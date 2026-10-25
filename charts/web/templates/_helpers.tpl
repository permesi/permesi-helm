{{/* vim: set filetype=mustache: */}}
{{- define "web.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "web.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "web.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "web.labels" -}}
helm.sh/chart: {{ include "web.chart" . }}
{{ include "web.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "web.selectorLabels" -}}
app.kubernetes.io/name: {{ include "web.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "web.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "web.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "web.runtimeConfigMapName" -}}
{{- if .Values.runtimeConfig.existingConfigMap -}}
{{- .Values.runtimeConfig.existingConfigMap -}}
{{- else -}}
{{- printf "%s-runtime-config" (include "web.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* SHA-256 of the chart-managed /config.js content, used as a pod annotation
     so that runtime-only upgrades roll the Deployment. Empty when an external
     ConfigMap is used (Helm cannot hash data it does not own). */}}
{{- define "web.runtimeConfigChecksum" -}}
{{- if not .Values.runtimeConfig.existingConfigMap -}}
{{- $json := dict "api_base_url" .Values.runtimeConfig.apiBaseUrl "token_base_url" .Values.runtimeConfig.tokenBaseUrl "client_id" .Values.runtimeConfig.clientId "opaque_server_id" .Values.runtimeConfig.opaqueServerId | toJson -}}
{{- printf "window.PERMESI_CONFIG = %s;" $json | sha256sum -}}
{{- end -}}
{{- end -}}

{{- define "web.validateValues" -}}
{{- if eq (default "" .Values.runtimeConfig.key) "" -}}
{{- fail "web: runtimeConfig.key must not be empty" -}}
{{- end -}}
{{- $cfg := .Values.runtimeConfig -}}
{{- if and (not $cfg.existingConfigMap) (not $cfg.allowBuildDefaults) -}}
{{- if not (trim (default "" $cfg.apiBaseUrl)) -}}
{{- fail "web: runtimeConfig.apiBaseUrl must not be empty (set runtimeConfig.allowBuildDefaults=true to fall back to image-baked endpoints)" -}}
{{- end -}}
{{- if not (trim (default "" $cfg.tokenBaseUrl)) -}}
{{- fail "web: runtimeConfig.tokenBaseUrl must not be empty (set runtimeConfig.allowBuildDefaults=true to fall back to image-baked endpoints)" -}}
{{- end -}}
{{- if not (trim (default "" $cfg.clientId)) -}}
{{- fail "web: runtimeConfig.clientId must not be empty (set runtimeConfig.allowBuildDefaults=true to fall back to image-baked endpoints)" -}}
{{- end -}}
{{- if not (trim (default "" $cfg.opaqueServerId)) -}}
{{- fail "web: runtimeConfig.opaqueServerId must not be empty (set runtimeConfig.allowBuildDefaults=true to fall back to image-baked endpoints)" -}}
{{- end -}}
{{- end -}}
{{- if and .Values.autoscaling.enabled (gt (int .Values.autoscaling.minReplicas) (int .Values.autoscaling.maxReplicas)) -}}
{{- fail "web: autoscaling.minReplicas must not be greater than autoscaling.maxReplicas" -}}
{{- end -}}
{{- end -}}
