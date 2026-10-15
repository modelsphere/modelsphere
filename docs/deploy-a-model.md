# Deploying a model

Each model is one Helm release of an engine chart, `sglang` or `vllm`. The
release brings the engine pods, the model's cache-aware router (CART), and
the objects that publish it to openresty and to the autoscaler.
[Install step 8](install.md#8-deploy-a-model) walks one small model end to
end; this page is for deploying a real one.

Clients call the model at **`/<route>/v1/...`**, and the route is the
**release name** (not the model name).

## Before you start

- The stack from [install step 6](install.md#6-install-the-stack) is running.
- The GPU nodes advertise `nvidia.com/gpu`: through your own device plugin, or
  with `enabled.gpuOperator: true`.
- **The weights are on each GPU node's local disk**, one directory per model,
  e.g. `/mnt/disk0/models/<org>/<model>`. `model.localPath` is a hostPath, so
  shared storage (NFS, CephFS) is not supported. A multi-node model needs a
  copy on every node of the group.
- **A model that spans several nodes** needs `enabled.lws` (either chart),
  plus `enabled.volcano` if it uses `schedulerName: volcano`. An environment
  file copied from `environments/private.yaml.example` turns both off.

## Write the values file

Both charts take the same values; only the image and the engine's own flags in
`extraArgs` differ (see [sglang and vLLM](#sglang-and-vllm)). A single-node
model on eight GPUs, on the sglang chart:

```yaml
image:
  repository: lmsysorg/sglang
  tag: v0.5.15-cu129                  # pin a tag; the default floats
model:
  name: "Qwen/Qwen2.5-72B-Instruct"   # what clients send as "model"
  localPath: "/mnt/disk0/models/Qwen/Qwen2.5-72B-Instruct"
  gpus: "8"                           # per pod
modelCheck:
  requiredGlobs: ["config.json", "*.safetensors"]
extraArgs:
  - --tp-size=8
  - --mem-fraction-static=0.85
volumes:
  - name: shm
    emptyDir: { medium: Memory, sizeLimit: 32Gi }
volumeMounts:
  - name: shm
    mountPath: /dev/shm
nodeSelector:
  nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3
tolerations:
  - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
modelRoute:
  nginx:
    outputConfigMap: "llm-route/openresty-conf"   # required
  monitor:
    enabled: false
```

On the vllm chart the file is the same except for the image and the flags:

```yaml
image:
  repository: vllm/vllm-openai
  tag: v0.30.0-cu129-ubuntu2404       # pin a tag; the default floats
extraArgs:
  - --tensor-parallel-size=8
  - --gpu-memory-utilization=0.85
```

**Startup and shutdown use the chart defaults**: up to 90 minutes to load
the model, and a pod being replaced keeps serving until its requests are done,
for up to 10 minutes. Raise `startupProbe.failureThreshold` for a model that
loads slower, and `lifecycle.preStop.drainSeconds` for responses that run
longer.

**Autoscaling is off until you set `maximumDeployment`**: the model stays at
one replica. See
[autoscaling.md](autoscaling.md#turn-on-autoscaling-for-a-model).

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| `image.repository`, `image.tag` | floating tag | The engine image. Pin the tag |
| `model.name` | `facebook/opt-125m` | The name clients send as `"model"` |
| `model.localPath` | `/mnt/disk0/models/facebook/opt-125m` | The weights directory on the node |
| `model.contextLength` | `""` (the model's own) | Set only to cap the context, e.g. `"32768"` |
| `model.gpus` | `"1"` | GPUs per pod. The only place to set a GPU count; not under `resources` |
| `extraArgs` | `[]` | Engine flags: parallelism, memory fraction, parsers, `--trust-remote-code`. They differ by engine: see [sglang and vLLM](#sglang-and-vllm) |
| `modelCheck.requiredGlobs` | `["config.json"]` | Files that must exist in the weights directory before the engine starts. Add `"*.safetensors"` |
| `resources`, `volumes`, `volumeMounts` | empty | CPU, memory, a memory-backed `/dev/shm` |
| `nodeSelector`, `tolerations`, `affinity` | empty | Which GPU nodes the model runs on |
| `priorityClassName` | `""` | e.g. `inference-prod` |
| `modelRoute.nginx.outputConfigMap` | not set | **Required**: `llm-route/openresty-conf` |
| `modelRoute.nginx.route` | release name | The path prefix, `/<route>/v1/...` |
| `modelRoute.nginx.values.expose_routed_peer` | `"true"` | Names the serving pod in `X-Routed-Peer`. Set `"false"` on any route reachable from outside the cluster |
| `modelRoute.monitor.enabled` | `true` | `false` unless you run the monitor ConfigMap |
| `lws.enabled`, `lws.size` | `false`, `2` | One model instance across several nodes; `lws.size` pods per group. See [Multi-node service](#multi-node-service) |
| `cart.enabled` | `true` | Deploys the model's CART and routes through it. See [cart.md](cart.md) |
| `continuationGateway.enabled` | `false` | Resumes streams that stall or drop mid-generation. See [Continuation gateway](#continuation-gateway-optional) |
| `scaler.*`, `sloRequirement.*` | | See [autoscaling.md](autoscaling.md) |

The charts reject unknown keys, so a typo fails the install.

## sglang and vLLM

The two charts share every setting on this page. What differs is the engine,
so its image and its own command-line flags:

| | sglang chart | vllm chart |
| --- | --- | --- |
| Chart | `modelsphere/sglang` | `modelsphere/vllm` |
| Image | `lmsysorg/sglang` | `vllm/vllm-openai` |
| Tensor parallelism | `--tp-size=N` (also accepts `--tensor-parallel-size=N`) | `--tensor-parallel-size=N` |
| GPU memory fraction | `--mem-fraction-static=0.85` | `--gpu-memory-utilization=0.85` |
| Multi-node layout | `--tp-size` covers the whole group | `tensor-parallel-size x pipeline-parallel-size = lws.size x model.gpus` |
| Multi-node flags the chart sets (do not pass them) | `--nnodes`, `--node-rank`, `--dist-init-addr` | `--nnodes`, `--node-rank`, `--master-addr`, `--master-port`, `--distributed-executor-backend=mp`, `--headless` |

Each chart also has a few settings for features only its engine has (for
example sglang's `cache.*`, vLLM's `promptTokensDetails`); they are described
in the chart's `values.yaml`.

## Multi-node service

Both charts can spread one model instance across several nodes, as a
LeaderWorkerSet instead of a Deployment: a **group** of `lws.size` pods (one
leader and its workers) loads the model, scales and restarts as one unit. It
needs the LWS controller (`enabled.lws`). Merge this into the single-node
values above:

```yaml
model:
  gpus: "8"                # per pod
lws:
  enabled: true
  size: 2                  # pods per group, leader included
extraArgs:                 # sglang: one tensor-parallel group over 2 x 8 GPUs
  - --tp-size=16
# extraArgs:               # vLLM: tensor x pipeline = 2 pods x 8 GPUs
#   - --tensor-parallel-size=8
#   - --pipeline-parallel-size=2
schedulerName: volcano     # optional: place the group whole or not at all
```

- `model.gpus` stays **per pod**; the parallelism you give the engine covers
  the **whole group**. The chart sets the flags that describe the group
  ([table above](#sglang-and-vllm)); do not pass them in `extraArgs`.
- vLLM runs its own multi-node mode, without Ray: the leader runs
  `vllm serve` with the API server and every worker `vllm serve --headless`.
- An sglang leader waits for its workers for the engine's `--dist-timeout`
  (600 s by default), not for the startup probe's budget.
- The Service is `<release>-leader`; CART, the ModelRoute and the autoscaler
  work as for a single node, with one replica being one whole group.
- Workers have no probes: a worker at `1/1` is running, not loaded. The
  group is ready when the leader is.
- A restart of any pod in the group recreates the whole group. Rollout
  behaviour is in [rolling-updates.md](rolling-updates.md#engine).

## Continuation gateway (optional)

The [continuation gateway](https://github.com/modelsphere/continuation_gateway)
resumes a streaming completion that stalls or drops mid-generation: it asks
the model to continue once from what the client has already received, so the
client sees one continuous, complete stream. Both engine charts deploy it as
part of the model's release. With it on, the model's traffic goes

```
openresty -> continuation gateway -> CART -> engine
```

```yaml
continuationGateway:
  enabled: true
  config:
    continuationModel: "glm-5.3"    # required: the real model this release serves
    # bufferToolCalls: true
    # stallIdleTimeoutSeconds: 600
  # resources: {}
```

- **`continuationModel` is required.** It is the model the engine actually
  serves, as one string, not the `model.name` clients send. It picks how the
  gateway rebuilds the prefix it continues from: `kimi-k3` uses Kimi-K3's own
  format; any other value uses a generic `<think>...</think>` format.
- `continuationEngine` is set by the chart (`sglang` or `vllm`); leave it.
- It needs `cart.enabled` and `modelRoute.enabled` (both on by default):
  openresty's CART peer is then pointed at the gateway's Service,
  `<release>-continuation-gateway`, and the gateway forwards to the CART.
  Turning it off points the peer back at the CART.
- The gateway is on the request path of the whole model, so size its replicas
  and `resources` for that traffic.

**Supported models.** Each engine and model combination has its own
continuation strategy, and not every combination is supported. Check the
compatibility table at the top of the
[continuation_gateway README](https://github.com/modelsphere/continuation_gateway#readme)
before turning it on; the repository also documents the gateway's settings
and how it decides to resume.

## Install

```bash
helm repo add modelsphere https://modelsphere.github.io/helm-charts
helm upgrade --install qwen modelsphere/sglang \
  -n llm-demo --create-namespace -f qwen-values.yaml   # or modelsphere/vllm
```

## Check that it works

```bash
kubectl -n llm-demo get pods
# engine qwen-<hash>        2/2   (engine + hang-watcher; 0/2 while loading)
# router qwen-cart-<hash>   3/3   x 2
kubectl -n llm-demo get modelroute qwen     # READY true, BACKENDS >= 1

# through openresty
kubectl -n llm-route port-forward svc/openresty 8080:8080 &
curl -s localhost:8080/qwen/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-72B-Instruct","messages":[{"role":"user","content":"hello"}]}'

# through the Gateway: the Host must be the HTTPRoute's hostname
kubectl -n llm-route get svc -l gateway.networking.k8s.io/gateway-name=openresty
curl -s http://<node-ip>:<http-nodeport>/qwen/v1/chat/completions \
  -H 'Host: llm.example.com' -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-72B-Instruct","messages":[{"role":"user","content":"hello"}]}'
```

**The CART pods wait in `Init` or `CrashLoopBackOff` while the engine is
still loading.** That is expected: there are no workers to route to yet. They
recover a minute or two after the engine reaches `2/2`.

Add `-H 'Authorization: Bearer <key>'` if openresty has API keys configured.

## Remove a model

```bash
helm -n llm-demo uninstall qwen
kubectl -n llm-demo get modelroute   # qwen gone, not stuck Terminating
```

**Uninstall models before you ever uninstall autoconfig.** autoconfig removes
the model's route from openresty; without it the ModelRoute stays
`Terminating` and the route stays published. Reinstalling autoconfig
finishes the job.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Render fails, `outputConfigMap is required` | Set `modelRoute.nginx.outputConfigMap: llm-route/openresty-conf` |
| Engine `Pending`, `Insufficient nvidia.com/gpu` | No free GPUs advertised on a matching node; check the device plugin, `nodeSelector`, `tolerations` |
| `FailedMount ... hostPath type check failed` | The weights are not at `model.localPath` on that node |
| `Init:CrashLoopBackOff` in `model-check` | The weights directory is empty or incomplete; finish the copy |
| Engine restarts during load, `Startup probe failed` | Raise `startupProbe.failureThreshold` |
| CART not ready minutes after the engine is `2/2` | `kubectl -n llm-demo describe modelroute qwen` and read the condition's reason |
| `502` from openresty | The path lacks the route: use `/<route>/v1/...` |
| `404` with an empty body at the Gateway | Send the HTTPRoute hostname as `Host` |
| Answers cut short, long prompts rejected | `model.contextLength` set too low; leave it `""` |
| ModelRoute stuck `Terminating` | autoconfig is not running; reinstall it |
