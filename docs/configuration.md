# Configuring ModelSphere

The README gets a cluster to its first answer. This page and the ones it links
are for what comes after: what each component can be told, where that setting
lives, and how to change it on a cluster that is serving traffic.

## Where a setting lives

Almost every knob lives in one of three places, and which one decides how you
change it:

| Layer | File | Changed with | Reaches |
|---|---|---|---|
| The cluster | `environments/<env>.yaml`, layered over `environments/default.yaml` | `make helm-apply ENV=<env>` | infrastructure releases: openresty, autoconfig, bodylog, the operators, monitoring |
| One model | that model's values file (`-f` to `helm upgrade --install`, or a `models:` entry passed with `MODELS=`) | `helm upgrade`, or `make helm-apply SELECTOR=tier=model MODELS=...` | the engine, its CART, its route on the router, its scaler and SLO objects |
| Runtime objects | custom resources: `ModelRoute`, `LLMScaler`, `LLMSLORequirement` | normally rendered by the model's chart; `kubectl patch` for a live change | the router and the autoscaler, without restarting anything |

The per-model layer is the one you touch most. A model's chart renders all of
its pieces -- engine, CART, route, scaler -- from one values file, so a model is
added, changed and removed as a unit.

## The guides

| To do this | Read |
|---|---|
| Put a new model into service, or take one out | [deploy-a-model.md](deploy-a-model.md) |
| Limit concurrency or token rate on a route, declare SLOs, require API keys, understand routing and fallback | [routing-and-rate-limiting.md](routing-and-rate-limiting.md) |
| Tune the cache-aware router (CART): prefix matching, load balance, health checks, timeouts | [cart.md](cart.md) |
| Let replica counts follow load or SLOs, or pin them | [autoscaling.md](autoscaling.md) |
| Upgrade or reconfigure any component without dropping requests | [rolling-updates.md](rolling-updates.md) |

Installing, diffing and adding clusters are in
[helmfile-deploy.md](helmfile-deploy.md); air-gapped sites in
[offline-install.md](offline-install.md).

## How a request moves, and which guide owns each hop

```
client ─▶ Gateway (Cilium/Envoy) ─▶ openresty ─▶ CART ─▶ engine pod
                                       │  ▲        │
                                       │  └─ falls back to the engine pods,
                                       │     then to the engine Service
            autoconfig ────────────────┴── writes the route into openresty's
                                           ConfigMap and the worker list into CART's
```

- **Gateway → openresty**: the path carries the route name, `/<route>/v1/...`.
  [deploy-a-model.md](deploy-a-model.md) and the README's step 7.
- **openresty**: admission (keys, limits), then peer choice by tier.
  [routing-and-rate-limiting.md](routing-and-rate-limiting.md).
- **CART**: picks the engine replica that already holds the longest matching
  prefix. [cart.md](cart.md).
- **autoconfig**: keeps both routers' view of the engine pods current. How long
  that takes matters most during updates:
  [rolling-updates.md](rolling-updates.md).
- **Replica count**: [autoscaling.md](autoscaling.md).

## Before changing a live cluster

- `make helm-diff ENV=<env>` (or `helm diff upgrade` for a model) shows what an
  apply would change, and changes nothing.
- Check `ENV` against `kubectl config current-context`: the Makefile does not
  connect the two.
- Upgrade with the full values file (`-f`), not `--reuse-values`.
- Changing CART's own settings, rather than its worker list, needs a CART
  restart to take effect: [cart.md](cart.md).
