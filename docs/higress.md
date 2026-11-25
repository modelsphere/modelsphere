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
(`llmgateway/higress-llm`: the five plugins and the spill EnvoyFilter, with
their gateway-wide settings only).

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
  consumers:
  - name: tenant-a
    credentials: ["Bearer sk-tenant-a"]
  - name: ops
    credentials: ["Bearer sk-ops", "Bearer sk-ops-next"]   # two keys: rotation
```

Then `make helm-apply ENV=<env>` (or `helmfile -e <env> -l name=higress -l name=higress-llm apply`),
and create a ModelFleet per model. Which consumers may call it is the fleet's
`spec.gateway.authConsumers` (a name not in `higress.consumers` is denied);
openresty's key is the Secret named by `spec.gateway.upstreamAuthSecretRef`, so
it is not in any values file. A fleet's `spec.gateway.namespace` must be the
namespace of this release (`namespaces.higress`): autoconfig looks for the
plugins there, and a fleet whose plugins it cannot find is not synced.

This needs an autoconfig release with the ModelFleet controller, and its CRD
applied by hand on an existing cluster (`helm upgrade` does not update a chart's
`crds/`).

The chart refuses values from the earlier per-model layout (`higress.models`,
`higress.upstreamKey`, `higress.backendRouter.enabled/retryCodes/exclude`)
instead of ignoring them, and a credential without the `Bearer ` prefix
(key-auth compares the whole `Authorization` header).

**Upgrading from chart 0.1.x** deletes the chart's `llm-model-*` Ingresses and
its plugin rules: those models stop being served until their ModelFleets exist.
Create the fleets first, then upgrade. What happens to the chart's old rules
depends on how helm applies the release:

- **helm 4 (server-side apply), measured on a test cluster:** once autoconfig
  has written a fleet's rule, it owns each plugin's whole `matchRules` list,
  so the upgrade neither clears the fleets' rules (no gap) nor removes the
  chart's old ones. Those old rules point at the deleted `llm-model-*`
  Ingresses and do nothing, but ai-proxy's still holds openresty's key in
  plain text: remove every rule whose Ingresses are all gone `llm-model-*`
  ones after the upgrade.
- **helm 3 (three-way merge):** the upgrade can clear each plugin's whole rule
  list, the fleets' rules included, until autoconfig's next resync (up to 30s)
  writes them back. Meanwhile fleet routes answer 404 or 401, and are open
  while `globalAuth` is false. Upgrade outside peak hours, or force a resync
  right after.

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
  with no consumers, so a fleet that names `authConsumers` is never served
  unauthenticated; with no matching consumer every caller is denied. Set it
  `true` once every client has a consumer.
- **Metrics are per gateway pod.** `ai-statistics` counters live in each pod's
  memory: aggregate with `sum by (...) (increase(...))`. For billing use the
  per-request `ai_log` in the access log.
- **Unknown models.** A request whose `model` matches no Ingress falls through
  to whatever else the gateway routes; with nothing else, it gets 404.
