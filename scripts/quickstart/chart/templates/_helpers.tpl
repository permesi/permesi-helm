{{/* vim: set filetype=mustache: */}}
{{- define "quickstart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "quickstart.fullname" -}}
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

{{- define "quickstart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "quickstart.labels" -}}
helm.sh/chart: {{ include "quickstart.chart" . }}
{{ include "quickstart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "quickstart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "quickstart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Restricted-PSA container security context (non-root identity set per workload). */}}
{{- define "quickstart.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end -}}

{{- define "quickstart.credentialsSecretName" -}}
{{- .Values.bootstrap.credentialsSecret | default (printf "%s-bootstrap-credentials" (include "quickstart.fullname" .)) -}}
{{- end -}}

{{- define "quickstart.postgresqlServiceName" -}}
{{- .Values.postgresql.service.name | default (printf "%s-postgresql" (include "quickstart.fullname" .)) -}}
{{- end -}}

{{- define "quickstart.vaultServiceName" -}}
{{- .Values.vault.service.name | default (printf "%s-vault" (include "quickstart.fullname" .)) -}}
{{- end -}}

{{- define "quickstart.vaultAddr" -}}
{{- printf "http://%s.%s.svc:%v" (include "quickstart.vaultServiceName" .) .Release.Namespace .Values.vault.service.port -}}
{{- end -}}

{{- define "quickstart.image" -}}
{{- if .digest -}}
{{- printf "%s@%s" .repository .digest -}}
{{- else -}}
{{- printf "%s:%s" .repository .tag -}}
{{- end -}}
{{- end -}}

{{/* Cluster-scoped TokenReview grant name (release + namespace scoped). */}}
{{- define "quickstart.tokenReviewName" -}}
{{- printf "%s-%s-tokenreview" (include "quickstart.fullname" .) .Release.Namespace | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Component fullname convention shared by direct and umbrella installs.
     Explicit names cover component fullnameOverride/serviceAccount.name. */}}
{{- define "quickstart.applicationName" -}}
{{- $explicit := (index .root.Values.bootstrap.services .service).serviceName -}}
{{- if $explicit -}}
{{- $explicit -}}
{{- else if contains .service .root.Release.Name -}}
{{- .root.Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .root.Release.Name .service | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Per-service PKI role names: exact Service DNS forms + browser hostnames. */}}
{{- define "quickstart.serviceDnsNames" -}}
{{- $svc := .name -}}
{{- $ns := .ns -}}
{{- $names := list $svc (printf "%s.%s" $svc $ns) (printf "%s.%s.svc" $svc $ns) (printf "%s.%s.svc.cluster.local" $svc $ns) -}}
{{- join "," (concat $names (.svc.browserDnsNames | default list)) -}}
{{- end -}}

{{- define "quickstart.validateValues" -}}
{{- if ne .Values.acknowledgeDevelopment true -}}
{{- fail "permesi-quickstart: acknowledgeDevelopment must be true to deploy disposable development dependencies (NOT for production)" -}}
{{- end -}}
{{- $schema := .Values.bootstrap.schema -}}
{{- $hasUrl := ne ($schema.sourceUrl | default "") "" -}}
{{- $hasCms := gt (len ($schema.existingConfigMaps | default list)) 0 -}}
{{- if eq $hasUrl $hasCms -}}
{{- fail "permesi-quickstart: set exactly one of bootstrap.schema.sourceUrl or bootstrap.schema.existingConfigMaps" -}}
{{- end -}}
{{- if and $hasUrl (not (regexMatch "^https://" $schema.sourceUrl)) -}}
{{- fail "permesi-quickstart: bootstrap.schema.sourceUrl must be https://" -}}
{{- end -}}
{{- if and $hasUrl (not (regexMatch "^[0-9a-f]{64}$" ($schema.sha256 | default ""))) -}}
{{- fail "permesi-quickstart: bootstrap.schema.sha256 (64 lowercase hex) is required with bootstrap.schema.sourceUrl" -}}
{{- end -}}
{{- end -}}
