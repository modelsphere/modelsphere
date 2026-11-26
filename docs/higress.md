# Higress: an OpenAI-compatible entry in front of openresty

openresty routes by path: a model is reached at `/<route>/v1/...`. Higress adds
the entry clients expect from an OpenAI-compatible API: they call `/v1/...`
with the model in the request body, and Higress

1. reads `model` from the body (`model-router`) and picks that model's route;
2. authenticates the caller's API key and checks the model's allow list (`key-auth`);
3. records tokens per route, model and caller (`ai-statistics`);
4. replaces the caller's key with the one openresty accepts (`ai-proxy`), so
   openresty keeps a single key while callers each have their own;
5. picks one of the model's backends (openresty routes) by tier and weight and
   forwards under its prefix, moving on to the next tier when it answers
   429/502/503/504 (`ai-backend-router`).

```
client POST /v1/chat/completions {"model":"qwen-trial",...}
  -> model-router   x-higress-llm-model: qwen-trial
  -> Ingress llm-fleet-qwen-trial (matches that header)
  -> key-auth -> ai-statistics -> ai-proxy -> ai-backend-router
  -> openresty:8080 /qwen-trial/v1/chat/completions -> engine
```

It is off by default (`enabled.higress`). Two releases: `higress` (the
`higress-core` chart: gateway and controller, no console) and `higress-llm`
(`modelsphere/higress-llm` from [helm-charts](https://github.com/modelsphere/helm-charts/tree/main/charts/higress-llm):
the five plugins and the spill EnvoyFilter, with their gateway-wide settings only).

**Models are not configured here.** Each model clients can ask for is a
`ModelFleet` (`routing.modelsphere.dev/v1alpha1`): one or more members, each a
ModelRoute (one per kind of hardware), under one model name. autoconfig renders
a fleet into the Ingress `llm-fleet-<name>` and one rule in each of key-auth,
ai-statistics, ai-proxy and ai-backend-router. A model on a single kind of
hardware is a fleet with one member. The chart writes no per-route rule because
a WasmPlugin's `matchRules` is replaced as a whole on every write: if the chart
owned any rule, each `helm upgrade` would drop the ones autoconfig wrote.

## Turning it on

In your environment file:

```yaml
enabled:
  higress: true

higress:
  gateway:
    httpNodePort: 31080          # optional
```

Then `make helm-apply ENV=<env>` (or `helmfile -e <env> -l name=higress -l name=autoconfig -l name=higress-llm apply`:
select autoconfig too, since a release outside the selection is not ordered),
then create an APIConsumer per caller and a ModelFleet per model.

**Callers are not configured here either.** Each is an `APIConsumer`
(`routing.modelsphere.dev/v1alpha1`) whose keys are the values of a Secret in its
namespace; autoconfig writes every APIConsumer into key-auth's consumer list.
Adding a tenant or rotating a key (add the new value to the Secret, remove the
old one once the caller has moved) needs no release:

```bash
kubectl -n llm-route create secret generic tenant-a-keys --from-literal=current=sk-tenant-a
kubectl apply -f - <<'YAML'
apiVersion: routing.modelsphere.dev/v1alpha1
kind: APIConsumer
metadata: {name: tenant-a, namespace: llm-route}
spec:
  gateway: {namespace: higress-system}
  credentialsSecretRef: tenant-a-keys
YAML
```

Clients send the key as `Authorization: Bearer <key>`. The keys end up in plain
text in the key-auth WasmPlugin (its config is pushed to the data plane as is).
Which consumers may call a model is the fleet's `spec.gateway.authConsumers`
(a name with no APIConsumer is denied); openresty's key is the Secret named by `spec.gateway.upstreamAuthSecretRef`, so
it is not in any values file. A fleet's `spec.gateway.namespace` must be the
namespace of this release (`namespaces.higress`): autoconfig looks for the
plugins there, and a fleet whose plugins it cannot find is not synced.

This needs an autoconfig release with the ModelFleet and APIConsumer
controllers, and their CRDs applied by hand on an existing cluster (`helm upgrade` does not update a chart's
`crds/`). Apply them before upgrading autoconfig: autoconfig looks for the CRDs
when it starts, so CRDs applied after it is running need `kubectl rollout restart`
of its deployment.

**key-auth's consumer list belongs to autoconfig.** The chart renders key-auth
without it: the list has a single owner under server-side apply, and a value from
the chart would be written over autoconfig's on every upgrade. key-auth refuses a
config without the list and fails closed, for the whole gateway, so autoconfig adds
an empty one when it is missing. This needs autoconfig 0.4.4 or later (the
helmfile refuses an older `versions.autoconfig`): an earlier release never adds
the list, and the gateway stays closed. The helmfile installs `higress` (which brings the WasmPlugin
CRD), then autoconfig, then `higress-llm`: until autoconfig adds the list, key-auth
rejects every request on the gateway. With the CRD already there autoconfig sees
key-auth appear and adds the list at once; an autoconfig started before Higress
picks it up on its next periodic pass, without a restart. Each key may belong to one consumer only: key-auth rejects the whole config
on a duplicate credential.

Check it:

```bash
curl http://<node>:<httpNodePort>/v1/chat/completions \
  -H 'Authorization: Bearer sk-tenant-a' -H 'Content-Type: application/json' \
  -d '{"model":"qwen-trial","messages":[{"role":"user","content":"hi"}],"max_tokens":32}'
```

A caller not on the model's allow list gets 403, a missing or unknown key 401,
both from key-auth with an empty body. To see which layer answered, use the
gateway's access log (`route_name`, `response_code_details`), not the body.

## Spilling to the next tier

When a member answers 429, 502, 503 or 504, ai-backend-router marks the
response and an EnvoyFilter (`ai-backend-router-spill`) replays the original
request, which then skips the tier it already tried, invisibly to the client.
It is on by default (`higress.backendRouter.spill`). What that costs:

- every pass runs the whole filter chain again: authentication, `ai-proxy`,
  `ai-statistics`; a request-count rate limit counts a spilled request twice;
- only errors before the first response byte move on; a stream that breaks
  midway reaches the client;
- request bodies are buffered for the replay, up to
  `backendRouter.maxRequestBodyBytes` (16 MiB; larger requests get 413), on
  **every route of the gateway**, not only fleet routes. The chart refuses a
  limit below the router's own (16 MiB). `spill: false` drops the buffer and the
  replay; a member's 429/5xx then reaches the client;
- a spilled request writes one access-log line per pass with the same
  `x-request-id`; for billing keep the line whose `response_code_details`
  does not start with `internal_redirect:`.

## Things to know

- **Only `registryMode: upstream`.** The gateway pods fetch the wasm plugins
  themselves (`higress.plugins.*`), which neither the offline bundle nor a node
  registry mirror covers; the helmfile refuses the other modes. One plugin URL
  the gateway cannot fetch stalls configuration updates for every plugin on it,
  so check a new URL on a test cluster first. All five plugins are always
  deployed, `ai-backend-router` included, so its image must be reachable from
  the gateway pods even before any fleet exists.
- **No console.** The umbrella `higress` chart always installs it, and the
  console creates a `key-auth.internal` plugin and an Ingress `default` that
  serves its page on `/` of the data-plane port, and resets key-auth's
  `global_auth` when a consumer is saved. Everything here is declared in git.
- **Long requests.** Downstream idle timeout 3600s, rollouts with
  `maxUnavailable: 0`, `EXIT_ON_ZERO_ACTIVE_CONNECTIONS`, and a 3600s
  `terminationGracePeriodSeconds` set by the release's postsync hook (the
  chart has no value for it): a gateway rollout does not cut streams in flight.
- **`globalAuth`.** With `false`, key-auth only checks routes that have an allow
  list: a ModelFleet without `authConsumers` is open. key-auth is deployed even
  with no APIConsumer, so a fleet that names `authConsumers` is never served
  unauthenticated; with no matching consumer every caller is denied. Set it
  `true` once every client has an APIConsumer.
- **Metrics are per gateway pod.** `ai-statistics` counters live in each pod's
  memory: aggregate with `sum by (...) (increase(...))`. For billing use the
  per-request `ai_log` in the access log.
- **Unknown models.** A request whose `model` matches no Ingress falls through
  to whatever else the gateway routes; with nothing else, it gets 404.
