# Autoscaling inference engines

This page covers how ModelSphere changes the number of engine replicas: what
it reads, what it writes, every setting, and how to switch it off. The index of
all configuration pages is [`configuration.md`](configuration.md). Deploying a
model in the first place is [`deploy-a-model.md`](deploy-a-model.md).

Scaling is horizontal. A replica is either one pod of a Deployment or one group
of a LeaderWorkerSet (a multi-node model). Two components take part, and the
first one also works on its own:

| | Chart | Namespace | Does |
| --- | --- | --- | --- |
| **llmscaleoperator** | `llmscaleoperator` | `llmscaleoperator-system` | Reconciles `LLMScaler` objects: writes `spec.replicas` on the target workload and picks which pods to remove on scale-down. Owns the `LLMScaler` CRD. |
| **decision-gen** | `llm-slo-decision-gen` (helmfile release `llm-slo`) | `llm-scaler` | Optional. Reads `LLMSLORequirement` / `JobSLORequirement` objects and live signals, and publishes one replica count per service at `GET /decisions`. It never writes to the cluster. Owns the two SLO CRDs. |

Both are in the helmfile's `operator` tier, controlled by `enabled.llmOperator`,
`enabled.llmslo`, `versions.llmOperator` and `versions.llmslo`. Each engine
chart (`vllm`, `sglang`) creates its model's own `LLMScaler` and
`LLMSLORequirement`.

