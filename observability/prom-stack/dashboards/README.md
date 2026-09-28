Grafana dashboards (LLM inference observability)
---

The K8s / Node / etcd dashboards that come with kube-prometheus-stack are loaded
by the chart as ConfigMaps and are not here. What is here are the LLM inference
stack's own dashboards; every panel reads the in-cluster Prometheus
(bodylog-exporter, the engines' ServiceMonitors, DCGM, cache-sim).

> Moved here from the llm-monitor repository (`grafana/`) on 2026-09-15. This is
> the one authoritative source. llm-monitor keeps the scripts that operate on or
> check a cluster (`promq.sh`, `check_legends.py`, `check_table.py`, copying a
> dashboard, folder alignment, data checks), and those scripts read the JSON in
> this directory.

| File | What it is |
|---|---|
| `build_dash.py` | **The authoritative source.** Generates a dashboard's POST body (`{"dashboard":{...},"overwrite":true}`) on stdout; arguments pick which |
| `llm-health-dashboard.json` | snapshot of `build_dash.py health`, uid `llm-health` -- service health overview, the landing page for a cluster |
| `llm-obs-dashboard.json` | snapshot of `build_dash.py main`, uid `llm-obs-bodylog` -- LLM inference performance |
| `llm-gpu-dashboard.json` | snapshot of `build_dash.py gpu`, uid `llm-gpu` -- GPU hardware |
| `h3-dashboard.json` | snapshot of `build_dash.py h3`, uid `h3-video` -- H3 video generation, only for clusters running minimax-h3 |

Every dashboard hard-codes its datasource to uid `prometheus`
(kube-prometheus-stack's default datasource), so a cluster importing them must
have that uid.

## The two main dashboards

- **`main`** (uid `llm-obs-bodylog`) -- performance per `$service`, rate limiting
  and 429s, engine state. **For looking into one service.**
- **`health`** (uid `llm-health`) -- **health of every service at once**: one
  table, a row per service (ready / desired / actual replicas, QPS, error rate,
  TTFT p95, output tok/s), plus component health and replica-count graphs.
  **For seeing the whole cluster in one glance.**
  - **The three replica columns are not redundant.** `desired` is the workload's
    `spec.replicas` (the exporter walks ownerRefs up to the top: for LWS it takes
    the LWS itself, not the StatefulSet that a surge has inflated); `actual` is
    every endpoint in the EndpointSlice; `ready` is `conditions.ready`.
    **Degraded means `ready < desired`** -- during a rolling update `actual`
    exceeds `desired` by maxSurge, and using it as the denominator reports a
    fully-staffed service as degraded (measured on kimi, 2026-08-27: ready 2 /
    actual 3 / desired 2).
  - Where `bodylog_service_replicas_desired` is missing (bare pods, or the
    exporter lacking RBAC) the expression `or`s back to `actual`, degrading to
    the old definition rather than blanking the row.

## Where the data comes from (all of it via Prometheus)

- **bodylog exporter** (job `bodylog`): QPS, error rate, TTFT, throughput,
  per-request tok/s, replica counts, 429s, labelled with `service` (=
  ModelRoute's discovery.service, with the LWS `-leader` stripped), `route`,
  `backend`, `model`.
- **the engines** (sglang / vllm, job = their own Service name): KV,
  num_running, num_queue, cache hits. Needs a ServiceMonitor on the engine side.
- **DCGM** (job `nvidia-dcgm-exporter`): GPU temperature, memory, utilisation,
  throttling.
- **cache-sim exporter**: cache hit rate, actual against theoretical maximum
  (`cachesim_*`, with `calib` distinguishing the definition's version). These
  panels are empty on a cluster with no cache-sim.

## Changing a dashboard

Edit `build_dash.py`. **Do not edit in the Grafana UI** -- since the move to
ConfigMaps the UI cannot save anyway. To try something in the UI first, "Save
as" a copy, work on that, then make the same change in `build_dash.py` and
delete the copy.

```bash
cd observability/prom-stack
# 1. edit dashboards/build_dash.py
make dashboards-gen     # 2. regenerate the JSON (= python3 ./dashboards/build_dash.py, all four by default)
# 3. check it (optional; the tools live in llm-monitor's grafana/, see below)
# 4. commit build_dash.py and the JSON together, and merge to master
make dashboards-diff    # 5. on each cluster's jump host: which CMs would change
make dashboards         #    apply -- live in about 5 seconds
```

`build_dash.py`:

- `python3 build_dash.py` -- generate all four JSON files next to the script;
- `python3 build_dash.py health gpu` -- only the ones named (`main`, `health`,
  `gpu`, `h3`; an unknown name is an error);
- `python3 build_dash.py --stdout main` -- print the Grafana API POST body
  (`{"dashboard":…,"overwrite":true}`) and write no file, for a cluster still
  importing through the API rather than through ConfigMaps.

Before changing anything, pull the live dashboard once and compare it with the
script's output, to be sure nobody edited it in the UI. If someone did, fold
that into the script first.

The checking tools are in llm-monitor's `grafana/`: verify a new or changed
panel's PromQL with `promq.sh`, then after regenerating the snapshots run
`check_legends.py` (point `DASH_DIR` at this directory), and for a table panel
`check_table.py <this directory>/<dashboard>.json <panel keyword>`.

## Deploying to a cluster (ConfigMaps)

`kustomization.yaml` turns each JSON into a ConfigMap
(`monitoring/grafana-dashboard-*`, labelled `grafana_dashboard: "1"`).
kube-prometheus-stack's grafana sidecar watches that label, writes the JSON into
`/tmp/dashboards`, and Grafana's file provisioner loads it -- the same path the
29 dashboards shipped with the chart take, so **no admin password and no calls
to the Grafana API**.

```bash
cd observability/prom-stack
make dashboards-diff   # what would change
make dashboards-dry    # server-side dry run
make dashboards        # kubectl apply --server-side -k ./dashboards/
```

Behaviour, measured 2026-09-15:

- **A ConfigMap change is live in about 5 seconds** -- the sidecar watches, so
  there is no waiting for the provisioner's 30-second scan.
- **The UI cannot save.** The provider sets `allowUiUpdates: false`, and saving
  reports `Cannot save provisioned dashboard`. Change `build_dash.py`,
  regenerate, `make dashboards`. In the UI you can only "Save as" a copy to
  experiment on.
- **A ConfigMap takes over an existing API-imported dashboard of the same uid**
  in about 6 seconds -- no conflict, no duplicate, the uid and its links
  unchanged. So there is nothing to delete before switching over from the old
  API import.
- **Deleting the ConfigMap deletes the dashboard** (the provider sets
  `disableDeletion: false`), including one that had been imported through the
  API. Do not delete these ConfigMaps by hand.
- Use server-side apply: a client-side apply stores the whole ConfigMap again in
  the `last-applied-configuration` annotation, and annotations are capped at
  256KiB in total.
- The dashboards sit at the root (the provider's `folder: ''`, matching
  production), so they need no folder annotation.

Also:

- To make `llm-health` the landing page: `PATCH /api/org/preferences
  {"homeDashboardUID":"llm-health"}`. That is not in a ConfigMap.
- Moving the chart's own dashboards into a `system` folder needs the new API
  (`/apis/dashboard.grafana.app/v1/.../dashboards/<uid>`, changing only
  `metadata.annotations["grafana.app/folder"]`); the old API answers `Cannot
  save provisioned dashboard` for a provisioned dashboard. After a
  kube-prometheus-stack upgrade, any dashboard whose content changed returns to
  the root.
- `h3-dashboard.json` only has data on a cluster running minimax-h3; elsewhere
  that dashboard is empty.

## The `service` label has two spellings (read before editing a panel)

| Source | what `service` holds | example |
|---|---|---|
| bodylog exporter / openresty | `<namespace>/<name>` | `kimi/kimi-k25` |
| engines, sglang / vllm (ServiceMonitor) | the k8s **Service name**, with `namespace` as its own label | `kimi-k25-leader` |
| DCGM | **no** service at all -- only `Hostname` plus `exported_namespace` / `exported_pod` | — |

`$service` follows the bodylog spelling, so engine and GPU panels have to
normalise before they filter. Three helpers in the script do that:

- **`eng(sel)`** -- normalise an engine metric: `label_replace` strips
  `-leader`, `label_join` builds `<ns>/<name>`.
- **`flt(expr)`** -- `and on(service) (count by(service)(bodylog_service_replicas{$service,...}))`.
  This filters by `$service` **and drops Service names that no longer exist**:
  historical series that do not normalise onto a live service (say
  `kimi-sglang-sglang-svc`) disappear on their own.
- **`gpu(agg, metric)`** -- returns two targets and lets **`$gpu_scope`** select
  one (`and on() (vector($gpu_scope) == N)`: when it does not match, the right
  side is an empty vector and the whole target vanishes). **It must be `== N`,
  never `== bool N`** -- with `bool` there is always one series, and `and` only
  tests existence, not value, so the switch would stop working.
  - `$gpu_scope=0`, **by service** (the default): DCGM's `exported_namespace` /
    `exported_pod` are renamed to `namespace` / `pod`, `on(namespace,pod)
    group_left(service)` joins `POD2SVC` for the service, and `flt()` filters.
    **Only the cards the selected service occupies are shown.**
  - `$gpu_scope=1`, **whole cluster**: no join and no filter, `by(Hostname)`
    yields every GPU host, idle and non-inference cards included.
  - `POD2SVC` is a **union of two halves**, without which an LWS worker's cards
    cannot be attributed to a service (only the leader is scraped by the
    ServiceMonitor):
    - ① **leader / single pod** -- straight from the engine metrics;
    - ② **LWS worker** -- a worker's **owning StatefulSet is named exactly like
      the leader's pod** (`kimi-k25-0-1` --owner--> StatefulSet `kimi-k25-0` ==
      the leader pod), so `kube_pod_owner{owner_kind="StatefulSet"}` bridges
      back to ① for the service.
    - ⚠️ While a leader is down or Terminating the bridge breaks, and that
      replica's worker cards disappear for a while. The leader has no metrics
      either at that point, so this is expected.
    - ⚠️ Depends on kube-state-metrics' `kube_pod_owner`. This cluster **does
      not export `kube_pod_labels`** (KSM's label allowlist does not include
      them), which is why this goes through owners rather than LWS labels.

The `$service` dropdown is populated from `bodylog_service_replicas` (live
service discovery) rather than `bodylog_requests_total` (a cumulative counter),
so a deleted service leaves the dropdown once it is out of the time window.

## TTFT: non-streaming requests are subtracted in Grafana for now

The exporter filters TTFT with `if d.Frt > 0`, and its comment assumes a
non-streaming request has `frt=0`. **In reality a non-streaming request's
`first_chunk_t ≈ rt`** -- there is one body chunk, and the response ends when it
arrives -- so `frt` is always > 0 and nothing is filtered out. The TTFT
histogram therefore fills with samples where frt ≈ rt, and the measured **p99
(82.17s) came out above RT p99 (77.36s)**, which is physically impossible.

The way around it, without touching the exporter: bodylog's details jsonl
**writes the `stream` field only for a streaming request** -- for a
non-streaming one the key is absent -- so the exporter's `stream="unknown"` is
exactly the non-streaming set, and **the rt metric carries the `stream` label**.
`ttft(all) - rt(stream="unknown")` thus subtracts the non-streaming part (native
histograms subtract directly). Measured: the difference has 1.6481/s samples
against 1.7000/s actual streaming requests, and p90 drops from 31.98s to 0.34s.

**The subtraction is automatic; there is no switch in the top bar.** Each
service is classified **by nearest anchor**, with no magic threshold: the TTFT
observation count can only sit near one of two anchors -- while the exporter is
broken it equals the total request count, and once fixed it equals the streaming
request count -- so comparing `|ttft-all|` with `|ttft-streaming|` is enough.
(An earlier version used a `ttft > 1.5 x streaming` threshold, which amounts to
requiring non-streaming traffic to exceed 33% before it can tell, and would miss
a service at 20%.) **Once the exporter is fixed, ttft holds only streaming
requests, the test flips on its own and the subtraction stops** -- it cannot
subtract twice. Measured on modelforge: ttft 3.1296 / all 3.1333 / streaming
0.5741 -- nearest "all", so subtract. On kimi all three are 0.0889 (it was
always streaming), so no subtraction, and there the subtraction would be a
no-op anyway.

How exact the subtraction is, measured: `histogram_count(ttft - rt_nonstreaming)`
equals the streaming request count **per service exactly** (deviation
0.0000/s), and the ttft and rt observation populations agree exactly as well
(0.0000/s apart), so there is no "rt has it, ttft does not" over-subtraction.
Over 426 sampled non-streaming records, **83.1% have frt exactly equal to rt**,
and the rest differ by a median of 0.003% relative -- far below the 10% bucket
width of a native histogram, so they cancel within a bucket. Only **0.5% (2 of
426) have frt=0**, which the exporter skips while rt still counts it: the one
source of over-subtraction. The real fix remains to filter by stream in the
exporter, or to add a stream label to the ttft metric.

## Notes

- **A state-timeline panel must set `options.tooltip` explicitly** -- without it
  Grafana 13 shows no tooltip on hover -- and **`mergeValues` must be `False`**:
  with adjacent equal values merged, the tooltip reports **the start of the
  whole run** rather than the time under the cursor (measured: a tooltip saying
  15:24 while the axis started at 15:40).
- **Do not write `$var` in a panel's description or title.** Grafana
  **interpolates** it (`$gpu_scope` renders as `0`, `$service` as an actual
  service name) and the sentence is ruined. Refer to a dropdown by its display
  name instead. Descriptions also render as **markdown**, so **do not start one
  with `>`** -- it becomes a block quote and the `>` of a `>0` disappears.
- The environment-specific constants -- engine job names (`kimi-k25`,
  `fallback-modelforge-01`), the Prometheus datasource uid `prometheus` -- are at
  the top of `build_dash.py` and in individual panel expressions, and have to be
  changed for another environment.
- **The health table's error rate counts 5xx only**, that being server-side
  failure. 4xx is excluded: it mixes 400 (the client sent something bad), 499
  (the client hung up) and 429 (rate limiting), none of which say anything about
  service health. ⚠️ **The exporter exposes only `status_class`, not exact
  codes, so 499 and 429 cannot be excluded individually in PromQL** -- doing
  that needs a change to `statusClass()` in llm-openresty's
  `bodylog-exporter-go/metrics.go`.
- Counting only 5xx, the numerator can be an empty vector (a service with no
  5xx at all), so it needs an `or (0 * <the total>)` fallback; otherwise that
  table cell is blank instead of 0%.
- The `service` variable's regex `/(.*?)(?:-leader)?$/` folds the LWS `-leader`
  away. `unknown` is a request the exporter could not attribute to a ModelRoute
  (a 4xx with no backend, a non-ModelRoute backend, or the timing window before
  a pod is indexed).
- Layout relies on `_y[0] += 8` for a manual line break. Forget one and panels
  overlap at the same y; Grafana pushes them apart when saving, and the snapshot
  then disagrees with the live gridPos (fixed once, 2026-09-14).
