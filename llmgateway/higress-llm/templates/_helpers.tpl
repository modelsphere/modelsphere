{{/*
  The chart renders the gateway-wide part only. Per-model routes (an Ingress
  llm-fleet-<name> each) and every plugin's per-route rule are written by
  autoconfig from ModelFleet objects. WasmPlugin matchRules is an atomic list:
  if this chart wrote any rule, each helm upgrade would drop autoconfig's.
  Values from the earlier per-model layout fail the render instead of being
  ignored, so an old environment file is noticed rather than silently serving
  nothing.
*/}}
{{- define "higress-llm.validate" -}}
{{- $v := .Values -}}
{{- if $v.models }}{{ fail "higress.models is gone: models are ModelFleet objects now (routing.modelsphere.dev/v1alpha1), rendered into the gateway by autoconfig. Create one ModelFleet per model (a single member for single-hardware models) and remove higress.models." }}{{ end }}
{{- if $v.upstreamKey }}{{ fail "higress.upstreamKey is gone: each ModelFleet names the openresty key in spec.gateway.upstreamAuthSecretRef. Remove higress.upstreamKey." }}{{ end }}
{{- range $k := list "enabled" "retryCodes" "exclude" }}
{{-   if hasKey $v.backendRouter $k }}{{ fail (printf "higress.backendRouter.%s is gone: ai-backend-router is always deployed and autoconfig writes its per-route config. Keep only backendRouter.spill and backendRouter.maxRequestBodyBytes." $k) }}{{ end }}
{{- end }}
{{- if lt (int64 $v.backendRouter.maxRequestBodyBytes) 16777216 }}{{ fail (printf "higress.backendRouter.maxRequestBodyBytes %v is below ai-backend-router's own limit (16777216, set by autoconfig): a body the router accepts could not be replayed on spill." $v.backendRouter.maxRequestBodyBytes) }}{{ end }}
{{- if $v.consumers }}{{ fail "higress.consumers is gone: each caller is an APIConsumer object (routing.modelsphere.dev/v1alpha1) with its keys in a Secret, written into key-auth by autoconfig. Create one per consumer and remove higress.consumers." }}{{ end }}
{{- end -}}
