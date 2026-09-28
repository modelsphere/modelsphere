# Routing and rate limiting

This is the reference for the routing layer (llm-openresty). It covers how a
model gets a route, what decides whether a request is admitted, and which values
change that. [`configuration.md`](configuration.md) is the index of these
references. For the model side, see [`deploy-a-model.md`](deploy-a-model.md);
for the cache-aware router in front of the engines, see [`cart.md`](cart.md);
for scaling, see [`autoscaling.md`](autoscaling.md); for draining and rollouts,
see [`rolling-updates.md`](rolling-updates.md).

Versions described: openresty chart `0.1.20`, autoconfig `0.4.0`, and the
`sglang` / `vllm` charts pinned in `environments/default.yaml`.

Three things to know before reading the rest:

- **Nothing is queued.** A request over a limit gets an immediate `429` with
  `Retry-After: 1`. Retrying is the client's job.
- **Every LLM route has limits, even with no settings.** Adaptive concurrency
  is on, the decode-rate threshold is 20 tok/s, and the time-to-first-token
  (TTFT) hard limit is 30 s. Older notes call these opt-in; they are not.
- **A stock install has no API-key authentication.** See
  [Authentication](#authentication).

## Request path

```
client ──> Gateway / Service :8080 ──> openresty dispatch
               /<route>/v1/chat/completions
                     │  strips /<route>, forwards to unix socket <route>.sock
                     ▼
           per-route server (session_route_<route>.conf)
                     │  auth → rules → admission → peer pick
                     ▼
           CART (optional) ──> engine pods
```

**The first path segment is the route, not the model.** Send
`POST /<route>/v1/chat/completions`. The route defaults to the model release's
name (`qwen` for the example in [`deploy-a-model.md`](deploy-a-model.md)). An
unknown route has no socket, and openresty answers `502` with every component
healthy. Those failures are logged to `logs/dispatch.log` in the openresty
container.

```bash
curl -s http://llm.example.com/qwen/v1/chat/completions \
  -H 'Authorization: Bearer <key>' -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"hi"}]}'
```

Port 8090 serves only `GET /healthz`, for probes and ha-gate. It does not route.

## How a route comes to exist

```
engine chart values (modelRoute:)  ──helm──>  ModelRoute (routing.modelsphere.dev/v1alpha1)
                                                   │ autoconfig: every 10s and on endpoint changes
                                                   ▼
                        ConfigMap openresty-conf, key session_route_<route>.conf
                                                   │ mounted at conf.d/routes/
                                                   ▼
                        reload sidecar (2s debounce) ──SIGHUP──> nginx graceful reload
```

- **autoconfig updates the ConfigMap; it never creates it.** The `openresty`
  chart creates it. If it is missing, the ModelRoute shows `Ready=False`
  (`ConfigMapMissing`) and autoconfig keeps retrying.
- **Nothing is written when nothing changed**, so a stable route causes no
  reloads.
- **A reload is graceful.** In-flight streams finish on the old workers.
  Shared memory survives a reload: in-flight counters, bans, latency averages,
  runtime overrides. A pod restart clears it.
- **Deleting the ModelRoute removes its key**, through the finalizer
  `routing.modelsphere.dev/cleanup`.
- **When two ModelRoutes claim one route name, the older one keeps it.** The
  newer one shows `Ready=False, reason=RouteKeyConflict` and writes nothing to
  openresty.
- **Renaming `spec.nginx.route` writes the new key before removing the old
  one.** Keys that autoconfig cannot attribute are listed in
  `status.orphanRouteKeys` and are never deleted automatically.

```bash
kubectl get mr -A                        # Backends / CART / Ready
kubectl describe mr qwen -n llm-demo     # conditions: Ready, SLOSynced, OrphanRouteKey
kubectl -n llm-route get cm openresty-conf -o jsonpath='{.data.session_route_qwen\.conf}'
```

### ModelRoute fields that reach openresty

| Field | Default | Meaning |
| --- | --- | --- |
| `spec.modelType` | `llm` | `llm` uses the routing engine. `video` gets a plain reverse proxy ([Video routes](#video-routes)). |
| `spec.discovery.service` / `.selector` | exactly one required | The backend pods. `service` uses EndpointSlices and accepts `ns/name`. |
| `spec.discovery.port` | derived when there is a single port | Backend port. |
| `spec.discovery.includeNotReady` | `false` | Include endpoints that are not Ready. |
| `spec.cart` | absent = no CART | `service`/`selector`, `port`, `outputConfigMap` (required), `outputKey` (`config.yaml`), `maxLoad` (20). See [`cart.md`](cart.md). |
| `spec.nginx.route` | `metadata.name` | Route name: URL prefix, conf key, socket name. Must match `^[a-z0-9._-]+$`. |
| `spec.nginx.outputConfigMap` | required | `ns/name` of openresty's ConfigMap. |
| `spec.nginx.peers[]` | at least 1 | Ordered peer tiers, described below. |
| `spec.nginx.values` | `{}` | String map, at most 32 keys, rendered into the route's configuration. **Every tuning knob on this page is set here.** |
| `spec.nginx.service` / `.selector` | — | openresty's own Service. Used for monitoring only. |
| `spec.slo.name` | absent | The LLMSLORequirement whose targets become this route's limits ([SLO-declared limits](#slo-declared-limits)). |

Peer tiers, `spec.nginx.peers[]`:

| Field | Default | Meaning |
| --- | --- | --- |
| `use` | required | `cart` (the CART Service), `backend` (pod IPs), or `backend-svc` (the backend Service's ClusterIP). `backend-svc` is a static last resort that still works while autoconfig is down; it needs `discovery.service`. |
| `priority` | `0` | Higher is preferred. Traffic moves down a tier only when every peer above it is banned. |
| `maxConcurrency` | `values.default_max` (20) | Cap **per peer** in this tier. |
| `maxConcurrencyFromBackend` | `false` | `cart` only. The cap becomes backend `maxConcurrency` × number of backends, so it follows scaling. |
| `probePath` | `/health` for `cart`, otherwise `/v1/models` | The path the health check requests. |

When a route has a `backend-svc` tier, autoconfig adds
`cross_tier_fallback: "true"` and `max_more_tries: "3"`, unless you set them
yourself.

**How `values` are typed.** A value that parses as a number becomes a number,
`true`/`false` become booleans, and anything else becomes a string. Structured
settings cannot be expressed this way: the SLO metric tables, the request-rule
list and per-model maps. The SLO tables come only from `spec.slo`, and
`spec.slo` overwrites a hand-written `ttft_metrics` or `tps_metrics`.

### From the engine chart

The `sglang` and `vllm` charts render the ModelRoute from `modelRoute:`:

| Chart value | Default | Becomes |
| --- | --- | --- |
| `modelRoute.enabled` | `true` | The CR, created in the release namespace. |
| `modelRoute.name` | release name | `metadata.name`, and so the route name. |
| `modelRoute.discovery.includeNotReady` | `false` | `spec.discovery.includeNotReady`. The Service and port are always the release's own Service and `service.port`. |
| `modelRoute.nginx.route` | CR name | `spec.nginx.route` |
| `modelRoute.nginx.outputConfigMap` | **required** | e.g. `llm-route/openresty-conf`. Rendering fails without it. |
| `modelRoute.nginx.values` | `{expose_routed_peer: "true"}` | Merged with your keys. |
| `modelRoute.nginx.peers` | `backend` (priority 2, `maxConcurrency: 100`) and `backend-svc` (priority 1) | `spec.nginx.peers` |
| `cart.enabled` | `true` | Deploys this model's CART, fills `spec.cart`, and prepends a `cart` tier one priority above the rest. The tier gets `maxConcurrencyFromBackend: true` when a backend tier has a `maxConcurrency`. Writing your own `use: cart` peer turns the injection off. |
| `modelRoute.cart.maxLoad` | `20` | `spec.cart.maxLoad` |
| `modelRoute.slo.enabled` / `.name` | `true` / `serviceId` | `spec.slo.name` |

With the chart defaults, a route has three tiers. On a test install the
rendered `qwen` route had exactly these, plus `cross_tier_fallback = true` and
`max_more_tries = 3`:

| Priority | Peer | Cap |
| --- | --- | --- |
| 3 | CART, probed on `/health` | 100 × backends |
| 2 | each engine pod | 100 |
| 1 | the Service ClusterIP | `default_max` |

A model with tuned limits:

```yaml
modelRoute:
  enabled: true
  nginx:
    outputConfigMap: "llm-route/openresty-conf"
    values:
      default_max: "60"        # cap for peers without their own (e.g. backend-svc)
      tps_limit_tps: "25"      # decode-rate threshold, tok/s
      ttft_limit_ms: "20000"   # time-to-first-token threshold, ms
```

## Admission, in order

For each request to `/<route>/v1/...`, the checks below run in order. The first
one that rejects ends the request.

| # | Check | Response |
| --- | --- | --- |
| 1 | API key, when keys are loaded | `401 {"error":"missing or invalid api key"}` |
| 2 | Request rules, when configured and enabled | default `429` |
| 3 | Every peer banned | `503`, `Retry-After: 5` |
| 4 | Concurrency: in-flight ≥ limit × `rt_limit_factor` | `429 "concurrency limit exceeded"` |
| 5 | TTFT average at or over its threshold (a few probe requests are still let through) | `429 "ttft limit exceeded"` |
| 6 | Decode-rate average at or under its threshold (**only when adaptive concurrency is off**) | `429 "tps limit exceeded"` |
| 7 | Pick a peer and proxy, retrying on failure | upstream status |

`GET /v1/models` and `/health` skip checks 4–6, so health probes from an outer
layer are never rate-limited.

## Concurrency

- **Limit.** For each tier, add up the caps of its **healthy** peers. The limit
  is the largest of those tier sums.
- **In-flight.** Active requests on **all** of the route's peers, banned ones
  included, because their streams are still running.
- **429.** A request is rejected when in-flight ≥ limit × `rt_limit_factor`.

| `values` key | Default | Meaning |
| --- | --- | --- |
| `default_max` | `20` | Cap for peers without a `maxConcurrency`. |
| `rt_limit_factor` | `1` | Multiplier applied to the limit before rejecting. |

The 429 body carries `realtime`, `limit`, `healthy_peers`, `active_level` and
`route`. With adaptive concurrency it also carries `pool_limit` and
`adaptive_cc`.

### Adaptive concurrency

**It is on for every LLM route.** It turns on whenever a route has a
decode-rate threshold, and the built-in default of 20 tok/s gives every route
one. To turn it off, set `adaptive_cc: "false"`.

While it is on:

- **The effective limit is `min(adaptive_cc, static limit)`.** Before
  `adaptive_cc` has a value, the limit is the floor.
- **Every `adaptive_cc_interval`, `adaptive_cc` is adjusted.**
  - It **shrinks** (× `dec`) when the decode-rate average drops below its
    threshold or the TTFT average rises above its threshold.
  - Otherwise it **grows** (× `inc`) if the last interval had concurrency 429s.
  - Otherwise it **follows real concurrency**, keeping headroom between
    `slack_frac` and `pressure_frac` and at least `abs` slots.
- **It is clamped** between the floor and the static limit.
- **With no recent decode-rate samples it is left alone.** It expires after
  `adaptive_cc_ttl`, and the route falls back to the floor.
- **The decode-rate hard 429 (step 6 above) is off** while adaptive
  concurrency is on.

| `values` key | Default | Meaning |
| --- | --- | --- |
| `adaptive_cc` | on | `"false"` switches back to the static limit plus the decode-rate 429. |
| `tps_limit_tps` | `20` tok/s | The threshold driving it. |
| `adaptive_cc_min` | unset | Absolute floor (integer ≥ 1). |
| `adaptive_cc_min_frac` | `0.4` | Floor when `adaptive_cc_min` is unset: static limit × this. |
| `adaptive_cc_interval` | `20` s | Seconds per step. |
| `adaptive_cc_dec` / `adaptive_cc_inc` | `0.97` / `1.02` | Multipliers for shrinking and growing. |
| `adaptive_cc_ttl` | `300` s | How long a value lives without refresh. |
| `adaptive_cc_pressure_frac` / `adaptive_cc_slack_frac` | `0.9` / `0.7` | Grow and shrink bands. |
| `adaptive_cc_abs` | `5` | Minimum headroom in slots. |
| `adaptive_cc_use_ttft` | on | `"false"` stops high TTFT from shrinking the limit. |

**When it first applies, a route drops to about 40 % of its static limit and
climbs 2 % every 20 s.** Reaching full capacity takes around 15 minutes. A
threshold above what the backend can deliver keeps the limit at the floor, and
nothing alerts on it. Watch `/_tps_status`.

**Decode-rate samples need `usage` in the response.** openresty does not add
`stream_options.include_usage` to streaming requests on these routes. Streams
whose clients do not ask for usage therefore produce no sample; they only
increment `nousage_samples`.

On a test install, about six concurrent streams without `include_usage` showed
the following, and no 429 at that load:

| Field | Value |
| --- | --- |
| `adaptive_cc_on` | `true` |
| `tps_limit_source` | `global_default` |
| `adaptive_cc_min` / `adaptive_cc_max` | `40` / `100` |
| `adaptive_cc_conc` | `5` |
| `nousage_samples` | `589` |
| `adaptive_cc_rej` | `0` |

If your clients stream without usage:

1. Watch `nousage_samples` and whether `adaptive_cc` ever gets a value.
2. Either make sure usage is returned, or set `adaptive_cc: "false"` on that
   route.

## TTFT and decode-rate limits

Both limits keep a running average for each route:

- **Every `window` seconds**, a quantile of that window's samples is folded
  into the average with weight `alpha`.
- **While a route is over its limit**, `probe_per_window` requests per
  `probe_window` seconds still pass through, so the average can recover.
- **The average expires `ttl` seconds after the last sample**, so a route that
  goes idle is released.

| | TTFT | Decode rate (TPS) |
| --- | --- | --- |
| Sample | Time to first chunk. **Streaming** 2xx only. | `completion_tokens` ÷ total request time. Any 2xx that returns usage, at least 16 tokens and 0.5 s long. |
| Over the limit when | average ≥ threshold | average ≤ threshold |
| Threshold | `ttft_limit_ms`, `30000` | `tps_limit_tps`, `20` |
| Window / alpha / ttl | `ttft_window` 20 s / `ttft_ewma_alpha` 0.3 / `ttft_ttl` 60 s | `tps_window` 20 s / `tps_ewma_alpha` 0.3 / `tps_ttl` 60 s |
| Probes | `ttft_probe_window` 10 s, `ttft_probe_per_window` 5 | `tps_probe_window` 10 s, `tps_probe_per_window` 5 |
| Hard 429 | on; `ttft_429_default_enabled: "false"` keeps only the adaptive signal | only with `adaptive_cc: "false"` |

There is no requests-per-second limiter for LLM routes. Load is controlled
through concurrency and these two signals.

## SLO-declared limits

An `LLMSLORequirement` (`inference.modelsphere.dev/v1alpha1`, short name
`llmslo`) sets a route's thresholds when the ModelRoute names it in
`spec.slo.name`. autoconfig only reads it, and only `ttft` and `otps`. The
`priority`, `minimumDeployment` and `maximumDeployment` fields belong to
[autoscaling](autoscaling.md).

```yaml
apiVersion: inference.modelsphere.dev/v1alpha1
kind: LLMSLORequirement
metadata: { name: qwen, namespace: llm-demo }
spec:
  serviceId: qwen
  ttft:
    default:
      metrics:
        - { type: p80, threshold: 20 }   # 80% of requests: TTFT <= 20 s
  otps:
    default:
      metrics:
        - { type: p80, threshold: 30 }   # 80% of requests: >= 30 tok/s
```

- **`type`** is one of `avg`, `p50`, `p80`, `p90`, `p95`, `p99`.
- **Units.** `ttft.threshold` is in seconds and `otps.threshold` is in tok/s.
- **Any metric in violation triggers the limit**; the metrics are OR'ed.
- **`ranges[]` is ignored.** The route's `SLOSynced` condition says so.
- **The effective threshold is the first of these that exists:**
  1. the declared SLO table;
  2. a runtime override ([Changing limits at runtime](#changing-limits-at-runtime));
  3. the route's `values`;
  4. the built-in default.

  While a table is declared, a runtime override has no effect, and the status
  endpoints report it under `ignored_override`.
- **Changing the object** rewrites the route and reloads openresty. No restart
  is needed.

The `SLOSynced` condition on the ModelRoute reports the result. SLO problems
never make the route `Ready=False`; the route falls back to its static
thresholds.

| Reason | Meaning |
| --- | --- |
| `Synced` | Thresholds applied. |
| `NoRequirement` | No LLMSLORequirement with that name. |
| `NothingApplicable` | It exists but has no `default.metrics`. |
| `TranslateError` | Unknown `type`, negative threshold, or empty name. |

**The engine charts create an LLMSLORequirement with only `serviceId`**
(`sloRequirement.enabled: true`). The route then reports `NothingApplicable`
and uses its static thresholds. To declare targets, put them in
`sloRequirement.extraSpec` in the CRD's own shape. The commented
`ttftMs`/`tpotMs` example in the chart values is not that shape.

```yaml
sloRequirement:
  extraSpec:
    ttft: { default: { metrics: [ { type: p80, threshold: 20 } ] } }
    otps: { default: { metrics: [ { type: p80, threshold: 30 } ] } }
```

## Changing limits at runtime

The endpoints below take effect immediately, with no reload. They apply to all
workers and survive reloads, but **not** a pod restart or a failover to the
standby replica.

- **Everything is per route.** The path is `/<route>/_...`; bare `/_tps_status`
  is `404`.
- **Write endpoints accept only 127.0.0.1**, so run them from inside the active
  pod. `curl` is in the image.

```bash
POD=$(kubectl -n llm-route get pod -l openresty-active=true -o name | head -1)
kubectl -n llm-route exec $POD -c openresty -- \
  curl -s 'http://127.0.0.1:8080/qwen/_tps_limit?tps=15&ttl=3600'
```

| Endpoint | Parameters | Effect |
| --- | --- | --- |
| `/_ttft_limit` | `ms=<n>` (0 clears), `model=`, `ttl=<s>` (default 7200, 0 = never expires) | Override the TTFT threshold. |
| `/_tps_limit` | `tps=<n>` (0 clears), `model=`, `ttl=` | Override the decode-rate threshold (this also drives adaptive concurrency). |
| `/_ttft_toggle` | `on=0\|1` | Turn TTFT limiting off or on for this route. |
| `/_ttft_429_toggle` | `on=0\|1` | Turn off only the TTFT hard 429; the adaptive signal stays. |
| `/_tps_toggle` | `on=0\|1` | Turn off decode-rate handling **and adaptive concurrency**. The limit returns to the full static limit. |
| `/_active_conns_set` | `peer=ip:port&value=N`, `&delete=1`, or `flush=1` | Repair leaked in-flight counters. |
| `/_429_status?reset=1` | | Reset the 429 counters. |
| `/_reject_rules_toggle` | `on=0\|1` | Turn the request rules on or off. |

## Peer selection, health and retries

### Session affinity

Session affinity is **off by default**. Every request goes to the healthy peer
with the lowest active ÷ cap ratio, with ties broken at random.

With `session_affinity_enabled: "true"`, a request that carries a session id is
pinned to one peer by hash. If that peer is at its cap, the request falls back
to least-connections. The session id is taken from the first of:

1. the `x-litellm-session-id`, `x-claude-code-session-id` or `x-session-id`
   header;
2. `metadata.session_id`;
3. `metadata.user_id.session_id`;
4. `metadata.user_id`;
5. the body field `user` (ignored unless `disable_body_user_affinity: "false"`).

### Health checks

Every `health_check_interval` (10 s), openresty requests each peer's probe path.
The request times out after 10 s.

- **Banned:** a failed connection, or any status other than 200 or 429.
- **Kept alive:** a timeout or a `429`. The peer is busy, not down.
- **Unbanned:** on the next 200. `health_ban_ttl` (300 s) only bounds how long a
  ban lives without renewal.
- **Only the highest tier that still has a healthy peer takes traffic.**

| `values` key | Default |
| --- | --- |
| `health_check_interval` | `10` s |
| `health_ban_ttl` | `300` s |
| `health_probe_path` | `/v1/models`; `peers[].probePath` overrides it per tier |

### Retries and timeouts

| Setting | Value |
| --- | --- |
| Retry on | connect error, timeout, 502, 503 (POST included) |
| Retry budget | `max_more_tries`, `2` (`3` with a `backend-svc` tier); 60 s total |
| `cross_tier_fallback` | `false` (`true` with a `backend-svc` tier): a retry may drop to the next tier down instead of waiting for a ban |
| Connect timeout | 2 s |
| Read / send timeout | 3600 s |
| Request body | 10 MB per route, then `413` |

Only `max_more_tries` and `cross_tier_fallback` are `values` keys. The rest are
part of the image.

### Request rules

Request rules reject requests by content, for example on `max_tokens`,
`stream`, `input_bytes`, `input_chars` or a body path. The default status is
`429` (`reject_rules_status`). They are **off by default**
(`reject_rules_default_enabled`). The rule list is a structured value, so it
cannot be set through a ModelRoute; it applies only to hand-maintained route
configuration.

### `X-Routed-Peer`

With `expose_routed_peer: "true"`, which the engine charts set by default,
responses carry `X-Routed-Peer: <ip:port>|<gpu>|<node>`. With a CART in the
path, the header names the real backend. Set it to `"false"` on routes whose
callers should not see your internal addresses.

## Observing the routing layer

Every endpoint below is per route (`/<route>/...`). The read-only ones have
**no authentication and no IP restriction**, so anyone who can reach 8080 can
read them. Restrict `/<route>/_*` at the Gateway if 8080 is exposed.

| Endpoint | Shows |
| --- | --- |
| `/_health_status` | `active` and `banned` per peer. `_meta.api_keys_configured`, `route_auth_enabled`, `key_file_status` (`ok` / `missing` / `unreadable` / `empty`). |
| `/_route_state` | Active tier, limit, and each tier's healthy / banned / active / max. |
| `/_tps_status` | Decode-rate average, `tps_limit_source`, `nousage_samples`, and every `adaptive_cc_*` value. |
| `/_ttft_status` | TTFT average, `enforcing`, `ttft_429_enabled`, the metric sources. |
| `/_429_status` | 429 counts by route and reason: `concurrency`, `ttft`, `tps`, `rule`. |
| `/_route_debug?sid=`, `POST /_route_inspect` | Which peer a session or request would go to, without sending it. |
| `/_bodylog_status` | Whether body capture is on, and its write / drop counters. |

`tps_limit_source` says where the decode-rate threshold comes from:

| Value | Source |
| --- | --- |
| `declared` | The SLO. |
| `override` | `/_tps_limit`. |
| `route` | The route's `values`. |
| `global_default` | The built-in 20 tok/s. |

The same split appears per metric in `metrics[].source` (`declared`,
`override`, `static`).

## Authentication

Clients send `Authorization: Bearer <key>`. Keys are read from a file:

- **Location:** `/etc/openresty/api-keys/keys`, mounted from a Secret.
- **Format:** `key1:owner1,key2:owner2`.
- **Re-read on every reload.** To rotate, add the new key next to the old one,
  move the callers over, then remove the old key.

**No key file means no authentication.** openresty lets every request through,
logs an error at start-up and reports it in `/_health_status`. This is
deliberate: a broken Secret must not turn the whole site into 401s. **A stock
install of this repo sets no Secret.** A test install reported:

```
_meta: key_file_status=missing, api_keys_configured=false, route_auth_enabled=false
```

Alert on `api_keys_configured=false`.

To turn authentication on:

1. Create the Secret. The entry must be named `keys`.

   ```bash
   kubectl -n llm-route create secret generic openresty-api-keys \
     --from-literal=keys='<key-1>:team-a,<key-2>:team-b'
   ```

2. Add this to `llmgateway/openresty.yaml.gotmpl` and apply:

   ```yaml
   existingSecret: openresty-api-keys
   ```

The Secret is mounted as a directory, and the reload sidecar reloads nginx when
it changes. No restart is needed.

The status endpoints (`/_*`) are never authenticated.

## Body logging: the listener address

openresty ships request and response bodies to the bodylog listener at
`bodylog.host`. **The host must be the fully qualified name
`bodylog.<namespace>.svc.cluster.local`.** nginx's resolver does not apply DNS
search domains, so a shorter name never resolves. When it does not resolve:

- frames are dropped with no error on the request path;
- `/<route>/_bodylog_status` still shows `enabled=true` and a growing
  `write_count`.

**Known issue:** `llmgateway/openresty.yaml.gotmpl` sets
`host: bodylog.llm-route.svc`. On a test install, openresty reported thousands
of writes while the listener received nothing. The fix:

```yaml
# llmgateway/openresty.yaml.gotmpl
bodylog:
  host: bodylog.llm-route.svc.cluster.local
```

**To check that records are arriving,** query the listener's `/summary` on its
HTTP port (9998, plus its token if one is configured). `peers` must be
non-empty, and files should appear under the listener's data directory.
`write_count` on the openresty side is not proof: it counts frames handed to
the sender, not frames that arrived.

## openresty chart values

| Value | Default | Notes |
| --- | --- | --- |
| `replicas` | `2` | With `ha.enabled`, a master/standby pair. |
| `ha.enabled` | `true` | ha-gate holds the Lease `<fullname>-ha` and labels the leader `openresty-active=true`. The Service selects only that label, so **one replica serves**. Counters, bans and adaptive state live in that pod's memory. |
| `ha.appTcp` | `127.0.0.1:8090` | The leader must answer here before it labels itself active. |
| `reload.enabled` | `true` | Watches `conf.d/routes/` and the key Secret, and reloads 2 s after a change. Without it, route changes wait for a manual reload. |
| `configMapName` | `openresty-conf` | Must match `modelRoute.nginx.outputConfigMap` (`llm-route/openresty-conf`). |
| `initialRoutes` | `{}` | Seed route configs, for running without autoconfig. |
| `existingSecret` / `secret.create` + `secret.keys` | empty | API keys; see [Authentication](#authentication). |
| `service.ports` | `dispatch: 8080`, `health: 8090` | autoconfig looks up the port **named** `dispatch`. |
| `resources` | requests 2 CPU / 2Gi, limits 20 CPU / 32Gi | The image runs 20 nginx workers. |
| `terminationGracePeriodSeconds` | `3600` | nginx stops gracefully, so streams can drain for up to an hour. See [`rolling-updates.md`](rolling-updates.md). |
| `preStop.sleepSeconds` | `5` | Time for endpoint removal to propagate. |
| `updateStrategy` | `maxSurge: 1`, `maxUnavailable: 0` | |
| `podDisruptionBudget.minAvailable` | `1` | |
| `bodylog.host` / `.port` | `bodylog.llm-route.svc.cluster.local` / `9999` | `""` turns capture off. |

This repo's overrides live in `llmgateway/openresty.yaml.gotmpl`. They set
`fullnameOverride: openresty`, the image tags and `bodylog.host` (see the known
issue above).

The built-in defaults, such as the 30 s TTFT threshold, 20 tok/s and session
affinity off, are part of the image. There is no chart value for them;
override them per route through `nginx.values`.

## Video routes

A ModelRoute with `modelType: video` is rendered as a plain reverse proxy. It
accepts only these `values` keys, and LLM keys are rejected:

| Key | Default | Meaning |
| --- | --- | --- |
| `max_body_size` | `64m` | Largest request body. |
| `proxy_timeout` / `connect_timeout` | `3600s` / `10s` | Proxy timeouts. |
| `rate_limit` | unset (unlimited) | **Total** download bandwidth, e.g. `200Mbps`. |
| `download_conn_limit` | `10` when `rate_limit` is set | Concurrent downloads across all clients. Each gets `rate_limit ÷ N`. Over the limit returns `429`. |
| `upload_conn_limit`, `upload_req_limit` (e.g. `10r/s`), `upload_req_burst` | unset | Per-client upload limits. Rejections return `503`. |
| `upload_limit_key` | `$http_x_real_ip` | What counts as one client. |
| `auth` / `auth_public_paths` | on / the download path | Bearer check against the same key file. |

How long a ConfigMap change takes to reach the pod is the kubelet's refresh
interval, not something this stack controls; only the sidecar's 2 s debounce is
fixed. Measured on a test cluster after an engine pod was replaced: openresty
reloaded about 16 s after the new pod was Ready, CART 65–80 s after. See
[rolling-updates.md](rolling-updates.md) for what that means for an update.
