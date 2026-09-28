# CART: the cache-aware router

CART sits in front of the replicas of **one** model. It sends each request to
the replica that already holds the longest matching prompt prefix, so that
replica's KV cache is reused. When that replica is too busy, the least-loaded
replica gets the request instead.

This page describes every setting CART reads, how the chart and autoconfig
build its config file, and which settings can change without a restart. It is
part of the [configuration reference](configuration.md). Related pages:

- [routing-and-rate-limiting.md](routing-and-rate-limiting.md): how openresty
  sends traffic to CART, and what happens behind it.
- [deploy-a-model.md](deploy-a-model.md): the model values file that turns CART
  on.
- [autoscaling.md](autoscaling.md) and [rolling-updates.md](rolling-updates.md):
  what happens to CART when the set of engine pods changes.

> ⚠️ **Only `workers` can be reloaded.** On `SIGHUP` (which the reload sidecar
> sends whenever the ConfigMap changes), CART can change its worker list and
> nothing else. If any other key in the files on disk differs from the running
> config, CART rejects the **whole** reload and keeps its old config. It also
> rejects every later worker update, because the file still differs from what
> is running. The worker list stays frozen until the pod restarts. After you
> change anything other than workers, run `kubectl rollout restart`.

## Where the config comes from

In a model release, you do not write CART's config file yourself. It is built
from two keys in one ConfigMap:

```
cart.baseConfig          ──► ConfigMap <release>-cart-config, key config.yaml    (Helm renders it)
autoconfig (ModelRoute)  ──► same ConfigMap, key workers.yaml                   (autoconfig writes it)
```

The ConfigMap is mounted at `/workspace/configs`, and CART starts with
`-c config.yaml -c workers.yaml`. Files are applied in order and later files
win:

- **mappings** are merged key by key, so an overlay only needs the keys it
  changes;
- **lists and scalars** are replaced whole, so the worker list in
  `workers.yaml` replaces any `workers` in the base;
- **an empty or comment-only file** changes nothing.

The `sglang` and `vllm` charts include CART as a subchart under the `cart:`
key, and they already set up the overlay:

```yaml
cart:
  enabled: true
  configOverlays:
    - key: workers.yaml
      autoconfig: true      # Helm never renders this key; autoconfig owns it
```

On a test install, the rendered files looked like this:

```yaml
# config.yaml (chart default baseConfig)
server:
  host: "0.0.0.0"
  port: 8071
cache:
  threshold: 0.1
  balance_abs_threshold: 10
  max_tree_size: 5000000
  daily_cleanup_hour_utc: 21
proxy:
  add_routed_peer_header: true
  remote_media_url_policy: 400
health:
  endpoint: "/health"
  interval_secs: 10
```

```yaml
# workers.yaml (written by autoconfig)
workers:
- max_load: 20
  url: http://<podIP>:30000
```

### What autoconfig writes

autoconfig reconciles on events, and at least every 10 s. On each pass it:

1. finds the model's **ready** endpoints;
2. reads the current contents of `workers.yaml`;
3. replaces the `workers` key with one
   `{url: http://<podIP>:<port>, max_load: <modelRoute.cart.maxLoad>}` entry per
   endpoint;
4. writes the ConfigMap back, but only if something changed.

It never sets `load_penalty`. It leaves the other keys in that file alone, and
it never creates the ConfigMap.

It skips the write in these cases:

- **no backend is ready.** CART would reject an empty list.
- **the ConfigMap can't be read.**
- **the base is empty,** when workers share a key with it.

In each case it keeps the last config instead of wiping it.

### From a pod change to CART

Here is the sequence when an engine pod is replaced:

1. **The old pod fails its health checks.** CART stops sending to it after
   `failure_threshold` failed checks (`Worker … marked unhealthy after 3
   consecutive failures`).
2. **autoconfig writes the new pod IP** into `workers.yaml`.
3. **The kubelet updates the mounted volume.** On the test install, the reload
   sidecar logged `config changed -> SIGHUP` **65–80 s after the new pod became
   Ready**. Most of that delay is the ConfigMap volume update; the sidecar
   itself only waits 2 s for the changes to settle.
4. **CART reloads.** It rebuilds its workers and **throws away the radix tree**
   (`Eviction task shutting down, clearing the tree (reload)`).

So after every rollout, scale event or engine restart, the prefix cache starts
cold, and the new pod gets no traffic from CART until step 3 finishes.
[rolling-updates.md](rolling-updates.md) covers what this means for engine
rollouts.

