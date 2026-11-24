{{/* Ingress name of a model: llm-model-<model name as a DNS label>. */}}
{{- define "higress-llm.ingressName" -}}
{{- $n := regexReplaceAll "[^a-z0-9-]+" (lower .) "-" | trimAll "-" -}}
{{- printf "llm-model-%s" $n | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* <namespace>/<ingress> of every model, the form WasmPlugin matchRules take. */}}
{{- define "higress-llm.ingressRefs" -}}
{{- $ns := .Values.upstream.namespace -}}
{{- range .Values.models }}
- {{ printf "%s/%s" $ns (include "higress-llm.ingressName" .name) }}
{{- end }}
{{- end -}}

{{/*
  Everything that would otherwise go wrong quietly at runtime fails the render
  instead: a model nobody is allowed to call is served to everybody while
  global_auth is false; a consumer name that is not defined denies everyone;
  the upstream key registered as a consumer makes a request whose key ai-proxy
  already swapped authenticate as that consumer.
*/}}
{{- define "higress-llm.validate" -}}
{{- $v := .Values -}}
{{- if $v.models }}
{{-   if not $v.upstreamKey }}{{ fail "higress.upstreamKey is empty: ai-proxy has no key to send to openresty, and every request would get openresty's 401." }}{{ end }}
{{- end }}
{{- $consumers := dict -}}
{{- range $v.consumers }}
{{-   if not .name }}{{ fail "higress.consumers: an entry has no name." }}{{ end }}
{{-   if hasKey $consumers .name }}{{ fail (printf "higress.consumers: %q is listed twice." .name) }}{{ end }}
{{-   if not .credentials }}{{ fail (printf "higress.consumers[%s]: no credentials." .name) }}{{ end }}
{{-   range .credentials }}
{{-     if not (hasPrefix "Bearer " .) }}{{ fail (printf "higress.consumers: credential %q does not start with \"Bearer \": key-auth compares the whole Authorization header." .) }}{{ end }}
{{-     if and $v.upstreamKey (eq . (printf "Bearer %s" $v.upstreamKey)) }}{{ fail "higress.consumers: the upstream key is also a consumer credential. Keep openresty's key out of consumers." }}{{ end }}
{{-   end }}
{{-   $_ := set $consumers .name true }}
{{- end }}
{{- $names := dict -}}
{{- $ingresses := dict -}}
{{- range $v.models }}
{{-   $m := . }}
{{-   if not $m.name }}{{ fail "higress.models: an entry has no name." }}{{ end }}
{{-   if hasKey $names $m.name }}{{ fail (printf "higress.models: %q is listed twice." $m.name) }}{{ end }}
{{-   $_ := set $names $m.name true }}
{{-   $ing := include "higress-llm.ingressName" $m.name }}
{{-   if hasKey $ingresses $ing }}{{ fail (printf "higress.models: %q and %q both become Ingress %s." (index $ingresses $ing) $m.name $ing) }}{{ end }}
{{-   $_ := set $ingresses $ing $m.name }}
{{-   if not $m.allow }}{{ fail (printf "higress.models[%s]: empty allow list. With global_auth false it would be served without authentication." $m.name) }}{{ end }}
{{-   range $m.allow }}
{{-     if not (hasKey $consumers .) }}{{ fail (printf "higress.models[%s].allow: %q is not in higress.consumers." $m.name .) }}{{ end }}
{{-   end }}
{{-   if not $m.backends }}{{ fail (printf "higress.models[%s]: no backends." $m.name) }}{{ end }}
{{-   if and (not $v.backendRouter.enabled) (gt (len $m.backends) 1) }}{{ fail (printf "higress.models[%s]: %d backends need higress.backendRouter.enabled; without it a model is one openresty route." $m.name (len $m.backends)) }}{{ end }}
{{-   $ids := dict }}
{{-   range $m.backends }}
{{-     if not (regexMatch "^[a-z0-9][a-z0-9._-]{0,62}$" (toString .id)) }}{{ fail (printf "higress.models[%s].backends: id %q must match [a-z0-9][a-z0-9._-]{0,62}." $m.name (toString .id)) }}{{ end }}
{{-     if hasKey $ids .id }}{{ fail (printf "higress.models[%s].backends: id %q twice." $m.name .id) }}{{ end }}
{{-     $_ := set $ids .id true }}
{{-     if not (regexMatch "^(/[A-Za-z0-9._~-]+)+$" (toString .path)) }}{{ fail (printf "higress.models[%s].backends[%s]: path %q must be /segment[/segment...], no trailing /." $m.name .id (toString .path)) }}{{ end }}
{{-   end }}
{{- end }}
{{- end -}}
