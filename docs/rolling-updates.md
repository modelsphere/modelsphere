# Updating a running stack without dropping requests

This page covers updating one component of the serving path while it takes
traffic: a model's engine, CART, openresty, autoconfig, bodylog, the operators,
and the CRDs. For each component it answers three questions:

- What counts as an update?
- What keeps requests flowing while it rolls?
- Where do requests still fail, and what do you do about it?

The index of the configuration docs is [configuration.md](configuration.md). How
requests are routed is in
[routing-and-rate-limiting.md](routing-and-rate-limiting.md), CART is covered in
[cart.md](cart.md), and installing a model is in
[deploy-a-model.md](deploy-a-model.md). The LLMScaler is covered in
[autoscaling.md](autoscaling.md).

**Most failures come from engine rollouts, not from rolling the routers.** On
the test cluster, every gateway component rolled without dropping a single
request. The engine with chart defaults did drop requests. The fix is two values
in the model's release; see [Engine](#engine-sglang--vllm-deployment).

Some sections are based only on the charts and the code, and say so. The rest
were measured; see [Measured](#measured).

## Why the routers learn late

A request reaches an engine like this (the default ModelRoute the sglang and
vllm charts render with `cart.enabled` and `modelRoute.enabled`):

```
client ─▶ openresty ─▶ tier 3: CART Service ─▶ engine pod IPs from CART's workers.yaml
                   ├─▶ tier 2: engine pod IPs (in openresty's route conf)
                   └─▶ tier 1: engine Service ClusterIP ("backend-svc")
```

Kubernetes does not update CART's worker list or openresty's list of pod IPs.
autoconfig updates them, through these steps:

```
EndpointSlice changes ─▶ autoconfig writes a ConfigMap
  ─▶ kubelet syncs the mounted volume ─▶ reload sidecar sends SIGHUP ─▶ reload
```

The kubelet sync is the slow step. On the test cluster, openresty picked up a
new engine pod about 16s after the rollout finished, while **CART took 65–80s**.
During that window CART sends every request to whatever pod IPs it last saw,
**including a pod that is already being deleted**.

That is why the engine's shutdown settings have to be sized to the router delay,
not to the Service.

## Engine (SGLang / vLLM, Deployment)

**What counts as an update:** an image bump, a chart bump, or any value that
changes the pod template (`extraArgs`, `model.*`, resources, env, the
hang-watcher image). Each of these replaces every engine pod of the release.

```bash
make helm-diff  SELECTOR=name=<model> MODELS=models/<file>.yaml
make helm-apply SELECTOR=name=<model> MODELS=models/<file>.yaml
kubectl -n <ns> rollout status deploy/<fullname> --timeout=30m
```

Watch the rollout with `rollout status`. `helmfile apply` cannot tell you when
it is done: `helmDefaults.wait` is false, so it returns as soon as the objects
are written, long before a model has loaded.

These changes do not restart the engine:

- **`hangWatcher.config.*`**: the sidecar hot-reloads its ConfigMap.
- **`modelRoute.*`**: autoconfig rewrites the route, and openresty reloads it.
- **`cart.*`**: this touches only CART; see [CART](#cart).

### What keeps requests flowing

- **Surge first.** `maxSurge: 1, maxUnavailable: 0`. A new pod starts, loads the
  model, and passes its probes before an old pod is deleted:
  - the startupProbe gives it a budget of 30 × 10s;
  - readiness then checks SGLang's `/health_generate`, which is a real
    one-token check, together with the hang-watcher sidecar's readiness.
- **preStop drain.** The deleted pod first keeps serving for
  `endpointSyncSeconds`. It then polls its own `/metrics` until nothing is
  running or queued, waiting at most `drainSeconds`.
- **Engine behaviour after SIGTERM.**
  - SGLang keeps serving and drains. The hook sends SIGTERM itself and kills the
    engine's children after `shutdownReserveSeconds`.
  - vLLM with the default `shutdownTimeout: 0` aborts whatever is still running.
- **Render-time checks.** The chart refuses a `terminationGracePeriodSeconds`
  smaller than `endpointSyncSeconds + drainSeconds + shutdownReserveSeconds`
  (on vLLM, `+ shutdownTimeout`). It also refuses a `progressDeadlineSeconds`
  that does not clear the startup budget.

### The default is sized for a plain ClusterIP, not for this stack

`endpointSyncSeconds: 5` is how long kube-proxy or Cilium needs to stop sending
new connections to a deleted pod. That is not the path requests take here: CART
and openresty route by pod IP and hear about the deletion 65–80s later. With the
defaults (grace 60, endpointSync 5, drain 30), this is what the test cluster
showed:

- CART kept sending every request to the old pod after it was deleted.
- SGLang kept serving those requests, so the drain never went idle.
- The pod was killed at the end of its grace period.
- **The six streams in flight at that moment were cut.**

The rollout itself finished in 92s. The `backend-svc` tier was never used.

**Set these in every model release:**

```yaml
terminationGracePeriodSeconds: 150
lifecycle:
  preStop:
    endpointSyncSeconds: 90   # >= how long the routers take to drop the pod
    drainSeconds: 30
  shutdownReserveSeconds: 20  # 90 + 30 + 20 = 140 <= 150
```

With this setting the same rollout had **zero failures** across about 1,800
overlapping requests, including 16 long streams. Traffic moved to the new pod
about 27s after the old one was deleted, and the old pod kept serving until
then.

The trade-off is that a deleted pod holds its GPUs for up to
`terminationGracePeriodSeconds`. Raise `drainSeconds`, and the grace period with
it, if your responses stream for longer than about 30s. For vLLM, the equivalent
values are the same keys plus `lifecycle.shutdownTimeout`. Unverified: the vLLM
chart was not tested.

### Where requests can still fail

- **Not enough GPUs to surge** (from the chart; not tested). Surge needs one
  spare replica's worth of `model.gpus`. Without it, the new pod stays Pending
  and the old pods keep serving. After `progressDeadlineSeconds` (1800) the
  rollout is marked `ProgressDeadlineExceeded`; it is not rolled back.
  - With two or more replicas, set `maxSurge: 0, maxUnavailable: 1`. This costs
    one replica's capacity while the rollout walks the fleet.
  - With **one replica**, `maxUnavailable: 1` or `type: Recreate` is a
    **full outage** for the whole model load time. Plan a window for it.
- **Keep the `backend-svc` tier.** This is the one route to the engines that no
  controller has to update. If autoconfig is down while an engine rolls, it
  is the only route still pointing at a live pod. The chart renders it by
  default; do not drop it from `modelRoute.nginx.peers`.
- **Streams do not survive a dead backend.** Once tokens are flowing, nginx and
  CART cannot retry a request elsewhere: they retry only before the first byte.
- **A cut stream can still be a 200.** A vLLM stream aborted at SIGTERM ends
  early with status 200. Check for `data: [DONE]`, not just the status code.
- **With the LLMScaler on, the chart does not render `spec.replicas`.** The
  operator owns that field; see [autoscaling.md](autoscaling.md).
- **Upgrade with the full values file (`-f`), not `--reuse-values`.**
  `--reuse-values` replays only the values you supplied last time and leaves out
  keys a newer chart added. If you want reuse, use `--reset-then-reuse-values`.

## Engine (SGLang, LeaderWorkerSet)

This section comes from the chart; it was not tested.

With `lws.enabled`, `lws.rolloutStrategy` controls the rollout. The default is
`maxSurge: 1, maxUnavailable: 0`, where one unit is a whole group of `lws.size`
pods.

- The Service selects only `role: leader`.
- Workers carry no probes, so a group is ready when its leader is.
- On teardown, the leader goes first. Its preStop:
  - drains, as in the Deployment case;
  - sends SIGTERM to the engine;
  - after `shutdownReserveSeconds`, kills the engine's children
    (`lws.leaderPreStopKill`). Without this last step, a leader stuck in a
    cross-node collective would hold its GPUs until the grace deadline.
- Workers follow, with `workerTerminationGracePeriodSeconds: 60`.

Where it fails:

- **Surge needs a whole spare group.** Without one, the surge group stays
  Pending. With a single group, `maxUnavailable: 1` is an outage.
- **The router delay applies here too,** so use the same `endpointSyncSeconds`
  and grace settings as for the Deployment.
- **A leader stuck in the GPU driver** (D state) ignores SIGKILL, and the rollout
  waits until you deal with the node.
- **Schedule groups with Volcano** so a surge group lands whole or not at all;
  see `scheduler/volcano/README.md`.

The vLLM chart has no LWS mode.

## CART

CART is a subchart of the model's release (see [cart.md](cart.md)), so it is
updated by applying that release:

```bash
make helm-apply SELECTOR=name=<model> MODELS=models/<file>.yaml
kubectl -n <ns> rollout status deploy/<release>-cart
```

**Measured:** `rollout restart` of CART produced 0 failures.

### What keeps requests flowing

- **Master/standby.** There are two replicas, and both are Ready. The ha-gate
  sidecar in each pod competes for a Lease, and only the holder labels itself
  `cart-active=true`, which is what the Service selects.
- **Planned failover.** On SIGTERM, the leader releases the Lease but keeps its
  label, so its open streams are not reset. The standby takes the Lease within
  about a second and labels itself on its next 2s tick.
- **Graceful shutdown.** CART stops accepting new connections and waits for open
  ones to finish, up to `terminationGracePeriodSeconds: 3600`.
- **No reconfiguration needed.** openresty reaches CART through the Service, so a
  failover needs no route change. While there is no leader, openresty falls
  through to the engine tiers.

### Where requests can still fail

- **A hard kill loses what is in flight through that pod.** This covers a node
  loss or `kubectl delete --grace-period=0 --force`. With the leader
  force-deleted, new requests had 0 failures. The four requests in flight
  through it were lost, and they did not fail fast: they hung for about 300s
  until an idle timeout closed them.
- **A `baseConfig` change needs a restart** (from the code; not tested). On
  SIGHUP, CART accepts only changes to `workers`. If anything in `server`,
  `cache`, `health`, `proxy` or `circuit_breaker` changed, it logs a warning and
  keeps its old config. Because every later reload is compared against that
  old config, **worker-list updates are rejected too until the pod restarts**.
  After changing `cart.baseConfig`, always run:

  ```bash
  kubectl -n <ns> rollout restart deploy/<release>-cart
  ```

- **Bumping `versions.autoconfig` restarts every CART.** CART's two sidecar
  images follow that version (`models/images.yaml.gotmpl`), so the next model
  apply after the bump rolls every CART.
- **Affinity resets.** CART's prefix-affinity state lives in the process, so a
  failover starts cold. Expect the cache hit rate to dip for a while; this is
  not an error.

## openresty

**What counts as an update:**

- **Image bump.** The tags are pinned in `llmgateway/openresty.yaml.gotmpl`
  (`image.tag`, `reload.image`, `ha.image`), so bump them there as well as in
  `versions.openresty`.
- **Any value that ends up in the pod template.** This includes `bodylog.host`,
  which is an environment variable; nginx reads environment variables only at
  start, so the change needs a rollout.
- **Route config.** autoconfig owns it and it reloads on its own, so there is
  nothing to do.

```bash
make helm-diff  SELECTOR=name=openresty
make helm-apply SELECTOR=name=openresty
kubectl -n llm-route rollout status deploy/openresty
```

**Measured:** `rollout restart` produced 0 failures, including for long streams.

### What keeps requests flowing

- **Surge first.** `replicas: 2` with `maxSurge: 1, maxUnavailable: 0`, and a PDB
  of `minAvailable: 1`.
- **Master/standby, as for CART.** The Service selects `openresty-active=true`,
  and ha-gate labels a pod only while nginx answers on the admin port.
  - Gating is by label, not readiness. A readiness-gated standby would never be
    Ready, and `maxUnavailable: 0` would then stall the rollout forever.
  - Do not point a readinessProbe at ha-gate's `/healthz`: it returns 503 on
    the standby by design.
- **Graceful stop.** The image stops with SIGQUIT, nginx's graceful stop signal:
  stop accepting, let in-flight requests finish. A 5s preStop sleep comes
  first, and the grace period is 3600s.
- **Config changes reload, not restart.** On SIGHUP, nginx starts new workers
  and the old ones finish what they hold. A config that fails to load is
  rejected, and the old one stays active.

API keys also reload without a restart (from the chart and code; not tested).
Keys are mounted from a Secret, and the reload sidecar watches that mount. To
rotate:

1. Add the new key alongside the old one (`key1:owner1,key2:owner2`).
2. Move callers over.
3. Remove the old key.

This needs reload image 0.3.46 or later.

### Where requests can still fail

- **Router state starts empty on failover.** A failover resets connection
  counts, the health-check ban list, the adaptive-concurrency ceilings and the
  TTFT/TPS averages. Session affinity is a hash of the peer list, so it
  survives.
- **`kubectl port-forward svc/openresty` pins you to one pod.** That connection
  breaks when the pod goes. Test through the Gateway or from inside the
  cluster.
- **Frequent reloads leave old workers running.** Every engine pod event
  triggers a reload, and old workers stay alive as long as their longest
  stream. Watch openresty's memory while a model scales up and down a lot.

## autoconfig

```bash
kubectl apply --server-side -f <autoconfig chart>/crds/   # only if the CRD changed; see below
make helm-apply SELECTOR=name=autoconfig
```

**Measured:** `rollout restart` produced 0 failures.

autoconfig is not on the request path. openresty and CART keep the last
configuration it wrote. It runs two replicas with leader election, and every
reconcile rediscovers from scratch, so anything that changed while it was away
is picked up on its first pass. It also refuses to write an empty backend list.

Where it matters:

- **Don't roll autoconfig and a model at the same time.** Engine changes made
  while autoconfig is away reach the routers only when it comes back. In the
  meantime `backend-svc` is the route that still works.
- **Delete model releases before uninstalling autoconfig.** Every ModelRoute
  carries a finalizer that autoconfig removes. Uninstall the controller first,
  and deleting a model release leaves its ModelRoute stuck in `Terminating`.

## bodylog and bodylog-exporter

```bash
make helm-apply SELECTOR=name=bodylog
make helm-apply SELECTOR=name=bodylog-exporter
```

**Measured:** `rollout restart` of bodylog produced 0 failures.

Both are single replicas with `strategy: Recreate`:

- the listener owns a ReadWriteOnce volume or a node-local directory;
- two exporters would report every series twice.

Neither is on the request path: openresty sends body-log frames asynchronously
and buffers them while the listener is away. What you can lose during a restart
is records, not requests.

- Keep the listener's memory limit high. It replays the buffered backlog when it
  comes back, and a low limit turns that replay into an OOM crash loop.
- Keep its `nodeSelector` and `timezone` unchanged across upgrades.

If the listener receives nothing at all, the cause is not the upgrade; see
[routing-and-rate-limiting.md](routing-and-rate-limiting.md).

## Operators: llmscaleoperator and llm-slo

This section comes from the charts; it was not tested.

```bash
make helm-apply SELECTOR=name=llmscaleoperator
make helm-apply SELECTOR=name=llm-slo
```

Neither operator is on the request path. While they roll, replica counts stay
where they are, so don't upgrade them in the middle of a traffic peak that needs
a scale-up. The LLMScaler CRD ships in the chart's `templates/` and helm
upgrades it. The llm-slo CRDs ship in `crds/`, so see the next section.

## CRDs

This section comes from the charts; it was not tested.

| CRD | Ships in | Upgraded by `helm upgrade`? |
| --- | --- | --- |
| `modelroutes.routing.modelsphere.dev` | autoconfig chart, `crds/` | **No** |
| `llmslorequirements` / `jobslorequirements.inference.modelsphere.dev` | llm-slo-decision-gen chart, `crds/` | **No** |
| `llmscalers.autoscaling.modelsphere.dev` | llmscaleoperator chart, `templates/` | Yes |

Helm installs `crds/` once and never touches them again. ⚠️ If you skip the
manual step, the API server **silently prunes** any new field from every object
you apply, so a new feature looks like it does nothing. Apply the CRDs before
upgrading the controller that reads them:

```bash
helm pull modelsphere/autoconfig --version <new> --untar -d /tmp/ac
kubectl apply --server-side -f /tmp/ac/autoconfig/crds/
```

Use `--server-side` because client-side apply stores the whole CRD in an
annotation that large CRDs overflow. Adding fields is safe while objects exist;
renaming or removing them is a migration, not an upgrade.

## Summary

| Component | Default rollout | Measured | What to do |
| --- | --- | --- | --- |
| Engine (Deployment) | surge 1 / unavailable 0; grace 60, endpointSync 5, drain 30 | 6 of ~1,500 failed with defaults; 0 of ~1,800 with the settings below | `terminationGracePeriodSeconds: 150`, `endpointSyncSeconds: 90`; keep `backend-svc` |
| Engine (LWS) | one surge group | not tested | needs a spare group, or a window |
| CART | 2 replicas, master/standby | 0 failures on restart; a hard kill loses what is in flight through that pod | `rollout restart` after any `baseConfig` change |
| openresty | surge 1 / unavailable 0, master/standby, SIGQUIT | 0 failures, long streams included | bump tags in `llmgateway/openresty.yaml.gotmpl` |
| autoconfig | 2 replicas, leader election | 0 failures | not together with a model; CRDs first |
| bodylog | 1 replica, Recreate | 0 failures | keep the memory limit high |
| Operators | 1 replica | not tested | avoid traffic peaks |
| CRDs in `crds/` | not upgraded by helm | not tested | `kubectl apply --server-side` first |

## Before you roll

1. **Diff first.** `make helm-diff SELECTOR=name=<release>` shows whether the
   change touches the pod template (a rollout) or only config. If it touches
   CART's `baseConfig`, plan a `rollout restart` of CART as well.
2. **Check the release status.** `make helm-status` should say `ok` for the
   release, not `failed` or `pending-upgrade`.
3. **Check the engine's shutdown settings.** The model release should have
   `endpointSyncSeconds` of at least 90 and a grace period that covers the sum.
4. **Check GPUs for the surge.** There should be one replica's worth free (a
   whole group for LWS). If there is not, choose the strategy deliberately.
5. **Check that the routers can follow.** autoconfig should be Running, and
   `kubectl get mr -A` should show the ModelRoute Ready. Exactly one pod should
   carry `openresty-active=true` and one `cart-active=true`.
6. **Apply CRDs** if a chart with a `crds/` directory changed version.
7. **Roll one layer at a time.** Always upgrade with `-f`.
8. **Start a request loop** before the rollout (see below). Keep it running until
   about two minutes after `rollout status` returns, so the router reloads are
   covered.

## Measured

Test cluster:

- one node with 2× A10, Cilium 1.20 with its Gateway;
- sglang chart 0.8.0 running `v0.5.15-cu129` with Qwen2.5-0.5B, one engine
  replica;
- CART, openresty and autoconfig with two replicas each.

Load was four concurrent short streams (`max_tokens: 200`) plus two long ones
(3,000 tokens, `ignore_eos`), sent through the Gateway's NodePort with the
Gateway's `Host` header. A request counted as good only if it returned 200
**and** ended with `data: [DONE]`.

| Component | Action | Requests overlapping | Failures |
| --- | --- | --- | --- |
| Engine | `rollout restart`, chart defaults (grace 60, endpointSync 5, drain 30) | ~1,500 (4 short + 2 long) | **6**: every stream in flight when the old pod was killed at the end of its grace period |
| Engine | `helm upgrade` with `terminationGracePeriodSeconds: 150`, `endpointSyncSeconds: 90` | ~1,800 short + 16 long | **0** |
| CART | `rollout restart` | | 0 |
| CART | leader `delete --grace-period=0 --force` | | 0 new requests failed; the 4 in flight through that pod were lost, hanging ~300s until an idle timeout |
| openresty | `rollout restart` | long streams included | 0 |
| autoconfig | `rollout restart` | | 0 |
| bodylog | `rollout restart` | | 0 |

Timings from the default-settings engine run:

- The rollout, surging onto the spare GPU, finished 92s after it started.
- openresty reloaded its route about 16s after that.
- CART reloaded its workers 65–80s after that.

With the recommended settings, traffic reached the new pod about 27s after the
old pod was deleted.

Not tested:

- LeaderWorkerSet;
- vLLM;
- CRD upgrades;
- API key rotation;
- rollouts with no spare GPU.

### Running the check yourself

Send traffic the way clients do: through the Gateway, or from a pod against the
openresty Service. Don't use `kubectl port-forward`, which pins you to one pod.
Count a request as good only if it returns 200 and the stream ends with `[DONE]`.

```bash
URL=http://<gateway-address>:<nodeport>/<route>/v1/chat/completions
HOST=<gateway hostname>          # the Host the Gateway listener expects
AUTH="Authorization: Bearer <key>"
worker() {   # $1 = worker id, $2 = max_tokens
  while :; do
    code=$(curl -sS -N -m 600 -o /tmp/b.$1 -w '%{http_code}' \
      -H "Host: $HOST" -H "$AUTH" -H 'Content-Type: application/json' \
      -d "{\"model\":\"<served-model-name>\",\"stream\":true,\"max_tokens\":$2,\"ignore_eos\":true,
           \"messages\":[{\"role\":\"user\",\"content\":\"Count upwards.\"}]}" "$URL")
    echo "$(date +%s) w$1 code=$code done=$(grep -c '\[DONE\]' /tmp/b.$1)" >> /tmp/roll.log
  done
}
for w in 1 2 3 4; do worker $w 200 & done
for w in 5 6;     do worker $w 3000 & done
# ... roll the component, wait for rollout status + ~2 min, then:
kill $(jobs -p)
grep -v 'code=200 done=1' /tmp/roll.log | wc -l    # 0 = nothing dropped
```