## The router pod

A healthy router pod shows `3/3`, and it also has an init container:

| Container | Role |
| --- | --- |
| `wait-workers` (init) | Waits until some config file contains a worker URL. Checks every 2 s for up to ~10 min, then starts CART anyway. If CART starts with no workers it exits, and the pod stays in `Init` instead of crash-looping. |
| `cart` | The router. Runs `ulimit -n <ulimitNofile>`, then `launch_service -c … -c …`. |
| `reload` | Watches `/workspace/configs`. When something changes, it waits 2 s and sends `SIGHUP` to `cache-aware-router`. |
| `hagate` | Holds the Lease that picks a leader. Only the leader gets the label that the Service selects on. |

### Leader and standby

`replicas: 2`, but only one replica takes traffic. CART's radix tree lives in
process memory, so two active replicas would each hold half of the cache.

- **Label.** The Service selects on `cart-active: "true"` (the label key is
  `<chart name>-active`). hagate sets the label on the leader and removes it
  from everyone else.
- **Readiness does not decide traffic.** Readiness is a plain TCP check, and
  both replicas are Ready.
- **Lease.** The Lease is `<fullname>-ha`, with duration 8 s, renew deadline
  5 s and retry 1 s.
- **Health condition.** The leader keeps the label only while it can open a TCP
  connection to `ha.appTcp`, which defaults to `127.0.0.1:8071`. hagate checks
  this every 2 s.
- **Planned change** (rollout, eviction, `kubectl delete`): the leader gives up
  the Lease right away, and the standby takes new traffic within 1–2 s. The old
  pod keeps its label while it terminates, so its open streams can finish. On
  the test install, a `rollout restart` of CART under load dropped **0**
  requests.
- **Hard loss** (node down, force delete): the standby takes over when the
  Lease expires, about 8 s later. New requests went through normally on the
  test install. **Requests that were in flight through the lost pod are lost.**
  On the test install they hung for about 300 s, until an upstream timeout
  gave up on them.
- **Cold cache after takeover.** The standby's tree is empty when it takes
  over.

A preferred anti-affinity rule keeps the two replicas on different nodes. Any
`affinity` you set is added to it. To replace it, set your own
`podAntiAffinity`.

## Which values to set

In a model values file, CART settings go under `cart:`. The exception is the
per-worker limit, which goes under `modelRoute.cart`.

