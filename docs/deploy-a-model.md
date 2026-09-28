# Deploying a model

This is the reference behind
[README step 8](../README.md#8-deploy-a-model). The README walks one small
model end to end; come here to deploy a real one — a bigger model, several
GPUs, several nodes, the other engine — or to work out why a model that
installed cleanly does not answer.

It assumes the stack from [README step 6](../README.md#6-install-the-stack) is
running: openresty, autoconfig, the scaling and SLO operators, LWS, Volcano
and the GPU operator. To change a model that is already serving, see
[rolling-updates.md](rolling-updates.md). The values this page mentions are
indexed in [configuration.md](configuration.md).

## What one model is

**One model is one Helm release of an engine chart**, `sglang` or `vllm`.
The release brings everything that model needs with it, named after the
release (`qwen` below):

| Object | Name | What it is |
| --- | --- | --- |
| Deployment, **or** LeaderWorkerSet | `qwen` | the engine pods |
| Service | `qwen` (`qwen-leader` under LWS) | the engine's ClusterIP |
| ConfigMap | `qwen-hang-watcher` | thresholds for the hang-watcher sidecar |
| Deployment + Service | `qwen-cart` | this model's cache-aware router (CART), two replicas, one active |
| ConfigMap | `qwen-cart-config` | CART's config; autoconfig writes its `workers.yaml` key |
| ModelRoute | `qwen` | tells autoconfig to publish the model to openresty and CART |
| LLMScaler | `qwen` | autoscaling — see [autoscaling.md](autoscaling.md) |
| LLMSLORequirement | `qwen` | the latency targets the route is held to |
| PodDisruptionBudgets | engine, CART | drain protection |
| ServiceMonitor | `qwen` | Prometheus scrape |

Once the engine pod is Ready, autoconfig reads the ModelRoute, finds the
Ready pods behind the release's Service, and writes two things:

- the worker list, into the `workers.yaml` key of the CART ConfigMap
  ([cart.md](cart.md));
- a route, `session_route_<route>.conf`, into the openresty ConfigMap that
  every model shares — `llm-route/openresty-conf` on a stack installed from
  this repo ([routing-and-rate-limiting.md](routing-and-rate-limiting.md)).

Clients then call `/<route>/v1/...` on openresty. **`<route>` is the release
name**, not the model name, unless you set it yourself.

## 1. Choose the engine and the topology

### Engine

| | `sglang` chart | `vllm` chart |
| --- | --- | --- |
| Default image | `lmsysorg/sglang:latest` | `vllm/vllm-openai:latest-cu129-ubuntu2404` |
| Port (`service.port`) | 30000 | 8000 |
| Engine container name | `sglang` | `vllm` |
| Context length | `model.contextLength` → `--context-length` | `model.maxLen` → `--max-model-len` |
| Tensor parallel, in `extraArgs` | `--tp-size=N` | `--tensor-parallel-size=N` |
| Multi-node (LWS) | yes, `lws.enabled` | no — the chart renders a Deployment only |
| Hang-watcher's confirming probe | `GET /health_generate` | `POST /v1/completions`, 1 token |
| Default scaler signal | `Custom` (the decision server) | `Prometheus` |

Both charts default to a floating image tag. Pin one.

### Topology

Pick the smallest one the model fits in:

| Topology | Values that select it |
| --- | --- |
| One GPU | `model.gpus: "1"` |
| One node, tensor parallel | `model.gpus: "<N>"` plus `--tp-size=<N>` (sglang) or `--tensor-parallel-size=<N>` (vllm) in `extraArgs` |
| Several nodes (sglang only) | `lws.enabled: true`, `lws.size: <nodes>`, `model.gpus: "<GPUs per node>"`, and `--tp-size=<nodes × GPUs per node>` (or your TP/PP split) in `extraArgs` |

What the charts derive for you, and refuse to be told twice:

- **`model.gpus` is per pod**, not per LWS group, and it is the only place
  a GPU count is written. `nvidia.com/gpu` under `resources` fails the
  render.
- **Under LWS, `--nnodes`, `--node-rank` and `--dist-init-addr` come from
  the group** (`lws.size`, the pod's index, the leader's address). Any of
  them in `extraArgs` fails the render, because the last copy of a flag
  wins and would give every pod the same rank. `lws.size` must be at least
  2.
- **The chart already passes** `--model-path` (vllm: `--model`),
  `--served-model-name`, `--host`, `--port`, and `--enable-metrics`
  (sglang). Leave them out of `extraArgs`. Whatever you do put there is
  appended last.

## 2. Put the weights on the nodes

As in [README step 8](../README.md#8-deploy-a-model): **a copy per GPU node,
on local disk**, one directory per model:

```
/mnt/disk0/models/<org>/<model>      # e.g. /mnt/disk0/models/Qwen/Qwen2.5-7B-Instruct
```

`model.localPath` is a hostPath, so shared storage (CephFS, NFS) is not
supported. Under LWS every node of the group needs its own copy. Copying the
weights is not this repository's job.

| Value | Default | Effect |
| --- | --- | --- |
| `model.localPath` | `/mnt/disk0/models/facebook/opt-125m` | the directory on the node |
| `model.mountPath` | `/models` | where it is mounted, read-only; also what `--model-path` / `--model` gets |
| `model.hostPathType` | `Directory` | the kubelet refuses to start a pod whose path does not exist, with a `FailedMount` event |
| `modelCheck.enabled` | `true` | an init container, `model-check`, that runs in the engine image without a GPU and fails if the directory is empty or incomplete |
| `modelCheck.requiredGlobs` | `["config.json"]` | each glob must match something **directly** under the mount path |

Add the weight files to the check. A half-copied directory then fails in
seconds with a message that names it, instead of after a multi-minute load
with a stack trace:

```yaml
modelCheck:
  requiredGlobs: ["config.json", "*.safetensors"]
```

## 3. Write the values file

Both charts reject unknown top-level keys, so a typo fails the install
instead of being ignored. The defaults below are sglang chart 0.8.0 and vllm
chart 0.5.0, the versions `environments/default.yaml` pins.

### The values almost every model sets

| Key | Default | Set it to |
| --- | --- | --- |
| `image.repository`, `image.tag` | see §1 | your engine image, tag pinned |
| `model.name` | `facebook/opt-125m` | what clients send as `"model"` (`--served-model-name`) |
| `model.localPath` | see §2 | the weights on the node |
| `model.contextLength` (sglang), `model.maxLen` (vllm) | `"1024"` | **`""` to use the model's own context length**, or the cap you mean. The default is almost never what you want |
| `model.gpus` | `"1"` | GPUs per pod |
| `extraArgs` | `[]` | engine flags: parallelism, memory fraction, `--trust-remote-code`, parsers |
| `env` | `[]` | extra environment on the engine container |
| `resources` | `{}` | CPU, memory, ephemeral-storage, and extended resources other than GPUs (e.g. `rdma/hca_shared`) |
| `volumes`, `volumeMounts` | `[]` | typically a memory-backed `/dev/shm`; the chart adds none |
| `nodeSelector`, `tolerations`, `affinity` | empty | the GPU nodes this model belongs on |
| `priorityClassName` | `""` | e.g. `inference-prod`, created by `make helm-bootstrap` |
| `schedulerName` | `""` | `volcano`, to gang-schedule an LWS group |
| `startupProbe.failureThreshold` | `30` (× 10 s) | high enough that the whole load fits in `failureThreshold × periodSeconds` |
| `modelRoute.nginx.outputConfigMap` | `""` — **required** | `llm-route/openresty-conf` |
| `modelRoute.monitor.outputConfigMap` | `""` | the monitor ConfigMap, or set `modelRoute.monitor.enabled: false` |

### Routing and CART

More in [routing-and-rate-limiting.md](routing-and-rate-limiting.md) and
[cart.md](cart.md).

| Key | Default | Notes |
| --- | --- | --- |
| `modelRoute.enabled` | `true` | needs the ModelRoute CRD, which autoconfig brings |
| `modelRoute.name` | release name | the ModelRoute object's name |
| `modelRoute.nginx.route` | the ModelRoute's name | the path prefix, `/<route>/v1/...`; `[a-z0-9._-]` only |
| `modelRoute.nginx.values` | `expose_routed_peer: "true"` | knobs rendered into openresty's route table (`ttft_limit_ms`, `tps_limit_tps`, `default_max`, ...). **Set `expose_routed_peer: "false"` on any route reachable from outside the cluster**, or every caller sees your pod IPs and node names in `X-Routed-Peer` |
| `modelRoute.nginx.peers` | `backend` (priority 2, `maxConcurrency: 100`), `backend-svc` (priority 1) | tiers; traffic moves down a tier only when every peer above it is banned. With CART on, a `use: cart` tier is added on top for you |
| `modelRoute.discovery.includeNotReady` | `false` | only Ready engine pods are routed to |
| `modelRoute.slo.enabled` | `true` | route thresholds come from the LLMSLORequirement rather than static `nginx.values` |
| `modelRoute.cart.maxLoad` | `20` | per-worker `max_load` written for CART |
| `cart.enabled` | `true` | deploys this model's CART **and** routes through it — the only switch |
| `cart.nodeSelector`, `cart.tolerations`, `cart.resources` | subchart defaults | CART needs no GPU; keep it off scarce GPU nodes |

### Health, hang detection and shutdown

| Key | Default | Notes |
| --- | --- | --- |
| `hangWatcher.enabled` | `true` | a sidecar that watches token progress and owns the engine's livenessProbe; this is why the engine pod is `2/2` |
| `hangWatcher.config.stallSec` | `30` | how long progress may freeze before the sidecar starts asking the engine |
| `readinessProbe` | sglang `/health_generate`, vllm `/health` | |
| `livenessProbe` | | **not used while `hangWatcher.enabled`** |
| `terminationGracePeriodSeconds` | `60` | the hard deadline for a pod being replaced or removed |
| `lifecycle.preStop.endpointSyncSeconds` | `5` | how long the pod keeps serving while it is taken out of rotation |
| `lifecycle.preStop.drainSeconds` | `30` | how long preStop waits for in-flight requests; returns early once idle |
| `lifecycle.shutdownReserveSeconds` (sglang), `lifecycle.shutdownTimeout` (vllm) | `20`, `0` | the engine's own exit after SIGTERM |
| `progressDeadlineSeconds` | `1800` | Deployment only |

**For sglang, set `terminationGracePeriodSeconds: 150` and
`lifecycle.preStop.endpointSyncSeconds: 90`.** That combination was measured
to let an engine rollout drop no requests; the defaults dropped in-flight
streams. [rolling-updates.md](rolling-updates.md) has the measurement and
the rest of the rollout settings.

Two render-time checks keep the numbers consistent, and fail `helm install`
with the arithmetic spelled out:

- `terminationGracePeriodSeconds` must cover `endpointSyncSeconds +
  drainSeconds + shutdownReserveSeconds` (vllm: `+ shutdownTimeout`).
- On a Deployment, `progressDeadlineSeconds` must exceed
  `startupProbe.failureThreshold × periodSeconds`. At the defaults that
  allows a `failureThreshold` of up to 179; beyond it, raise
  `progressDeadlineSeconds` as well.

### Autoscaling and the SLO

More in [autoscaling.md](autoscaling.md).

| Key | Default (sglang / vllm) | Notes |
| --- | --- | --- |
| `scaler.enabled` | `true` | while on, the chart leaves `spec.replicas` to the operator and the start count is `scaler.minReplicas`; `replicaCount` and `lws.replicas` are ignored. Under LWS one replica is one group |
| `scaler.minReplicas`, `maxReplicas` | `1`, `5` | |
| `scaler.metricProvider` | `Custom` / `Prometheus` | `Custom` reads a replica count off a decision server; `Prometheus` evaluates `scaler.metrics` |
| `scaler.serverAddress` | `http://decision-gen.llm-scaler.svc:80` / `http://prometheus-operated.monitoring.svc:9090` | both are installed by step 6 |
| `scaler.scaleDown.stabilizationWindowSeconds`, `maxStepReplicas` | `10`, `0` / `0`, `0` | the chart's own comments suggest `300` and `1` in production |
| `sloRequirement.enabled` | `true` | |
| `sloRequirement.extraSpec` | `{}` | latency targets, passed through as written (e.g. `ttftMs`, `tpotMs`) |
| `serviceId` | release name | the id the decision server, the SLO object and the route share |

For a fixed replica count, set `scaler.enabled: false` and `replicaCount`
(or `lws.replicas`, in groups).

### Several nodes (LWS), sglang only

| Key | Default | Notes |
| --- | --- | --- |
| `lws.enabled` | `false` | a LeaderWorkerSet instead of a Deployment |
| `lws.size` | `2` | pods per group, leader included (= `--nnodes`) |
| `lws.replicas` | `1` | groups; only read with the scaler off |
| `lws.distPort` | `29500` | the rendezvous port inside the group |
| `lws.waitForLeader` | `true` | workers wait in a `wait-leader` init container until the leader's port opens |
| `podLabels` | `{}` | `rdma-ib: "true"` has the rdma-injector webhook set the per-node NCCL IB environment |
| `securityContext` | `{}` | `capabilities.add: ["IPC_LOCK"]` on an IB fabric, so RDMA can pin memory |

Under LWS the Service is `<release>-leader` and selects only the leader,
which is the one pod serving HTTP. Workers have no probes: a worker at `1/1`
is running, not necessarily loaded. The group's readiness is the leader's,
and the leader's `startupProbe` budget has to cover the slowest rank's start
plus the rendezvous.

## 4. Install

Two ways, producing the same release. Pick one per model and stay with it.

### Plain Helm

The one [README step 8](../README.md#8-deploy-a-model) uses:

```bash
helm repo add modelsphere https://modelsphere.github.io/helm-charts
helm upgrade --install qwen modelsphere/sglang --version 0.8.0 \
  --namespace llm-demo --create-namespace -f qwen-values.yaml
```

Right for a quick trial, or when models are managed outside this repo — a
GitOps tool, a CI job. Everything is as written in your values file: the
chart version, and every image address. A cluster that cannot reach Docker
Hub has to point `image.repository`, `hangWatcher.image.repository`,
`cart.image.repository`, `cart.ha.image` and `cart.reload.image` at its own
registry itself.

### helmfile `models:` entries

Right on a cluster whose stack this repo installed. Write a file of entries —
copy `models/examples/sglang-qwen.yaml`, which documents the format:

```yaml
models:
  - name: qwen              # the release name, and so the route name
    namespace: llm-demo     # default llm-demo
    chart: sglang           # sglang or vllm; default sglang
    # version: "0.8.0"      # default: versions.<chart> in environments/default.yaml
    # enabled: false        # uninstall on the next apply
    # timeout: 1800         # helm timeout, seconds
    values:                 # the chart's own values, merged as written
      image:
        repository: lmsysorg/sglang
        tag: v0.5.15-cu129
      model:
        name: "Qwen/Qwen2.5-0.5B-Instruct"
        localPath: "/mnt/disk0/models/Qwen/Qwen2.5-0.5B-Instruct"
        contextLength: "4096"
        gpus: "1"
      modelRoute:
        nginx:
          outputConfigMap: "llm-route/openresty-conf"
        monitor:
          enabled: false
```

and apply only the model releases:

```bash
make helm-diff  SELECTOR=tier=model MODELS=models/site.yaml
make helm-apply SELECTOR=tier=model MODELS=models/site.yaml
# several files, later ones winning:
make helm-apply SELECTOR=tier=model MODELS="models/a.yaml models/b.yaml"
```

What that buys over plain Helm:

- **the chart version comes from `versions:`**, like every other chart in the
  stack. An entry naming a chart with no pin there fails the render instead
  of installing whatever is newest;
- **images follow `registry` and `registryMode`**: the hang-watcher, CART and
  CART's two sidecars are named under `registry`
  (`models/images.yaml.gotmpl`), and under `registryMode: rewrite` the engine
  image is moved onto the local registry too — nothing to override per image
  on an air-gapped site ([offline-install.md](offline-install.md));
- **ordering**: every model `needs` autoconfig, so it installs after the
  controller that configures it;
- **`tier: model`**, so `SELECTOR=tier=model` touches models and nothing
  else.

`make helm-apply` asks before it changes anything (`INTERACTIVE=false` to
skip the prompt). Without `MODELS=` no model release is rendered at all.

## 5. Check it serves

In this order — each step needs the one before it. The commands use release
`qwen` in namespace `llm-demo` on the sglang chart.

**1. Pods.**

```bash
kubectl -n llm-demo get pods -o wide
```

| Pod | Expected |
| --- | --- |
| engine, `qwen-<hash>` | `Init` while `model-check` runs, `0/2` while the model loads, then `2/2` (engine + hang-watcher) |
| LWS leader `qwen-0`, workers `qwen-0-1` ... | leader `2/2`, workers `1/1` |
| router, `qwen-cart-<hash>` × 2 | `3/3` each (router, config reload, leader election) |

**Before the engine is Ready, the router pods are not.** They wait in `Init`
for up to ten minutes, then start and `CrashLoopBackOff` with
`Failed to read config file '/workspace/configs/workers.yaml'` — the README
describes the same window. There is no engine to route to yet, so autoconfig
has no worker list to write. It clears on its own: on a measured install
CART had its workers 65–80 s after the engine pod became Ready, and restarts
cleanly from there. It is a fault only if it persists a few minutes past
the engine reaching `2/2`.

**2. The engine answers.**

```bash
kubectl -n llm-demo exec deploy/qwen -c sglang -- curl -s localhost:30000/v1/models
```

On vllm, or under LWS, port-forward the Service instead and ask from your
own machine:

```bash
kubectl -n llm-demo port-forward svc/qwen 8000:8000             # vllm
kubectl -n llm-demo port-forward svc/qwen-leader 30000:30000    # sglang under LWS
curl -s localhost:8000/v1/models
```

The `id` it returns is `model.name` — the string clients send as `"model"`.

**3. The route is written.**

```bash
kubectl -n llm-demo get modelroute qwen
# NAME   BACKENDS   CART   READY   AGE
kubectl -n llm-demo get modelroute qwen -o jsonpath='{.status.appliedRouteKey}{"\n"}'
# session_route_qwen.conf
kubectl -n llm-demo get modelroute qwen \
  -o jsonpath='{range .status.conditions[*]}{.reason}: {.message}{"\n"}{end}'
```

`READY` true, `BACKENDS` at least 1 and reason `Synced` mean autoconfig has
written the route; on a measured install openresty had it about 16 s after
the engine pod became Ready. The other reasons are in
[Troubleshooting](#8-troubleshooting). To see the key from openresty's side:

```bash
kubectl -n llm-route get cm openresty-conf \
  -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' | grep qwen
```

**4. CART has its workers.**

```bash
kubectl -n llm-demo get cm qwen-cart-config -o jsonpath='{.data.workers\.yaml}'
kubectl -n llm-demo exec deploy/qwen -c sglang -- curl -s qwen-cart:8071/v1/models
```

**5. Through openresty, from inside the cluster.**

```bash
kubectl -n llm-route port-forward svc/openresty 8080:8080 &
curl -si localhost:8080/qwen/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct",
       "messages":[{"role":"user","content":"hello"}],"max_tokens":32}'
```

The first path segment is the **route** (`qwen`); the `"model"` field is
`model.name`. If the openresty release has API keys configured, add
`-H 'Authorization: Bearer <key>'`; with none, authentication is off. With
`expose_routed_peer` on, the response names the pod that served it in
`X-Routed-Peer`.

**6. Through the Gateway**, if you did
[README step 7](../README.md#7-gateway-objects). Cilium puts the Gateway on
a Service called `cilium-gateway-openresty`, reached over its http NodePort:

```bash
kubectl -n llm-route get svc -l gateway.networking.k8s.io/gateway-name=openresty
curl -si http://<node-ip>:<http nodeport>/qwen/v1/chat/completions \
  -H 'Host: llm.example.com' \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"hello"}]}'
```

`Host` is the hostname in `gateway-api/openresty/httproute-openresty.yaml` —
yours, once you have edited it. Without it the same request is a `404` with
an empty body. `server: envoy` in the response says Envoy handled it. A
Gateway showing `Programmed: False` can still be serving; see
[The Gateway looks dead and is not](helmfile-deploy.md#the-gateway-looks-dead-and-is-not).

## 6. Examples

Each renders against the charts `environments/default.yaml` pins. The model
names, image tags and node labels are placeholders for yours.

### sglang, one node, eight GPUs

```yaml
image:
  repository: lmsysorg/sglang
  tag: v0.5.15-cu129
model:
  name: "Qwen/Qwen2.5-72B-Instruct"
  localPath: "/mnt/disk0/models/Qwen/Qwen2.5-72B-Instruct"
  contextLength: ""              # the model's own
  gpus: "8"
modelCheck:
  requiredGlobs: ["config.json", "*.safetensors"]
extraArgs:
  - --tp-size=8
  - --mem-fraction-static=0.85
startupProbe:
  failureThreshold: 120          # 120 x 10 s = 20 minutes to load
# the rollout settings from rolling-updates.md
terminationGracePeriodSeconds: 150
lifecycle:
  preStop:
    endpointSyncSeconds: 90
volumes:
  - name: shm
    emptyDir: { medium: Memory, sizeLimit: 32Gi }
volumeMounts:
  - name: shm
    mountPath: /dev/shm
resources:
  requests: { cpu: "16", memory: 128Gi }
nodeSelector:
  nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3
tolerations:
  - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
priorityClassName: inference-prod
modelRoute:
  nginx:
    outputConfigMap: "llm-route/openresty-conf"
  monitor:
    enabled: false
```

### sglang, two nodes of eight GPUs (LeaderWorkerSet)

```yaml
image:
  repository: lmsysorg/sglang
  tag: v0.5.15-cu129
model:
  name: "deepseek-ai/DeepSeek-V3"
  localPath: "/mnt/disk0/models/deepseek-ai/DeepSeek-V3"   # on BOTH nodes
  contextLength: ""
  gpus: "8"                      # per pod
lws:
  enabled: true
  size: 2                        # leader + one worker = --nnodes=2
extraArgs:
  - --tp-size=16                 # 2 x 8; never --nnodes / --node-rank / --dist-init-addr
  - --trust-remote-code
schedulerName: volcano           # the group lands whole or not at all
podLabels:
  rdma-ib: "true"
securityContext:
  capabilities:
    add: ["IPC_LOCK"]
resources:
  limits: { rdma/hca_shared: "1" }
volumes:
  - name: shm
    emptyDir: { medium: Memory, sizeLimit: 64Gi }
volumeMounts:
  - name: shm
    mountPath: /dev/shm
startupProbe:
  failureThreshold: 180          # every rank's start plus the rendezvous
terminationGracePeriodSeconds: 300
lifecycle:
  preStop:
    endpointSyncSeconds: 90
priorityClassName: inference-prod
modelRoute:
  nginx:
    outputConfigMap: "llm-route/openresty-conf"
  monitor:
    enabled: false
```

The leader renders as `sglang serve ... --nnodes=2 --node-rank=0
--dist-init-addr=${LWS_LEADER_ADDRESS}:29500 --tp-size=16`, the worker with
`--node-rank=${LWS_WORKER_INDEX}`. `rdma/hca_shared` comes from the
network operator's RDMA shared device plugin (`enabled.nicClusterPolicy`,
off by default); drop it and the two lines above it on a cluster without an
IB fabric. `schedulerName: volcano` needs Volcano and LWS gang scheduling,
both on in `environments/default.yaml` — `scheduler/volcano/README.md` has
the order in which they are switched on.

### vllm, one node, two GPUs

```yaml
image:
  repository: vllm/vllm-openai
  tag: v0.11.0                   # the build you have tested
model:
  name: "Qwen/Qwen2.5-7B-Instruct"
  localPath: "/mnt/disk0/models/Qwen/Qwen2.5-7B-Instruct"
  maxLen: "32768"
  gpus: "2"
modelCheck:
  requiredGlobs: ["config.json", "*.safetensors"]
extraArgs:
  - --tensor-parallel-size=2
  - --gpu-memory-utilization=0.90
volumes:
  - name: shm
    emptyDir: { medium: Memory, sizeLimit: 16Gi }
volumeMounts:
  - name: shm
    mountPath: /dev/shm
startupProbe:
  failureThreshold: 60
scaler:
  metricProvider: Custom         # the decision server the sglang chart uses by default
  serverAddress: "http://decision-gen.llm-scaler.svc:80"
modelRoute:
  nginx:
    outputConfigMap: "llm-route/openresty-conf"
  monitor:
    enabled: false
```

To keep the chart's own `Prometheus` signal instead, drop the `scaler` block
and leave `serviceMonitor.enabled` on, so its `vllm:num_requests_waiting`
query has data.

## 7. Remove a model

**The ModelRoute carries a finalizer, `routing.modelsphere.dev/cleanup`.**
When the ModelRoute is deleted, autoconfig takes this route's key — only
this one — out of the shared openresty ConfigMap (and the monitor key, if
there is one), then lets the object go. It never deletes the shared
ConfigMaps themselves, never touches the CART ConfigMap (that goes with the
release), and leaves a key alone if another ModelRoute owns it.

That finalizer is why the order matters:

1. **Move traffic off `/<route>/`.**
2. **Uninstall the release while autoconfig is running:**

   ```bash
   helm -n llm-demo uninstall qwen
   ```

   With helmfile, set `enabled: false` on the entry and run
   `make helm-apply SELECTOR=tier=model MODELS=...`. Deleting the entry from
   the file is not enough: helmfile only acts on releases it declares.
3. **Check it is gone:**

   ```bash
   kubectl -n llm-demo get modelroute          # no qwen, not stuck Terminating
   kubectl -n llm-route get cm openresty-conf \
     -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' | grep qwen   # nothing
   kubectl -n llm-demo get pods                # engine and router pods gone
   ```

**Remove models before autoconfig, never after.** With the controller gone,
the ModelRoute sits in `Terminating` for good and its route stays in
openresty's ConfigMap. Reinstalling autoconfig lets it finish the job. Only
if that is not an option: delete the `session_route_<route>.conf` key from
`openresty-conf` by hand, then release the object:

```bash
kubectl -n llm-demo patch modelroute qwen --type=merge -p '{"metadata":{"finalizers":null}}'
```

Renaming a route (`modelRoute.nginx.route`) needs none of this: autoconfig
removes the key it last wrote (`status.appliedRouteKey`) and writes the new
one.

## 8. Troubleshooting

| Symptom | Cause | Check / fix |
| --- | --- | --- |
| Render fails: `modelRoute.nginx.outputConfigMap is required` | the one required value is unset | `modelRoute.nginx.outputConfigMap: llm-route/openresty-conf` |
| Install fails: `no matches for kind ModelRoute` (or `LLMScaler`, `LLMSLORequirement`, `ServiceMonitor`, `LeaderWorkerSet`) | the component that brings that CRD is not installed. ModelRoute and LLMSLORequirement come from charts' `crds/` directories (so they carry no Helm labels), LLMScaler from the `llmscaleoperator` release, ServiceMonitor from kube-prometheus-stack, LeaderWorkerSet from `lws` | install it via step 6, or turn the feature off: `modelRoute.enabled`, `scaler.enabled`, `sloRequirement.enabled`, `serviceMonitor.enabled` |
| Install fails: `additional properties '<x>' not allowed` | a typo, or a key from another chart version | fix the key |
| Render fails: `progressDeadlineSeconds ... does not clear the startupProbe budget` | `failureThreshold × periodSeconds` reaches `progressDeadlineSeconds` | raise `progressDeadlineSeconds` past the load time plus image pull |
| Render fails: `terminationGracePeriodSeconds ... is smaller than the shutdown budget` | preStop plus the engine's exit do not fit the grace period | raise `terminationGracePeriodSeconds`, or lower `drainSeconds` |
| Render fails: `extraArgs carries "--nnodes..."` | a flag LWS derives, repeated | remove `--nnodes`, `--node-rank`, `--dist-init-addr` |
| Render fails: `set the GPU count with model.gpus` | `nvidia.com/gpu` under `resources` | move it to `model.gpus` |
| Engine `Pending`, `Insufficient nvidia.com/gpu` | no GPUs advertised, or none free on a matching node | `kubectl get node <n> -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'`; check `nodeSelector` and `tolerations` |
| New pod `Pending` on every upgrade | `maxSurge: 1` needs a free GPU slot for the replacement | see [rolling-updates.md](rolling-updates.md) |
| `ContainerCreating`, `FailedMount ... hostPath type check failed` | `model.localPath` is not on that node | copy the weights there, or pin the pod to nodes that have them |
| `Init:CrashLoopBackOff`, `model-check: ... is empty` / `no *.safetensors directly under` | an empty or half-copied weights directory | `kubectl logs <pod> -c model-check`; finish the copy |
| Engine restarts mid-load, `Startup probe failed` | the load outlasts `failureThreshold × periodSeconds` | raise `startupProbe.failureThreshold` |
| Engine restarts while serving, liveness on `/healthz` gets 503 | the hang-watcher called a hang | `kubectl logs <pod> -c hang-watcher`; raise `hangWatcher.config.stallSec` for a model with long stop-the-world phases |
| Router `Init:0/1`, or `CrashLoopBackOff` with `Failed to read config file .../workers.yaml` | no Ready engine yet, so no worker list | expected until a minute or two after the engine is `2/2`; past that, read the ModelRoute's reason |
| ModelRoute not Ready, reason `NoBackends` | no Ready engine pod; the previous config is kept | wait for the engine, or see why it is not Ready |
| ModelRoute not Ready, reason `ConfigMapMissing` | `outputConfigMap` names a ConfigMap that does not exist; autoconfig updates ConfigMaps, it never creates them | `kubectl -n llm-route get cm openresty-conf` |
| ModelRoute reason `RouteKeyConflict` | two ModelRoutes resolve to the same route | give one its own `modelRoute.name` or `modelRoute.nginx.route` |
| `502` from openresty, every pod healthy | no route prefix: `/v1/chat/completions` instead of `/<route>/v1/chat/completions` | put the route name first in the path |
| `404` with an empty body at the Gateway | the `Host` header does not match the HTTPRoute hostname — typically a request to an IP | send `-H 'Host: <your hostname>'` |
| HTTPRoute `Accepted=False`, `NotAllowedByListeners` | the namespace label is missing | apply all of `gateway-api/openresty/` |
| `401` from openresty | API keys are configured | `-H 'Authorization: Bearer <key>'` |
| Answers are cut short, or long prompts are rejected | `model.contextLength` / `model.maxLen` left at `"1024"` | `""` for the model's own, or your real cap |
| LWS leader not Ready, worker waiting in `wait-leader` | the leader has not come up, or the group was not placed together | `kubectl logs <leader> -c sglang`; with `schedulerName: volcano`, check the group's PodGroup |
| ModelRoute stuck `Terminating` after an uninstall | autoconfig is not running to process the finalizer | see [Remove a model](#7-remove-a-model) |
