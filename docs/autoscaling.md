# Autoscaling

Each model can grow and shrink its number of engine replicas between a floor
and a ceiling you set. It scales up when requests miss the latency targets you
declare or start getting `429`s, and scales down when there has been spare
capacity for a while.

A replica is one engine pod, or one group of pods for a model that spans
several nodes.

## Before you start

- `enabled.llmOperator` and `enabled.llmslo` are on. Both are on by default.
- A Prometheus is available: `enabled.kubePrometheusStack: true`, or your own.
  An environment file copied from `environments/private.yaml.example` turns it
  off.
- Body logging works, because the scaling signals are derived from it. See the
  listener address in
  [openresty.md](openresty.md#body-logging-the-listener-address).
- The GPU nodes carry the `nvidia.com/gpu.product` label. The GPU operator's
  feature discovery sets it.

## Turn on autoscaling for a model

Add this to the model's values file:

```yaml
scaler:
  enabled: true
  minReplicas: 1
  maxReplicas: 4
sloRequirement:
  enabled: true
  extraSpec:
    minimumDeployment: { value: 1 }
    maximumDeployment: { value: 4 }       # required: without it the model never scales
    priority: 5
    ttft:                                 # time to first token, in seconds
      default:
        metrics:
          - { type: p80, threshold: 2 }
    otps:                                 # output tokens/s per request
      default:
        metrics:
          - { type: p80, threshold: 20 }
```

**`maximumDeployment` is the switch.** The charts do not set it, so a model
installed with defaults stays at `minReplicas`.

**Keep the two pairs of bounds equal**: `scaler.minReplicas` / `maxReplicas`
and `minimumDeployment` / `maximumDeployment`. The replica count always stays
inside both.


## Model settings

In the model's values file:

| Setting | Default | What it does |
| --- | --- | --- |
| `scaler.enabled` | `true` | `false` turns autoscaling off for this model; it then runs `replicaCount` replicas |
| `scaler.minReplicas` | `1` | Never fewer replicas than this |
| `scaler.maxReplicas` | `5` | Never more replicas than this |
| `scaler.scaleDown.stabilizationWindowSeconds` | `10` | Before scaling down, wait until no higher count has been asked for within this many seconds. Larger values make scale-down slower and steadier; `300` is a reasonable production value |
| `scaler.scaleDown.maxStepReplicas` | `0` | The most replicas removed in one step; `0` is no limit. `1` makes the fleet step down one replica at a time |
| `sloRequirement.extraSpec.minimumDeployment.value` | `1` | Floor for the scaling decision |
| `sloRequirement.extraSpec.maximumDeployment.value` | not set | Ceiling for the scaling decision. **Required** for the model to scale |
| `sloRequirement.extraSpec.priority` | `0` | `0`–`10`. When the cluster runs out of GPUs, higher-priority models get replicas first and may take them from lower-priority ones, down to those models' floors |
| `sloRequirement.extraSpec.ttft.default.metrics` | not set | Time-to-first-token targets, in **seconds**. `{type: p80, threshold: 2}` means 80 % of requests should get their first token within 2 s. `type` is one of `avg`, `p50`, `p80`, `p90`, `p95`, `p99` |
| `sloRequirement.extraSpec.otps.default.metrics` | not set | Output-speed targets, in tokens/s per request. `{type: p80, threshold: 20}` means 80 % of requests should decode at 20 tok/s or faster |

The same `ttft` and `otps` targets also set the route's admission limits in
openresty; see [openresty.md](openresty.md).

A model with neither `ttft` nor `otps` only scales up on `429`s and never
scales down.

## How it behaves

With the default cluster settings:

- **Targets missed**: if the p80 target is missed over 5 minutes (with at least
  20 requests), about 15 % more replicas are added, and at least one. This
  happens at most once every 15 minutes.
- **Requests rejected**: if 5 % or more of requests get `429` (at least 5 in
  2 minutes), the fleet grows at once, by up to 1.5×, and by at least one
  replica.
- **Spare capacity**: about 15 % of replicas are removed, at least one, when
  for 20 minutes every target has been met with plenty of room (TTFT under half
  its threshold, output speed over twice its threshold), almost no requests
  were rejected, and 30 minutes have passed since the last change.

## Cluster-wide settings

These apply to every model. They are environment variables of decision-gen,
set as `decisionGen.env` in the values of the `llm-slo` release
(`llm-operator/llmslo-images.yaml.gotmpl`):

| Variable | Default | What it does |
| --- | --- | --- |
| `DEFAULT_GPU_POOL` | unset | GPU type assumed for a model that does not pin one through node affinity or `nodeSelector`. Unset means the cluster's largest GPU type with a schedulable GPU. **On a cluster with several GPU types, set it to one `nvidia.com/gpu.product` value** if unpinned models should stay on that type |
| `PROM_URL` | `http://kube-prometheus-stack-prometheus.monitoring:9090` | The Prometheus to read signals from |
| `SCALE_UP_COOLDOWN_S` | `900` | Minimum seconds between a change and a scale-up for missed targets |
| `SCALE_DOWN_COOLDOWN_S` | `1800` | Minimum seconds between a change and a scale-down |
| `SCALE_DOWN_COMFORT_S` | `1200` | How long targets must be met comfortably before a scale-down |
| `REJECTION_THRESHOLD` | `0.05` | Share of `429`s that triggers an immediate scale-up |

```yaml
# llm-operator/llmslo-images.yaml.gotmpl
decisionGen:
  env:
    - { name: DEFAULT_GPU_POOL, value: NVIDIA-A100-SXM4-80GB }
```

## Fixed replica count, or pausing

Editing `spec.replicas` on the workload by hand does not stick: it is set back
within seconds. Use one of these instead:

| To | Do |
| --- | --- |
| Run a model at a fixed count | `scaler.enabled: false` and `replicaCount: N` in its values |
| Pin a model at N for now | `kubectl -n <ns> patch llmscaler <model> --type merge -p '{"spec":{"minReplicas":N,"maxReplicas":N}}'`; restore the bounds to resume |
| Freeze every model | `kubectl -n llmscaleoperator-system scale deploy -l control-plane=controller-manager --replicas=0`; scale it back to 1 to resume |

When switching a running model to `scaler.enabled: false`, set `replicaCount`
to the number it runs now, or the upgrade resizes it.

## Check that it works

```bash
kubectl get llmscalers -A        # MIN / MAX / CURRENT / DESIRED per model
kubectl get llmslo -A            # MAX_REPLICAS must be set

# the count decision-gen wants for each model; an empty list means it manages none
kubectl -n llm-scaler port-forward svc/decision-gen 8080:80 &
curl -s localhost:8080/decisions

# why it wants that count: one line per model per minute
kubectl -n llm-scaler logs deploy/decision-gen | grep '<namespace>/<model>'
```

| decision-gen log says | Do |
| --- | --- |
| `CR missing maximumDeployment — unmanaged` | Set `maximumDeployment` |
| `hold-no-physical-data` | Body logging is not reaching decision-gen; check the listener address |
| `hold-missing-signal` | A declared target's series is missing in Prometheus; check that bodylog-exporter is scraped. A model with no traffic does not cause this |
| `hold-cooldown-up`, `hold-cooldown-down`, `hold-comfort` | Waiting out a cooldown; nothing to do |