| Value | Set it? | Notes |
| --- | --- | --- |
| `cart.enabled` | yes | The only switch. With `modelRoute.enabled`, it also sends the route through CART. |
| `modelRoute.cart.maxLoad` | per model | Becomes every worker's `max_load` (default 20). Setting `max_load` in `baseConfig` has no effect, because `workers.yaml` replaces the whole list. |
| `cart.baseConfig` | when tuning | **Replaces the whole base document.** Copy the default above, then edit it. Leave `workers` out. Changes need a restart (see [Upgrades and hand edits](#upgrades-and-hand-edits)). |
| `cart.resources`, `nodeSelector`, `tolerations`, `affinity` | as needed | CART needs CPU only; the default limit is 4 CPU / 16 Gi. Tree memory grows with `max_tree_size` × the number of workers. |
| `cart.terminationGracePeriodSeconds` | keep it ≥ your longest response | The default is 3600. The Kubernetes default of 30 s cuts long streams. |
| `cart.service.port` | rarely | If you change it, change three values together: `service.port`, `server.port` in `baseConfig`, and `ha.appTcp`. If `ha.appTcp` still points at the old port, no pod gets the label and the Service has **no endpoints**. |
| `cart.image.repository`, `cart.ha.image`, `cart.reload.image` | not per model | `models/images.yaml.gotmpl` sets all three from `registry`, so they can't be overridden per model. `ha.image` and `reload.image` are `repository:tag` strings. |
| `cart.configOverlays` | **no** | The `workers.yaml` + `autoconfig: true` entry is what stops `helm upgrade` from overwriting the workers. At most one entry may set `autoconfig: true`, and that entry must not have `content`. |
| `cart.waitForWorkers`, `cart.reload.enabled`, `cart.ha.enabled` | no | Leave them `true`. Turn all three off only for a standalone CART (see [Standalone](#standalone)). |
| `cart.reload.process`, `cart.configMapName`, `cart.ulimitNofile` | no | `launch_service` refuses to start if `ulimit -n` is below 65535. |

Example of per-model tuning:

```yaml
cart:
  enabled: true
  baseConfig: |
    server:
      host: "0.0.0.0"
      port: 8071
    cache:
      threshold: 0.1
      balance_abs_threshold: 10
      max_tree_size: 5000000
      daily_cleanup_hour_utc: 21
    proxy:
      add_routed_peer_header: true
      remote_media_url_policy: 400
      max_body_size: 33554432      # 32 MiB, e.g. for inline base64 images
    health:
      endpoint: "/health"
      interval_secs: 10
modelRoute:
  cart:
    maxLoad: 32
```

### Upgrades and hand edits

- **A config change does not restart CART.** The Deployment has no
  config-checksum annotation, so a `helm upgrade` that changes `baseConfig`
  only updates the ConfigMap. The sidecar then sends `SIGHUP`, CART rejects the
  reload, and worker updates stay frozen from then on. Follow every
  `baseConfig` change with:

  ```bash
  kubectl -n <ns> rollout restart deploy/<release>-cart
  ```

  A restart of CART under load dropped no requests on the test install (see
  [Leader and standby](#leader-and-standby)). The tree starts cold afterwards.
- **`helm upgrade` overwrites `config.yaml` from values.** A `kubectl edit` on
  that key is lost at the next upgrade. Make the change in values instead.
- **`workers.yaml` belongs to autoconfig.** autoconfig sets `workers` again on
  its next pass, and any other key you add there counts as a non-worker change,
  which blocks reloads.
- **Standalone chart defaults.** The standalone `cart` chart defaults to
  `configOverlays: []`, so autoconfig writes workers into `config.yaml` itself.
  Every `helm upgrade` then resets that key to a base with no workers until
  autoconfig writes them back. Whenever a controller manages the workers, give
  it an `autoconfig: true` overlay.

### Standalone

To run the `cart` chart on its own, with a worker list you write by hand:

```yaml
waitForWorkers: false
reload:
  enabled: false
ha:
  enabled: false
replicas: 1
baseConfig: |
  server:
    host: "0.0.0.0"
    port: 8071
  workers:
    - url: "http://my-engine-0.my-engine.my-ns.svc:8000"
      max_load: 20
    - url: "http://my-engine-1.my-engine.my-ns.svc:8000"
      max_load: 20
  health:
    endpoint: "/health"
```

## Config file reference

Unknown keys are rejected at every level, so a typo stops CART at startup
instead of being silently ignored. Only `workers` is required.

The **Chart** column shows the chart's default `baseConfig` where it differs
from the code default. The **Reload** column shows what `SIGHUP` does with a
changed value:

- **yes**: the new value is applied.
- **no**: CART rejects the whole reload, and the value takes effect only after
  a restart.

### `server`

| Key | Type | Default | Chart | Meaning | Reload |
| --- | --- | --- | --- | --- | --- |
| `server.host` | string | `0.0.0.0` | | Address to bind. | no |
| `server.port` | u16 | `6700` | `8071` | Listen port. Must be > 0. | no |

### `workers`

This key is required and must not be empty. An empty list stops CART from
starting, and a reload that would empty the list is rejected.

| Key | Type | Default | Meaning | Reload |
| --- | --- | --- | --- | --- |
| `workers[].url` | string | none (required) | Backend base URL, which must start with `http://` or `https://`. CART appends the request path to it. | yes |
| `workers[].max_load` | integer | `20` | **Hard cap** on requests in flight to this replica. A replica at its cap is skipped. When every replica is at its cap, CART returns `503 No available workers`; it doesn't queue. Must be > 0. | yes |
| `workers[].load_penalty` | integer | `0` | Added to this replica's load when loads are compared (to pick the least-loaded replica and to check for overload), but not when checking `max_load`. Use it to send less traffic to a weaker node while keeping it in the pool. | yes |

A reload rebuilds every worker. That resets the in-flight counters, circuit
breakers and health state (all workers start healthy), and it **clears the
radix tree**.

### `cache`

These settings control prefix matching, balancing and the radix tree. Lengths
are **characters of the matched text** (see [What is matched](#what-is-matched)).
CART has no tokenizer.

| Key | Type | Default | Chart | Meaning | Reload |
| --- | --- | --- | --- | --- | --- |
| `cache.threshold` | float 0–1 | `0.3` | `0.1` | A request follows its cached replica when `matched / total` characters is at least this. | no |
| `cache.match_abs_threshold` | integer (chars) | `8192` | | A request also follows its cached replica when at least this many characters match, whatever the ratio. This catches a long shared system prompt inside a longer request. `0` turns it off. | no |
| `cache.balance_abs_threshold` | integer (requests) | `5` | `10` | Overload test, absolute part: `matched_load − min_load ≥ this`. | no |
| `cache.balance_rel_threshold` | float | `1.25` | | Overload test, relative part: `matched_load / min_load ≥ this`. The ratio is infinite when `min_load` is 0. | no |
| `cache.eviction_interval_secs` | integer (s) | `60` | | How often the eviction pass runs. `0` turns off eviction and the daily cleanup, and the tree then grows without bound. | no |
| `cache.max_tree_size` | integer (chars **per worker**) | `1048576` | `5000000` | Each eviction pass removes the least-recently-used leaves of a worker until the characters stored for it are at or below this value. | no |
| `cache.daily_cleanup_hour_utc` | `-1` or 0–23 | `-1` | `21` | The first eviction pass at or after `HH:08` UTC empties the whole tree. `-1` turns it off. | no |

A request is overloaded only when **both** balance tests hold. When it is,
CART ignores the cache match and sends the request to the least-loaded replica.

### `health`

| Key | Type | Default | Chart | Meaning | Reload |
| --- | --- | --- | --- | --- | --- |
| `health.endpoint` | string | `/v1/models` | `/health` | CART sends `GET <url><endpoint>` to each worker. Any 2xx response counts as healthy. | no |
| `health.interval_secs` | integer (s) | `10` | `10` | All workers are probed together, once per interval. | no |
| `health.failure_threshold` | integer | `3` | | Consecutive failed checks before a worker is marked unhealthy. | no |
| `health.success_threshold` | integer | `1` | | Consecutive successful checks before an unhealthy worker is marked healthy again. | no |

The probe uses a fixed 10 s timeout, with 2 s allowed for connecting. A dead
worker is taken out after about `failure_threshold × interval_secs`, which is
30 s with the defaults.

Note that the code default endpoint (`/v1/models`) differs from the chart's
`/health`, so a hand-written file without a `health` section probes
`/v1/models`. The SGLang chart makes `/health` a cheap status check
(`healthEndpointGeneration: false`).

### `proxy`

| Key | Type | Default | Chart | Meaning | Reload |
| --- | --- | --- | --- | --- | --- |
| `proxy.max_retries` | integer | `1` | | Retries after the first attempt. CART retries on connection errors, timeouts and HTTP `408`, `429`, `500`, `502`, `503`, `504`. Each retry avoids the replica that failed **on the previous attempt**. CART only retries before response headers arrive, so a stream that breaks partway is not retried. | no |
| `proxy.initial_backoff_ms` | integer (ms) | `100` | | Base delay before a retry. | no |
| `proxy.max_backoff_ms` | integer (ms) | `5000` | | Upper limit on the delay, before jitter is applied. | no |
| `proxy.backoff_multiplier` | float | `2.0` | | Delay = `min(initial × multiplier^attempt, max)`. | no |
| `proxy.jitter_factor` | float 0–1 | `0.25` | | Multiplies the delay by a random factor between `1 − j` and `1 + j`. | no |
| `proxy.request_timeout_secs` | integer (s) | `10000` | | Total time allowed for one attempt, including reading the response body. When it runs out, CART returns `504`. Keep it longer than your longest generation. | no |
| `proxy.connect_timeout_secs` | integer (s) | `2` | | Covers only opening the TCP/TLS connection. A dead pod IP fails in about 2 s instead of about 30 s, and long streams are not affected. A failed connect returns `502` and is retried. | no |
| `proxy.add_routed_peer_header` | bool | `false` | `true` | Adds `x-routed-peer: <worker url>` to responses. This exposes backend pod addresses to whoever receives the response. | no |
| `proxy.max_body_size` | integer (bytes) | `10485760` | | Maximum request body for `/v1/chat/completions`, `/v1/completions` and `/v1/messages`. Raise it for large inline images. | no |
| `proxy.remote_media_url_policy` | `200` or 400–599 | `200` | `400` | Stops the engine from fetching URLs on behalf of clients. With `200`, remote media is allowed. With a 4xx/5xx code, any chat or `/v1/messages` request whose `image_url` / `video_url` is not a `data:` URI is refused with that status and `code: remote_media_url_disallowed`. | no |

CART keeps up to 32 idle connections per backend, closing them after 90 s idle.
Neither setting can be changed.

### `circuit_breaker`

| Key | Type | Default | Meaning | Reload |
| --- | --- | --- | --- | --- |
| `circuit_breaker.failure_threshold` | integer | `5` | Consecutive failed requests before the breaker opens. An open breaker takes the worker out of rotation. | no |
| `circuit_breaker.success_threshold` | integer | `2` | Consecutive successes in half-open state before the breaker closes. | no |
| `circuit_breaker.timeout_secs` | integer (s) | `30` | Time the breaker stays open before it moves to half-open. | no |

Connection errors, timeouts and any 5xx response count as failures. Any 2xx or
4xx response, **including 429**, counts as a success. In half-open state the
worker gets normal traffic, and a single failure opens the breaker again.

### `logging`

| Key | Type | Default | Meaning | Reload |
| --- | --- | --- | --- | --- |
| `logging.level` | string | `info` | A filter such as `info`, `debug` or `cache_aware_router=debug`. The `RUST_LOG` environment variable overrides it. | no |

At `info`, CART logs one line per request: `Route: <reason> → <worker>
load=<n> | matched=<m>/<total> <ratio> <ms>`. The reason is `cache_hit`,
`cache_miss`, `hit_overloaded` or `empty_text`.

### Validation

CART rejects a config for any of the following. At startup it exits with
`Configuration error: …`; on a reload it logs a warning and keeps the old
config.

- `workers` is missing or empty;
- a worker URL doesn't start with `http://` or `https://`;
- a `max_load` is `0`;
- `cache.threshold` or `proxy.jitter_factor` is outside 0–1;
- `server.port` is `0`;
- `remote_media_url_policy` is neither `200` nor between 400 and 599;
- `daily_cleanup_hour_utc` is above 23;
- the file has an unknown key, or its top level is not a mapping.

On reload, CART also rejects the config when any section other than `workers`
differs from the running config. It logs `Config reload rejected: only worker
list changes are supported`, followed by the list of sections that changed.

## Command line

| Flag | Meaning |
| --- | --- |
| `-c, --config <path>` | Config file. Can be repeated; files are applied in order and later ones win. Defaults to `config.yaml`. |
| `--config-check` | Validates the merged config, prints `Configuration is valid.` and exits 0. |
| `-V, --version`, `-h, --help` | Show the version or help. |

| Signal | Effect |
| --- | --- |
| `SIGHUP` | Reads the config files again and applies a change to the worker list. |
| `SIGTERM`, `SIGINT` | Stops accepting new connections and waits for in-flight requests, including streams, to finish. |

The container entrypoint, `launch_service`, does the following:

- refuses to start below `ulimit -n` 65535;
- prints `/proc/cpuinfo` and **every environment variable** to the log, so
  keep secrets out of CART's environment;
- passes its arguments to the binary, or runs with `-c configs/config.yaml`
  when there are none.

To check a file before deploying it:

```bash
cache-aware-router -c config.yaml -c overlay.yaml --config-check
```

## How a request is routed

1. **Usable workers.** Keep the workers that are healthy, have a circuit
   breaker that isn't open, and are below `max_load`. If none are left, return
   `503`.
2. **Least-loaded worker.** Find the lowest `load + load_penalty`. Ties are
   broken at random.
3. **Empty text.** If there is no text to match (a path CART doesn't match on,
   or a body that isn't JSON), send the request to the least-loaded worker
   (`empty_text`).
4. **Prefix match.** Look up the text in the radix tree to get the matched
   character count and the worker that owns the match.
5. **Cache hit.** If `ratio ≥ threshold` or `matched ≥ match_abs_threshold`,
   and that worker is usable, send the request to it (`cache_hit`). If it is
   overloaded, send the request to the least-loaded worker instead
   (`hit_overloaded`).
6. **Cache miss.** Otherwise, send the request to the least-loaded worker
   (`cache_miss`).
7. **Record the route.** Insert the text into the tree under the chosen
   worker. If an eviction pass holds the lock for more than 1 s, the insert is
   skipped and logged.

Keep `cache.threshold` above `0`. With `0`, a request that matches nothing
still counts as a "hit" and goes to whichever worker the tree's root happens
to point at.

### What is matched

| Endpoint | Text |
| --- | --- |
| `POST /v1/chat/completions` | `tools` as JSON, followed by `messages` as JSON |
| `POST /v1/completions` | `prompt`, but only when it is a string. Token IDs and prompt lists give `empty_text`. |
| `POST /v1/messages` | `tools` followed by `messages`. The top-level `system` field is not included. |
| anything else | nothing, so the request goes to the least-loaded worker |

The match is measured in characters, not tokens. Some engines cache in large
blocks, for example with a large page size or decode-context parallelism,
where the smallest cacheable unit is `page_size × dcp_size`. With those
engines, a short shared prefix can show no cache hit even though CART routed
it correctly.

## Endpoints

| Method | Path | Behaviour |
| --- | --- | --- |
| POST | `/v1/chat/completions`, `/v1/completions`, `/v1/messages` | Cache-aware routing, retries and the body-size limit. SSE streams are passed through without buffering. |
| GET | `/health` | `200 {"status":"healthy","healthy_workers":N,"total_workers":M}` while N > 0, otherwise `503`. Counts health checks only. |
| GET | `/workers` | For each worker: `url`, `healthy`, `available`, `load`, `effective_load`, `load_penalty`, `max_load`, `circuit_breaker_state`. |
| GET | `/v1/models` | Fetched from one worker and then **cached for 10 minutes**. |
| any | anything else | Passed unchanged to the least-loaded worker. |

⚠️ **Don't use `/v1/models` as a health check.** It keeps answering `200` for
up to 10 minutes after every backend is gone. autoconfig probes CART's tier in
openresty on `/health` for this reason.

⚠️ **CART has no metrics endpoint.** A `GET /metrics` sent to CART is passed
through to a backend, and you get **one engine's** metrics. Scrape the engines
directly. What CART itself exposes is its per-request log lines and
`/workers`.

## Checking that it routes

```bash
NS=<model namespace>; REL=<release>

# 3/3, and exactly one pod has cart-active=true
kubectl -n $NS get pods -l app.kubernetes.io/name=cart -L cart-active

# the worker list autoconfig wrote
kubectl -n $NS get cm $REL-cart-config -o jsonpath='{.data.workers\.yaml}'

# live worker state, through the Service (the leader)
kubectl -n $NS port-forward svc/$REL-cart 8071:8071 &
curl -s localhost:8071/health
curl -s localhost:8071/workers

# send the same long prompt twice: cache_miss first, then cache_hit on the same worker
kubectl -n $NS logs deploy/$REL-cart -c cart --tail=20 | grep 'Route:'

# after an engine pod changes: did the reload arrive, and was it accepted?
kubectl -n $NS logs deploy/$REL-cart -c reload --tail=5
kubectl -n $NS logs deploy/$REL-cart -c cart | grep -E 'Config reload|reload rejected|clearing the tree'
```

If the log shows `Config reload rejected`, compare the sections it lists with
`Current config:` (printed at startup), fix the values, and restart the
Deployment.

## Tuning

- **`threshold` vs `match_abs_threshold`.** The ratio test helps short
  requests. The absolute test catches long requests that share a long system
  prompt or tool list. `tools` comes first in the matched text, so a long tool
  list counts toward the match.
- **Balance tests are ANDed.** A lower `balance_abs_threshold` gives up cache
  affinity sooner. When any usable worker is idle, the ratio is infinite, so
  only the absolute test decides. The chart's value of `10` keeps affinity
  longer in a lightly loaded pool.
- **`max_load` is a cliff, not a weight.** A worker at its cap is skipped, and
  when every worker is at its cap CART returns `503` right away. Set it to the
  engine's real concurrency. Use `load_penalty` for a soft preference.
- **Tree memory.** `max_tree_size` is counted per worker, so memory grows with
  the number of workers. An eviction pass holds an exclusive lock, and inserts
  that wait more than 1 s are dropped. `daily_cleanup_hour_utc` clears the
  whole tree at a quiet hour.
- **Timeouts.** Keep `connect_timeout_secs` small, because it only decides how
  fast a dead pod IP fails. Keep `request_timeout_secs` above your longest
  generation. Whether that timeout cuts a stream that has already started has
  not been verified.
- **Retries.** Each retry waits `100 ms × 2ⁿ ± 25%`. With more than two
  workers, a retry can land on a replica that failed two attempts earlier.
- **Reloads cost cache warmth.** Every change to the engine pool clears the
  tree, and CART picks up the change about a minute after the pod is Ready.
  Frequent scaling (see [autoscaling.md](autoscaling.md)) keeps the cache
  cold.
