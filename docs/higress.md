# Higress: an OpenAI-compatible entry in front of openresty

openresty routes by path: a model is reached at `/<route>/v1/...`. Higress adds
the entry clients expect from an OpenAI-compatible API: they call `/v1/...`
with the model in the request body, and Higress

1. reads `model` from the body (`model-router`) and picks that model's route;
2. authenticates the caller's API key and checks the model's allow list (`key-auth`);
3. records tokens per route, model and caller (`ai-statistics`);
4. replaces the caller's key with the one openresty accepts (`ai-proxy`), so
   openresty keeps a single key while callers each have their own;
5. forwards to openresty under the model's route prefix: a route-level path
   rewrite, or `ai-backend-router` when a model has several backends.

```
client POST /v1/chat/completions {"model":"qwen-trial",...}
  -> model-router   x-higress-llm-model: qwen-trial
  -> Ingress llm-model-qwen-trial (matches that header)
  -> key-auth -> ai-statistics -> ai-proxy [-> ai-backend-router]
  -> openresty:8080 /qwen-trial/v1/chat/completions -> engine
```

It is off by default (`enabled.higress`). Two releases: `higress` (the
`higress-core` chart: gateway and controller, no console) and `higress-llm`
(`llmgateway/higress-llm`: the plugins and one Ingress per model).

## Turning it on

In your environment file:

```yaml
enabled:
  higress: true

higress:
  gateway:
    httpNodePort: 31080          # optional
  # The key openresty accepts. It ends up in plain text in a WasmPlugin in the
  # higress namespace: keep this file private.
  upstreamKey: "sk-..."
  consumers:
  - name: tenant-a
    credentials: ["Bearer sk-tenant-a"]
  - name: ops
    credentials: ["Bearer sk-ops", "Bearer sk-ops-next"]   # two keys: rotation
  models:
  - name: qwen-trial             # the `model` clients send, exact match
    allow: [tenant-a, ops]
    backends:
    - {id: qwen-trial, path: /qwen-trial}                  # openresty route prefix
```

Then `make helm-apply ENV=<env>` (or `helmfile -e <env> -l name=higress -l name=higress-llm apply`).

The chart refuses configurations that would misbehave quietly rather than
render them: a model without an allow list (it would be open to everyone while
`globalAuth` is false), an allow entry that names no consumer, openresty's key
listed as a consumer, a credential without the `Bearer ` prefix (key-auth
compares the whole `Authorization` header), several backends without
`ai-backend-router`, malformed paths and ids.

Check it:

```bash
curl http://<node>:<httpNodePort>/v1/chat/completions \
  -H 'Authorization: Bearer sk-tenant-a' -H 'Content-Type: application/json' \
  -d '{"model":"qwen-trial","messages":[{"role":"user","content":"hi"}],"max_tokens":32}'
```

A caller not on the model's allow list gets 403, a missing or unknown key 401,
both from key-auth with an empty body. To see which layer answered, use the
gateway's access log (`route_name`, `response_code_details`), not the body.

## Several backends per model: ai-backend-router

With `higress.backendRouter.enabled: true` a model may list several openresty
routes. The plugin starts at the lowest `tier`, picks within it by `weight`, and
when a backend answers one of `retryCodes` (429, 502, 503, 504 by default) the
request moves on to the next tier, invisibly to the client:

```yaml
higress:
  backendRouter:
    enabled: true
  models:
  - name: qwen3.5-27b
    allow: [ops]
    backends:
    - {id: h100-ep8, path: /qwen3.5-27b-h100-ep8, tier: 0, weight: 70}
    - {id: h100-pp2, path: /qwen3.5-27b-h100-pp2, tier: 0, weight: 30}
    - {id: b300,     path: /qwen3.5-27b-b300,     tier: 1}
```

The route then has no path rewrite (the plugin owns the path), and an
EnvoyFilter (`ai-backend-router-spill`) replays the original request when the
plugin marks a response for the next tier. What that costs:

- every pass runs the whole filter chain again: authentication, `ai-proxy`,
  `ai-statistics`; a request-count rate limit counts a spilled request twice;
- only errors before the first response byte move on; a stream that breaks
  midway reaches the client;
- request bodies are buffered for the replay, up to
  `backendRouter.maxRequestBodyBytes` (16 MiB; larger requests get 413);
- a spilled request writes one access-log line per pass with the same
  `x-request-id`; for billing keep the line whose `response_code_details`
  does not start with `internal_redirect:`.

## Things to know

- **Only `registryMode: upstream`.** The gateway pods fetch the wasm plugins
  themselves (`higress.plugins.*`), which neither the offline bundle nor a node
  registry mirror covers; the helmfile refuses the other modes. One plugin URL
  the gateway cannot fetch stalls configuration updates for every plugin on it,
  so check a new URL on a test cluster first.
- **No console.** The umbrella `higress` chart always installs it, and the
  console creates a `key-auth.internal` plugin and an Ingress `default` that
  serves its page on `/` of the data-plane port, and resets key-auth's
  `global_auth` when a consumer is saved. Everything here is declared in git.
- **Long requests.** Downstream idle timeout 3600s, rollouts with
  `maxUnavailable: 0`, `EXIT_ON_ZERO_ACTIVE_CONNECTIONS`, and a 3600s
  `terminationGracePeriodSeconds` set by the release's postsync hook (the
  chart has no value for it): a gateway rollout does not cut streams in flight.
- **`globalAuth`.** With `false`, key-auth only checks routes that have an allow
  list, and the chart requires one per model. Set it `true` once every client
  has a consumer.
- **Metrics are per gateway pod.** `ai-statistics` counters live in each pod's
  memory: aggregate with `sum by (...) (increase(...))`. For billing use the
  per-request `ai_log` in the access log.
- **Unknown models.** A request whose `model` matches no Ingress falls through
  to whatever else the gateway routes; with nothing else, it gets 404.
