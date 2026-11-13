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
- **A model that spans several nodes** needs the sglang chart and
  `enabled.lws`, plus `enabled.volcano` if it uses `schedulerName: volcano`.
  An environment file copied from `environments/private.yaml.example` turns
  both off. The vllm chart is single-node only.

## Write the values file

A single-node sglang model on eight GPUs:

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
| `extraArgs` | `[]` | Engine flags: tensor parallelism (`--tensor-parallel-size=N` on both engines; SGLang also accepts `--tp-size=N`), memory fraction, parsers, `--trust-remote-code` |
| `modelCheck.requiredGlobs` | `["config.json"]` | Files that must exist in the weights directory before the engine starts. Add `"*.safetensors"` |
| `resources`, `volumes`, `volumeMounts` | empty | CPU, memory, a memory-backed `/dev/shm` |
| `nodeSelector`, `tolerations`, `affinity` | empty | Which GPU nodes the model runs on |
| `priorityClassName` | `""` | e.g. `inference-prod` |
| `modelRoute.nginx.outputConfigMap` | not set | **Required**: `llm-route/openresty-conf` |
| `modelRoute.nginx.route` | release name | The path prefix, `/<route>/v1/...` |
| `modelRoute.nginx.values.expose_routed_peer` | `"true"` | Names the serving pod in `X-Routed-Peer`. Set `"false"` on any route reachable from outside the cluster |
| `modelRoute.monitor.enabled` | `true` | `false` unless you run the monitor ConfigMap |
| `cart.enabled` | `true` | Deploys the model's CART and routes through it. See [cart.md](cart.md) |
| `scaler.*`, `sloRequirement.*` | | See [autoscaling.md](autoscaling.md) |

The charts reject unknown keys, so a typo fails the install.

## vLLM

The same model on the vllm chart (single node only):

```yaml
image:
  repository: vllm/vllm-openai
  tag: v0.30.0-cu129-ubuntu2404       # pin a tag; the default floats
model:
  name: "Qwen/Qwen2.5-72B-Instruct"   # what clients send as "model"
  localPath: "/mnt/disk0/models/Qwen/Qwen2.5-72B-Instruct"
  gpus: "8"                           # per pod
modelCheck:
  requiredGlobs: ["config.json", "*.safetensors"]
extraArgs:
  - --tensor-parallel-size=8
  - --gpu-memory-utilization=0.85
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

## Multi-nodes service (sglang only)

Add a LeaderWorkerSet. `model.gpus` stays per pod; `--tp-size` covers the
whole group. Do not pass `--nnodes`, `--node-rank` or `--dist-init-addr`: the
chart sets them.

```yaml
model:
  gpus: "8"
lws:
  enabled: true
  size: 2                  # pods per group, leader included
extraArgs:
  - --tp-size=16           # 2 x 8
schedulerName: volcano     # optional: place the group whole or not at all
```

Merge this into the single-node values above. The Service is
`<release>-leader`. Rollout behaviour for a group is in
[rolling-updates.md](rolling-updates.md#engine).

## Install

```bash
helm repo add modelsphere https://modelsphere.github.io/helm-charts
helm upgrade --install qwen modelsphere/sglang \
  -n llm-demo --create-namespace -f qwen-values.yaml
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