> **A stock install does not autoscale.** The `sglang` chart points its scaler
> at decision-gen. Its `LLMSLORequirement`, though, has no
> `maximumDeployment`, and decision-gen treats that as "do not manage this
> service". On a fresh install `/decisions` returns
> `"decisions": []`, the operator holds, and the model stays at
> `scaler.minReplicas`:
>
> ```
> $ kubectl -n llm-demo get llmscalers
> NAME   MINREPLICAS   MAXREPLICAS   CURRENTREPLICAS   DESIREDREPLICAS
> qwen   1             5             1                 1
> ```
>
> To turn scaling on, pick one of the two signal sources below and configure it.
> [Scale on SLO targets](#scale-on-slo-targets-decision-gen) shows the missing
> piece.

## How it works

### Two signal sources

An `LLMScaler` chooses exactly one source with `spec.metricProvider`. The two
are alternatives, not layers. If the chosen source fails, nothing falls back to
the other one.

```
 metricProvider: Prometheus                  metricProvider: Custom
 ──────────────────────────                  ──────────────────────
 engine /metrics ─▶ Prometheus               LLMSLORequirement / JobSLORequirement
                        │                     bodylog-exporter, kube-state-metrics ─▶ Prometheus
                        │ spec.metrics         workloads + GPU nodes (Kubernetes API)
                        ▼ (PromQL)                         │
                 llmscaleoperator                          ▼
   desired = ceil(ready × value / target)        decision-gen (every 60s)
                        │                                  │ GET /decisions?serviceId=…
                        │                                  ▼
                        │                          llmscaleoperator
                        │                     desired = decisions[].replicas.active
                        └───────────────┬──────────────────┘
                                        ▼
         clamp to [minReplicas, maxReplicas] → scale-down stabilization → step cap
                                        ▼
            Deployment / StatefulSet / LeaderWorkerSet   .spec.replicas
```

**Prometheus.**
- Every sync, the operator sends each `spec.metrics[].query` to
  `{serverAddress}/api/v1/query` and computes `ceil(readyReplicas × value /
  target)`.
- When there are several metrics, the largest result wins.
- The usual signals come from the engine's own `/metrics`, scraped through the
  chart's ServiceMonitor:
  - queue depth: `vllm:num_requests_waiting`, `sglang:num_queue_reqs`
  - KV-cache usage: `vllm:kv_cache_usage_perc`, `sglang:token_usage`

**Custom (decision-gen).**
- The operator calls
  `GET {serverAddress}{customProvider.path}?serviceId={serviceId}`.
- It uses `decisions[].replicas.active` as an absolute replica count.
- decision-gen works that number out from the inputs below. Every PromQL series
  is selected by `service="<namespace>/<serviceId>"`:

| Input | Series / source | From |
| --- | --- | --- |
| TTFT, seconds | `bodylog_ttft_seconds` (native histogram), 5m rate | bodylog-exporter |
| Output tokens/s per request | `bodylog_output_tok_per_second` (native histogram), 5m rate | bodylog-exporter |
| Request count (minimum-evidence rule) | `bodylog_requests_total{backend!="(none)"}`, 5m increase | bodylog-exporter |
| 429 rejection rate and count | `openresty_rejected_total` ÷ `bodylog_requests_total`, 2m | bodylog-exporter (openresty poll) |
| Ready replicas, LLM services | `max by(service)(avg_over_time(bodylog_service_replicas_ready[2m]))` | bodylog-exporter (ModelRoute discovery) |
| Ready replicas, job services | `kube_deployment_status_replicas_ready{namespace, deployment="<serviceId>"}` | kube-state-metrics |
| Queue depth, job services | the `JobSLORequirement`'s own `queue.promql` | your exporter |
| GPU capacity per pool | `status.allocatable["nvidia.com/gpu"]` of Ready, schedulable nodes labelled `nvidia.com/gpu.present=true`, grouped by `nvidia.com/gpu.product` | Kubernetes API |
| Workload shape | the LWS, StatefulSet or Deployment **named after the serviceId**: GPUs per replica (`nvidia.com/gpu` limit × LWS size), GPU pool (node affinity on `nvidia.com/gpu.product`), `spec.replicas` | Kubernetes API |

**Every bodylog series depends on the bodylog pipeline actually receiving
records.** The pipeline runs openresty → bodylog listener → bodylog-exporter.
If openresty's `bodylog.host` is not a fully qualified name, the listener
receives nothing (see [`routing-and-rate-limiting.md`](routing-and-rate-limiting.md)).
In that case every bodylog-derived input above is empty and decision-gen holds
every LLM service where it is. Fix that before you rely on SLO scaling.

Where the `service` label comes from:
- bodylog-exporter copies it from the ModelRoute's `spec.discovery.service`
  (`<ns>/<Service name>`) and strips any `-leader` suffix.
- The engine charts point that field at the release's own Service.

**For the SLO path to find its data, the serviceId, the workload name and the
Service name (minus `-leader`) must be the same string.** They are, as long as
you leave the chart's `serviceId` and `fullnameOverride` at their defaults.

### What gets scaled

- `spec.targetRef` can be a `Deployment`, `StatefulSet` or `LeaderWorkerSet`.
- The target must be in the **same namespace as the `LLMScaler`**; there is no
  namespace field.
- The operator reads `spec.replicas` and `status.readyReplicas`, and writes
  `spec.replicas`.

Which workload each engine chart targets:
- The `vllm` chart always targets its Deployment.
- The `sglang` chart targets its Deployment, or its LeaderWorkerSet when
  `lws.enabled: true`. With an LWS, one replica is one group of `lws.size`
  pods.

**While the scaler is enabled, the engine charts leave `spec.replicas` out of
the workload entirely**, so that the operator owns the field.
- The API server defaults it to 1, and the operator's first sync clamps it to
  `minReplicas`.
- `replicaCount` and `lws.replicas` only apply with `scaler.enabled: false`.

### Rules the operator applies on every sync

- **No data means no change.** The metric source for a sync is ignored when:
  - a Prometheus query errors, returns nothing, returns more than one series,
    or returns NaN/Inf;
  - or a decision request fails, comes back in an unknown `apiVersion`, has
    zero or several matching decisions, or has no `replicas.active`.

  When every source is ignored, the operator keeps the current
  `spec.replicas`. It still clamps that value to
  `[minReplicas, maxReplicas]`.
- **Scale-up is immediate.** It is bounded by `maxReplicas`. It is also
  computed from *ready* replicas, so pods that are still starting do not
  compound.
- **Scale-down is damped** in three ways:
  - `scaleDown.stabilizationWindowSeconds` holds the fleet at the highest
    recommendation seen in the window.
  - After every scale-down, the window restarts from the new count.
  - `scaleDown.maxStepReplicas` caps how many replicas a single write removes.
- **Rollout guard (Deployment only).** There is no scaling while a template
  rollout is in progress:
  - `observedGeneration < generation`,
  - or `updatedReplicas < spec.replicas`,
  - or pods from an old ReplicaSet still exist.

  See [`rolling-updates.md`](rolling-updates.md).
- **Settle guard.** The next scale-down waits until
  `readyReplicas == spec.replicas`.

### How scale-down drains

1. **Which pod goes (Deployment targets, `scaleDown.behavior: CacheAware`).**
   Before lowering `spec.replicas`, the operator sets
   `controller.kubernetes.io/pod-deletion-cost` on the pods it wants gone, and
   the ReplicaSet deletes those first.
   - How the pods are chosen:
     - With `deletionCostQuery` under the Prometheus provider, each pod's cost
       is that query's value for the pod.
     - Otherwise the newest pods get cost `-100`.
   - The cost is a hint: an unready pod is still deleted first.
   - StatefulSet and LWS targets ignore it and remove by ordinal.
2. **How it leaves.** The engine chart's `lifecycle.preStop` hook:
   1. waits `endpointSyncSeconds` so routers stop sending new requests;
   2. waits up to `drainSeconds` for the engine to go idle, checking every
      `pollIntervalSeconds`;
   3. hands over to the engine's own shutdown: `lifecycle.shutdownTimeout`
      for vLLM, `lifecycle.shutdownReserveSeconds` for SGLang.

   The whole sequence has to fit in `terminationGracePeriodSeconds` (default
   60). The chart refuses to render if it does not.

Routers pick the change up by themselves: autoconfig and CART follow the
Service's endpoints. See [`cart.md`](cart.md).

## `LLMScaler` (`autoscaling.modelsphere.dev/v1alpha1`)

Namespaced, with a `status` subresource. `kubectl get llmscalers` shows
`MINREPLICAS`, `MAXREPLICAS`, `CURRENTREPLICAS` and `DESIREDREPLICAS`.

### `spec`

| Field | Default | Validation | Meaning |
| --- | --- | --- | --- |
| `targetRef.apiVersion` | — | required | `apps/v1`, `leaderworkerset.x-k8s.io/v1` |
| `targetRef.kind` | — | required | `Deployment`, `StatefulSet` or `LeaderWorkerSet` |
| `targetRef.name` | — | required | Workload name, in this object's namespace |
| `metricProvider` | `Prometheus` | `Prometheus` \| `Custom` | Signal source |
| `customProvider` | — | required when `Custom` | See below; ignored under `Prometheus` |
| `serverAddress` | — | required | `Prometheus`: the query API base URL (`/api/v1/query` is appended). `Custom`: the decision server's base URL |
| `serverHeaders` | — | | Extra HTTP headers sent verbatim with every fetch, e.g. `Authorization` |
| `minReplicas` | — | required, ≥ 1 | Floor, applied to every result including a held one |
| `maxReplicas` | — | required, ≥ 1 | Ceiling |
| `metrics[].name` | — | | Label used in logs |
| `metrics[].query` | — | required | PromQL returning **exactly one** series; aggregate it with `avg(...)` |
| `metrics[].target` | — | required; finite, > 0; a `%` suffix is rejected | Per-replica target on the query's own scale: `"0.8"` for a 0–1 ratio, `"80"` for 0–100 |
| `metrics` | — | non-empty unless `Custom` | Ignored under `Custom` |
| `syncPeriodSeconds` | `15` | | Seconds between evaluations |
| `retryPeriodSeconds` | `10` | | Retry interval while the target cannot be read |
| `scaleDown.stabilizationWindowSeconds` | `0` | | Hold at the window's highest recommendation; `0` is off. Scale-up is unaffected |
| `scaleDown.maxStepReplicas` | `0` | ≥ 0 | Max replicas removed per write; `0` is unlimited |
| `scaleDown.behavior` | `CacheAware` | `CacheAware` \| `None` | `None` leaves the deletion order to the workload controller |
| `scaleDown.deletionCostQuery` | — | | PromQL returning one series per `pod` label; lowest is deleted first. Only used with `CacheAware` **and** `Prometheus` |
| `preemption.enable`, `preemption.priorityClass` | — | | Accepted, not implemented |

### `spec.customProvider`

| Field | Default | Meaning |
| --- | --- | --- |
| `serviceId` | — (required) | Sent as `?serviceId=` **and** matched against `decisions[].serviceId` in the reply |
| `namespace` | — | Only accept decisions for this namespace. Without it, more than one matching decision is an error and the sync holds |
| `path` | `/decisions` | Request path |

About the reply:
- The only schema accepted is `apiVersion: llmscaling.inference.x-k8s.io/v1alpha1`.
- Only `replicas.active` (≥ 0) is read. A `0` is clamped up to `minReplicas`.
- Decision requests and Prometheus queries both time out after 5 s.

### `status`

| Field | Meaning |
| --- | --- |
| `currentReplicas` | Ready replicas of the target at the last sync |
| `desiredReplicas` | The recommendation after clamping and stabilization, **before** the `maxStepReplicas` cap. It shows where a step-capped descent is heading |
| `conditions` | Declared, not populated |

## `LLMSLORequirement` (`inference.modelsphere.dev/v1alpha1`)

Namespaced; short names `llmslo` and `slo`. decision-gen keys each object by
`(metadata.namespace, spec.serviceId)`. The same object also sets openresty's
per-route TTFT/TPS admission limits through autoconfig. That use is documented
in [`routing-and-rate-limiting.md`](routing-and-rate-limiting.md) and not
repeated here.

| Field | Default | Validation | What decision-gen does with it |
| --- | --- | --- | --- |
| `serviceId` | — | required | Service key; must equal the workload name |
| `minimumDeployment.value` | `1` | ≥ 1 | Replica floor |
| `minimumDeployment.type` | `replica` | `replica` \| `concurrency` | Not read; `value` is always replicas |
| `maximumDeployment.value` | — | ≥ 1 | Replica ceiling. **Without `maximumDeployment`, the service is not managed at all.** If min > max, max is raised to min |
| `maximumDeployment.type` | `replica` | `replica` | Not read |
| `priority` | `0` | 0–10 | Allocation tier when GPUs are short: higher tiers are served first and may take replicas from lower tiers, down to those tiers' minimums |
| `ttft.default.metrics[]` | — | ≥ 1 item; `type` ∈ `avg`, `p50`, `p80`, `p90`, `p95`, `p99`; `threshold` ≥ 0 | TTFT ceiling **in seconds**. `p80: 2` means 80 % of requests get their first token within 2 s |
| `otps.default.metrics[]` | — | same | Floor on output tokens/s per request. `p80: 20` means 80 % of requests decode at ≥ 20 tok/s (it is checked on the slow tail, quantile 0.2) |
| `ttft.ranges[]`, `otps.ranges[]` | — | `contextLengthRangeLow` (required), `contextLengthRangeHigh`, `metrics[]` | Accepted by the schema and **ignored**; only `default` is read |

## `JobSLORequirement` (`inference.modelsphere.dev/v1alpha1`)

This resource is for asynchronous job workers; its short name is `jobslo`. It
has the same `serviceId`, `minimumDeployment`, `maximumDeployment` and
`priority` fields as `LLMSLORequirement`, plus:

| Field | Validation | Meaning |
| --- | --- | --- |
| `queue.promql` | required, non-empty | PromQL returning the **whole fleet's** queue depth as one series; decision-gen divides it by ready replicas. Append `or vector(0)` if an idle queue should count as comfortable rather than missing |
| `queue.maxDepth` | required, ≥ 0 | Target pending jobs **per replica**. `0` counts as not configured, and the service holds |

Ready replicas come from kube-state-metrics' `kube_deployment_status_replicas_ready`
with `deployment=<serviceId>`. In practice, the worker must be a Deployment
named after the serviceId.

## Engine chart values (`vllm`, `sglang`)

### `scaler:`

The rendered `LLMScaler` is named after the chart's fullname, in the release
namespace.

| Value | vllm | sglang | Renders / means |
| --- | --- | --- | --- |
| `scaler.enabled` | `true` | `true` | Creates the `LLMScaler` and drops `spec.replicas` from the workload. `false`: fixed `replicaCount` |
| `scaler.minReplicas` | `1` | `1` | `spec.minReplicas` |
| `scaler.maxReplicas` | `5` | `5` | `spec.maxReplicas` |
| `scaler.syncPeriodSeconds` | `10` | `10` | `spec.syncPeriodSeconds` |
| `scaler.metricProvider` | `Prometheus` | **`Custom`** | Always written out; anything else fails the render |
| `scaler.serverAddress` | `http://prometheus-operated.monitoring.svc:9090` | `http://decision-gen.llm-scaler.svc:80` | Required unless `metricsMock.enabled` |
| `scaler.serverHeaders` | `{}` | `{}` | `spec.serverHeaders` |
| `scaler.customProvider.serviceId` | `""` | `""` | Empty: the top-level `serviceId` |
| `scaler.customProvider.path` | `""` | `""` | Omitted when empty, so the CRD default `/decisions` applies |
| `scaler.customProvider.namespace` | `""` | `""` | Always rendered; empty means **the release namespace** |
| `scaler.metrics[]` | `queue-depth`: `avg(avg_over_time(vllm:num_requests_waiting{__SCOPE__}[1m]))`, target `"5"` | `queue-depth`: `avg(avg_over_time(sglang:num_queue_reqs{__SCOPE__}[1m]))`, target `"5"` | Rendered only under `Prometheus`, where an empty list fails the render |
| `scaler.scaleDown.behavior` | `CacheAware` | `CacheAware` | |
| `scaler.scaleDown.stabilizationWindowSeconds` | `0` | `10` | Omitted when 0 |
| `scaler.scaleDown.maxStepReplicas` | `0` | `0` | Omitted when 0 |
| `scaler.scaleDown.deletionCostQuery` | `""` | `""` | Dropped under `Custom`. E.g. `vllm:kv_cache_usage_perc{__SCOPE__} * 100`, `sglang:token_usage{__SCOPE__} * 100` |

**`__SCOPE__`** in a query becomes `namespace="<release ns>",
app="<release>-vllm"` (or `-sglang`). This limits the query to this release's
pods. It relies on `serviceMonitor.podTargetLabels: [app]`, which is the
default.

**`metricsMock`** (`enabled: false`, `value: "10"`, `image`) is for testing.
It stands up a fake Prometheus that always answers `value` and points the
scaler at it, so you can push the fleet to max or min by hand. It cannot be
combined with `Custom`. Leave `deletionCostQuery` empty while it is on.

### `sloRequirement:`

| Value | Default | Renders |
| --- | --- | --- |
| `sloRequirement.enabled` | `true` | The `LLMSLORequirement`. Needs the CRD from `llm-slo` |
| `sloRequirement.name` | `""` | `metadata.name`; empty: the top-level `serviceId` |
| `sloRequirement.serviceId` | `""` | `spec.serviceId`; empty: the top-level `serviceId` |
| `sloRequirement.annotations` | `{}` | `metadata.annotations` |
| `sloRequirement.extraSpec` | `{}` | Merged verbatim into `spec`. `minimumDeployment`, `maximumDeployment`, `priority`, `ttft` and `otps` go here. Must not contain `serviceId` (the render fails) |

The chart's commented example keys `ttftMs` / `tpotMs` are **not fields of this
CRD** and have no effect. Use `ttft.default.metrics` / `otps.default.metrics`.

### Names

- `fullnameOverride` (default: the release name) names the workload, its
  Service and the `LLMScaler`.
- `serviceId` (default: the fullname) is the default for
  `customProvider.serviceId`, `sloRequirement.serviceId` and
  `sloRequirement.name`.

For SLO scaling, keep `serviceId` equal to the fullname.

## decision-gen

### Environment

There is no config file. Set these variables through the chart's
`decisionGen.env` (or `decisionGen.unstable.env`).

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8080` | HTTP port |
| `TICK_SECONDS` | `60` | How often every service is re-derived from scratch |
| `PROM_URL` | `http://kube-prometheus-stack-prometheus.monitoring:9090` | Prometheus with the bodylog-exporter and kube-state-metrics series |
| `PROM_TIMEOUT_S` | `5` | Per-query timeout |
| `LOG_LEVEL` | `INFO` | decision-gen's own log level; the Kubernetes client is capped at WARNING |
| `DEFAULT_GPU_POOL` | `NVIDIA-H100-80GB-HBM3` | Pool used for a workload with no `nvidia.com/gpu.product` `In` node affinity. Set it to your nodes' `nvidia.com/gpu.product` value |
| `SCALE_UP_COOLDOWN_S` | `900` | Time since the last change before an SLO-violation scale-up |
| `SCALE_DOWN_COOLDOWN_S` | `1800` | Time since the last change before a scale-down |
| `SCALE_DOWN_COMFORT_S` | `1200` | How long every SLO must stay comfortable, without a break, before a scale-down |
| `SLO_HEADROOM` | `0.5` | "Comfortable" means TTFT < threshold × 0.5, OTPS > threshold ÷ 0.5, and queue per replica < maxDepth × 0.5 |
| `REJECTION_THRESHOLD` | `0.05` | 429 rate that fires the emergency scale-up |
| `REJECTION_OK_FLOOR` | `0.001` | A scale-down needs a 429 rate below this |
| `SCALE_UP_MULTIPLIER_GAIN` | `2.0` | Emergency multiplier = 1 + r/(1−r) × gain |
| `SCALE_UP_MULTIPLIER_CAP` | `1.5` | Multiplier cap when an SLO is also violated |
| `SCALE_UP_MULTIPLIER_CAP_CLEAN_SLO` | `1.2` | Multiplier cap when no SLO is violated |
| `SCALE_UP_STEP_FRAC` | `0.15` | SLO scale-up step: + max(1, ceil(0.15 × current)) |
| `SCALE_DOWN_STEP_FRAC` | `0.15` | Scale-down step: − max(1, ceil(0.15 × current)) |
| `R1A_MIN_REJECTIONS_2M` | `5` | Minimum 429s in 2 min before the emergency rule can fire |
| `R1B_MIN_REQUESTS_5M` | `20` | Minimum requests in 5 min before an SLO violation counts |

**GPU pools.** A pool is a `nvidia.com/gpu.product` value.
- decision-gen currently merges the product `NVIDIA-H800` into the pool
  `NVIDIA-H100-80GB-HBM3`. This applies both when it reads workload affinity
  and when it counts node capacity.
- A workload whose affinity names two or more distinct pools is not managed.
- A workload with no product affinity is placed in `DEFAULT_GPU_POOL`.

### Rules, per service, per tick

Each tick starts with a check. **A service is skipped** if any of these hold:
- the CR has no `maximumDeployment`;
- no LWS, StatefulSet or Deployment (looked up in that order) is named after
  the serviceId;
- the workload has no container with an `nvidia.com/gpu` limit;
- it names two or more GPU pools;
- its ready-replica count is missing or 0.

A skipped service keeps its last decision. A service without
`maximumDeployment` is never seeded, so it does not appear in `/decisions` at
all. The first
time decision-gen sees a service, it seeds the service from the workload's
`spec.replicas`, clamped to the CR's `[min, max]`.

If any declared TTFT/OTPS series is missing, or a job's queue series is
missing, the service holds. A quantile that is NaN because there was no traffic
counts as **comfortable**, not missing.

After that check, the rules run in order and the first match wins:

| Rule | Condition | Gate | New count |
| --- | --- | --- | --- |
| `r1a-fire` | 429 rate ≥ `REJECTION_THRESHOLD` and ≥ `R1A_MIN_REJECTIONS_2M` rejections in 2 min | none | `max(ceil(current × multiplier), current + 1)` |
| `r1b-steady` | any declared TTFT/OTPS metric violated, with ≥ `R1B_MIN_REQUESTS_5M` requests in 5 min | `SCALE_UP_COOLDOWN_S` since last change | `current + max(1, ceil(current × SCALE_UP_STEP_FRAC))` |
| `r1c-shed` | every declared metric comfortable, 429 rate < `REJECTION_OK_FLOOR` | `SCALE_DOWN_COOLDOWN_S` since last change **and** `SCALE_DOWN_COMFORT_S` of unbroken comfort | `current − max(1, ceil(current × SCALE_DOWN_STEP_FRAC))` |
| `rjob-step-up` / `rjob-shed` | queue per replica violated / comfortable | as `r1b` / `r1c` | same steps |

Then, in order:

1. **Clamp.** The result is clamped to the CR's `[min, max]`. Lowering `max`
   below the current decision applies at once, bypassing every cooldown.
2. **Direction freeze.** While ready replicas are below the last decision, the
   service is still growing and a decrease is ignored. While they are above
   it, the service is still draining and an increase is ignored.
3. **GPU allocation, per pool.**
   - Free GPUs = pool allocatable − Σ(decision × GPUs per replica) over the
     services decision-gen manages.
   - Increases are granted in `priority` order until the free GPUs run out.
   - A service that still falls short takes replicas from lower-priority
     services, never below their minimum.
   - If the sum of all minimums does not fit, decision-gen logs
     `UNDER-PROVISIONED` and honours the minimums anyway. The extra pods then
     stay `Pending`.
4. **Publish** at `/decisions`.

Consequences worth knowing:
- **A service that declares neither `ttft` nor `otps` never scales down.** Only
  the 429 rule can grow it.
- **The ledger and cooldown clocks live in memory.** After decision-gen
  restarts, every service is re-seeded and both cooldowns start over. The 429
  rule is not gated by cooldowns, so it can still fire.

### HTTP API

| Path | Answer |
| --- | --- |
| `GET /decisions` (also `/api/v1alpha1/decisions`) | `{"apiVersion": "llmscaling.inference.x-k8s.io/v1alpha1", "decisions": [{"namespace": …, "serviceId": …, "replicas": {"active": N}}]}`. Optional filters: `?namespace=` and `?serviceId=`. **503** until the first tick |
| `GET /healthz` (also `/health`) | 200 |
| `GET /readyz` | 503 until the first tick, then 200 |

### Chart values (`llm-slo-decision-gen`)

| Value | Default | Meaning |
| --- | --- | --- |
| `namespace` | `llm-scaler` | Where every object of the chart goes, whatever the release namespace |
| `decisionGen.enabled` | `true` | ServiceAccount, read-only ClusterRole (SLO CRs, nodes, Deployments, StatefulSets, LWS), Service `decision-gen`, Deployment `decision-gen` |
| `decisionGen.replicas` | `1` | Keep at 1: each replica keeps its own in-memory ledger |
| `decisionGen.image.repository` / `tag` / `pullPolicy` | `4pdosc/llm-scaler-decision-gen` / `0.7.0` / `IfNotPresent` | The helmfile sets the repository to `<registry>/llm-scaler-decision-gen` |
| `decisionGen.service.port` / `targetPort` | `80` / `http` | The service answers at `http://decision-gen.<namespace>.svc:80` |
| `decisionGen.container.port` / `name` | `8080` / `http` | Must match `PORT` |
| `decisionGen.probes.liveness` / `readiness` | `/healthz` / `/readyz`; delay 2s, period 10s, timeout 1s, 3 failures | |
| `decisionGen.resources` | requests 50m / 64Mi; limits 1 CPU / 256Mi | |
| `decisionGen.env` | `[]` | Environment, verbatim |
| `decisionGen.unstable.enabled` | `true` | A second Deployment and Service, **`decision-gen-unstable`**, from the same image (see below) |
| `decisionGen.unstable.replicas` / `env` / `resources` | `1` / `LOG_LEVEL=DEBUG` / requests 50m / 64Mi, limits 200m / 256Mi | |
| `sloApi.enabled` | `false` | Optional HTTP front end for editing SLO objects. The chart says the published image still looks for the CRD under its old API group, so leave it off |

**Why there are two decision-gen Deployments.** The chart runs a second copy
called `decision-gen-unstable`, with its own Service and label. It is there so
that a single model can opt into in-development decisions by pointing its
`scaler.serverAddress` at `http://decision-gen-unstable.llm-scaler.svc:80`,
while everything else keeps reading the stable `decision-gen`. By default it
runs the same image with `LOG_LEVEL=DEBUG`. Both copies are read-only, so
running both is harmless. Set `decisionGen.unstable.enabled: false` if you do
not want the second one.

The SLO CRDs ship in the chart's `crds/` directory with
`helm.sh/resource-policy: keep`.

## Operator (`llmscaleoperator` chart)

All scaling behaviour is set per `LLMScaler`. The operator has no global poll
interval and no dry-run mode.

| Value | Default | Meaning |
| --- | --- | --- |
| `manager.enabled` | `true` | Controller Deployment `<fullname>-controller-manager`, labelled `control-plane: controller-manager` |
| `manager.replicas` | `1` | With `--leader-elect`, only one replica acts at a time |
| `manager.image.repository` / `tag` / `pullPolicy` | `4pdosc/llm-operator` / `""` (follows `appVersion`) / `IfNotPresent` | The helmfile sets the repository to `<registry>/llm-operator` |
| `manager.args` | `["--leader-elect"]` | Extra flags |
| `manager.resources` | requests 10m / 64Mi; limits 500m / 128Mi | |
| `manager.terminationGracePeriodSeconds` | `10` | |
| `manager.affinity`, `nodeSelector`, `tolerations`, `podSecurityContext`, `securityContext` | non-root, read-only root FS | |
| `rbac.namespaced` | `false` | `true`: Role/RoleBinding, acting in the release namespace only |
| `rbac.helpers.enabled` | `false` | Admin/editor/viewer ClusterRoles for `LLMScaler` |
| `crd.enabled` / `crd.keep` | `true` / `true` | Install the CRD; keep it on uninstall |
| `metrics.enabled` / `port` / `secure` | `true` / `8443` / `true` | The operator's own `/metrics` |
| `prometheus.enabled` | `false` | ServiceMonitor for that endpoint |
| `certManager.enabled`, `networkPolicy.enabled` | `false` | |

Flags accepted by the controller:
- `--leader-elect` (off unless passed; the chart passes it)
- `--health-probe-bind-address` (`:8081`)
- `--metrics-bind-address` (the chart sets it)
- `--metrics-secure`
- `--enable-http2`
- `--metrics-cert-path` / `-name` / `-key`
- `--webhook-cert-path` / `-name` / `-key`
- the standard zap logging flags (`--zap-log-level` and so on)

## Examples

### Fixed replica count

```yaml
# engine chart values
replicaCount: 2
scaler:
  enabled: false          # no LLMScaler; the workload carries spec.replicas: 2
sloRequirement:
  enabled: false          # optional
```

`scaler.minReplicas == scaler.maxReplicas` also pins the count and keeps the
scaler in place. A stock `sglang` install is fixed at `minReplicas` too, but
only because no decision is found on each sync (see the note at the top).
Prefer one of the two explicit forms.

### Scale on queue depth or KV cache (Prometheus, no decision-gen)

```yaml
# vllm chart values
serviceMonitor:
  enabled: true                           # engine metrics must reach Prometheus
  labels: { release: kube-prometheus-stack }
scaler:
  enabled: true
  metricProvider: Prometheus
  serverAddress: http://prometheus-operated.monitoring.svc:9090
  minReplicas: 1
  maxReplicas: 4
  syncPeriodSeconds: 15
  metrics:
    - name: queue-depth                   # > 5 waiting requests per replica
      query: 'avg(avg_over_time(vllm:num_requests_waiting{__SCOPE__}[1m]))'
      target: "5"
    - name: kv-cache                      # > 80 % KV usage per replica
      query: 'avg(avg_over_time(vllm:kv_cache_usage_perc{__SCOPE__}[2m]))'
      target: "0.8"
  scaleDown:
    behavior: CacheAware
    stabilizationWindowSeconds: 300
    maxStepReplicas: 1
    deletionCostQuery: 'vllm:kv_cache_usage_perc{__SCOPE__} * 100'
```

- For SGLang, use `sglang:num_queue_reqs` and `sglang:token_usage`.
- Only the metric that drives scale-up should end in `or vector(0)`.
- On a guardrail metric, `or vector(0)` would turn "no data" into a real zero,
  and that zero could pull the fleet to `minReplicas` whenever the main
  metric fails.

### Scale on SLO targets (decision-gen)

Needs:
- `llmscaleoperator` and `llm-slo` installed.
- bodylog, bodylog-exporter (with `openrestyPoll.url` set, as it is by
  default) and a working `bodylog.host` on openresty. The exporter's series
  must reach the Prometheus at `PROM_URL`.
- `modelRoute.enabled: true` on the model.
- An `nvidia.com/gpu` request on the engine.
- GPU nodes labelled `nvidia.com/gpu.present=true` and
  `nvidia.com/gpu.product` (GPU feature discovery does this).

```yaml
# sglang chart values
scaler:
  enabled: true
  metricProvider: Custom
  serverAddress: http://decision-gen.llm-scaler.svc:80
  minReplicas: 1
  maxReplicas: 4                          # keep equal to the SLO bounds below; the
                                          # operator clamps decisions to these as well
  scaleDown:
    behavior: CacheAware
    stabilizationWindowSeconds: 120
    maxStepReplicas: 1
sloRequirement:
  enabled: true
  extraSpec:
    minimumDeployment: { value: 1 }
    maximumDeployment: { value: 4 }       # without this, decision-gen ignores the model
    priority: 5
    ttft:                                 # seconds
      default:
        metrics:
          - { type: p80, threshold: 2 }
    otps:                                 # tokens/s per request
      default:
        metrics:
          - { type: p80, threshold: 20 }
```

With the default decision-gen settings:
- **Scale-up on SLO miss.** If p80 TTFT goes over 2 s (with ≥ 20 requests in
  5 min), 15 % more replicas are added, at least one. This happens at most
  once every 15 min.
- **Scale-up on 429s.** A 429 rate ≥ 5 % (≥ 5 rejections in 2 min) grows the
  fleet by up to 1.2× straight away, or up to 1.5× if an SLO is also missed.
- **Scale-down.** 15 % of replicas are removed only when all of these hold:
  - p80 TTFT has stayed below 1 s **and** p80 OTPS above 40 tok/s for 20
    unbroken minutes;
  - 429s are below 0.1 %;
  - at least 30 min have passed since the last change.

The same `ttft` / `otps` targets also become the route's admission limits in
openresty. See [`routing-and-rate-limiting.md`](routing-and-rate-limiting.md).

### Check that it works

```bash
kubectl get llmscalers -A                  # MIN / MAX / CURRENT (ready) / DESIRED
kubectl get llmslo -A                      # MIN_REPLICAS / MAX_REPLICAS / PRIORITY -- MAX must be set
kubectl -n llm-scaler get deploy           # decision-gen and decision-gen-unstable

# what decision-gen wants (empty list = it manages nothing)
kubectl -n llm-scaler port-forward svc/decision-gen 8080:80 &
curl -s 'localhost:8080/decisions?serviceId=<serviceId>'

# why: one line per service per tick, with every reading, gate and hold reason
kubectl -n llm-scaler logs deploy/decision-gen | grep '<ns>/<serviceId>'

# what the operator did
kubectl -n llmscaleoperator-system logs -l control-plane=controller-manager \
  | grep -E 'Metric calculation|Custom provider decision|Scaling target|Deferring scaling|Scale-down (stabilized|step capped)|Failed to fetch'
```

What the decision-gen log tells you:

| In the log | Means |
| --- | --- |
| `CR missing maximumDeployment — unmanaged` | Set `maximumDeployment` |
| `placement unresolvable` | No GPU workload named after the serviceId |
| `hold-no-physical-data` | No `bodylog_service_replicas_ready`: check the ModelRoute and the bodylog pipeline |
| `hold-missing-signal …` | A declared SLO series is empty |
| `hold-cooldown-up`, `hold-cooldown-down`, `hold-comfort` | A gate has not opened yet |
| `freeze-ramp-up`, `freeze-in-drain` | The last change has not finished landing |

On the operator side, `no decision for serviceId` means decision-gen is not
managing that service.

### Pause or turn it off

**The operator overwrites a hand edit of `spec.replicas` on its next sync.**
Use one of these instead:

| To | Do | Effect |
| --- | --- | --- |
| Pin one model at N | `scaler.minReplicas` = `scaler.maxReplicas` = N, or `kubectl patch llmscaler <name> -n <ns> --type merge -p '{"spec":{"minReplicas":N,"maxReplicas":N}}'` | Every result clamps to N. Works for both providers; undo by restoring the bounds |
| Stop SLO scaling for one model | Remove `maximumDeployment` from its `LLMSLORequirement` | decision-gen drops the service; the operator finds no decision and holds, clamped to its own bounds |
| Stop scaling one model | `scaler.enabled: false`, with `replicaCount` set to the **current** count | The chart puts `spec.replicas: replicaCount` back on the workload, so any other value resizes the fleet on upgrade |
| Freeze all models | `kubectl -n llmscaleoperator-system scale deploy -l control-plane=controller-manager --replicas=0` | Nothing writes `spec.replicas`; hand edits stick. On restart the operator applies current recommendations at once |
| Take decision-gen away | Disable the `llm-slo` release | `Custom` scalers fail their fetch and hold (clamped); `Prometheus` scalers are unaffected |

Not verified: how `helm upgrade` reconciles `spec.replicas` when a live
release switches `scaler.enabled` from `true` to `false`.
