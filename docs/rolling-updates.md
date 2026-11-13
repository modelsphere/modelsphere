# Rolling updates

How to upgrade or reconfigure one component of a running stack without
dropping requests. Every component except the model engine rolls cleanly with
its chart defaults. The engine needs two extra values, set once per model.

## Summary

| Component | How to update | Drops requests? | What to do |
| --- | --- | --- | --- |
| Engine (SGLang / vLLM) | `helm upgrade <model> modelsphere/<engine> -n <ns> -f values.yaml` | No | Nothing, with the chart defaults (sglang ≥ 0.8.2, vllm ≥ 0.6.2) |
| CART | Same command as the engine (it is part of the model release) | No | `rollout restart` after changing CART settings |
| openresty | `make helm-apply SELECTOR=name=openresty` | No | Bump tags in `llmgateway/openresty.yaml.gotmpl` |
| autoconfig | `make helm-apply SELECTOR=name=autoconfig` | No | Apply CRDs first; don't roll it together with a model |
| bodylog, bodylog-exporter | `make helm-apply SELECTOR=name=bodylog` (or `bodylog-exporter`) | No (records can be lost, not requests) | Nothing |
| llmscaleoperator, llm-slo | `make helm-apply SELECTOR=name=<release>` | Not on the request path | Apply llm-slo CRDs first; avoid traffic peaks |

Models are updated with `helm upgrade`; the other components with
`make helm-apply`. Always pass the model's whole values file with `-f`, not
`--reuse-values`: that replays only last time's values and leaves out keys a
newer chart added.

## Before you roll

1. **Diff.** For a model, `helm diff upgrade <model> modelsphere/<engine> -n <ns>
   -f values.yaml`; for the other components, `make helm-diff
   SELECTOR=name=<release>`. A pod-template change means a rollout.
2. **Check the release.** `helm status <release> -n <ns>` should say
   `deployed`, not `failed` or `pending-upgrade`.
3. **Check GPUs for the surge**: one replica's worth of `model.gpus` free.
4. **Check the routers.** autoconfig is Running, `kubectl get mr -A` shows the
   ModelRoute Ready, and exactly one pod carries `openresty-active=true` and one
   `cart-active=true`.
5. **Apply CRDs** if the autoconfig or llm-slo chart version changed (see
   [CRDs](#crds)).
6. **Roll one component at a time.**

## Engine

```bash
helm diff upgrade <model> modelsphere/<engine> -n <ns> -f values.yaml
helm upgrade      <model> modelsphere/<engine> -n <ns> -f values.yaml
kubectl -n <ns> rollout status deploy/<model> --timeout=2h
```

`helm upgrade` returns before the model has loaded; wait on `rollout status`.
Changes to `hangWatcher.config.*` and `modelRoute.*` reload without restarting
the engine.

**Why it does not drop requests.** CART picks up a new engine pod 65–80s after
the rollout (openresty about 16s), and until then keeps sending requests to the
old pod. The old pod keeps serving until it has no requests left, for up to 10
minutes (`lifecycle.preStop.drainSeconds: 600`), which covers both the router
delay and long responses. A response still running after that is cut; an idle
pod exits within seconds.


**No spare GPU for the surge** (not measured). The default is `maxSurge: 1,
maxUnavailable: 0`, so without a free replica's worth of GPUs the new pod stays
Pending.

| Replicas | Do |
| --- | --- |
| 2 or more | Set `strategy.rollingUpdate` to `maxSurge: 0, maxUnavailable: 1`; you lose one replica's capacity during the roll |
| 1 | Free a spare GPU, or schedule an outage window for the full model load |

Keep the `backend-svc` peer in `modelRoute.nginx.peers` (the chart renders it by
default): it is the route that still works if autoconfig is down while an engine
rolls. For LeaderWorkerSet models, surge needs a whole spare
group.

## CART

CART rolls with its model release. It does not drop requests on a normal
rollout. Two things to know:

- **Changing CART settings** (`cart.baseConfig`: anything other than the worker
  list) is not picked up on reload, and blocks later worker-list updates until
  the pod restarts. After every such change run:

  ```bash
  kubectl -n <ns> rollout restart deploy/<release>-cart
  kubectl -n <ns> rollout status  deploy/<release>-cart
  ```

- **Don't force-delete the active CART pod**. Its
  in-flight requests are lost and hang until an idle timeout (~300 s).

Expect the cache hit rate to dip after any CART restart or engine rollout. See
[cart.md](cart.md).

## openresty

```bash
make helm-diff  SELECTOR=name=openresty
make helm-apply SELECTOR=name=openresty
kubectl -n llm-route rollout status deploy/openresty
```

Image tags are pinned in `llmgateway/openresty.yaml.gotmpl` (`image.tag`,
`reload.image`, `ha.image`); bump them there. Route config and API keys reload
on their own; changing `bodylog.host` needs a rollout. Test through the Gateway,
not `kubectl port-forward` (it pins you to one pod).

## autoconfig

```bash
kubectl apply --server-side -f <autoconfig chart>/crds/   # see CRDs
make helm-apply SELECTOR=name=autoconfig
```

It is not on the request path; the routers keep their last config while it
restarts. Don't roll it and a model at the same time. When tearing down, delete
model releases before uninstalling autoconfig, or their ModelRoutes stay stuck
in `Terminating`.

## CRDs

Helm does not upgrade CRDs in a chart's `crds/` directory. If you skip this, new
fields are silently dropped. Apply them before upgrading the chart:

| Chart | CRDs in `crds/` |
| --- | --- |
| autoconfig | `modelroutes.routing.modelsphere.dev` |
| llm-slo-decision-gen (release `llm-slo`) | `llmslorequirements`, `jobslorequirements` |

```bash
helm pull modelsphere/autoconfig --version <new> --untar -d /tmp/ac
kubectl apply --server-side -f /tmp/ac/autoconfig/crds/
```

The llmscaleoperator CRD ships in `templates/` and helm upgrades it.
