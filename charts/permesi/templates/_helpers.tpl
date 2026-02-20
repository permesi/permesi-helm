{{/* vim: set filetype=mustache: */}}
{{- define "permesi.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "permesi.fullname" -}}
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

{{- define "permesi.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "permesi.labels" -}}
helm.sh/chart: {{ include "permesi.chart" . }}
{{ include "permesi.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "permesi.selectorLabels" -}}
app.kubernetes.io/name: {{ include "permesi.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "permesi.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "permesi.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "permesi.pathDir" -}}
{{- $path := . -}}
{{- if contains "/" $path -}}
{{- regexReplaceAll "/[^/]+$" $path "" -}}
{{- else -}}
.
{{- end -}}
{{- end -}}

{{- define "permesi.pathBase" -}}
{{- regexFind "[^/]+$" . -}}
{{- end -}}

{{- define "permesi.vaultIsTcp" -}}
{{- $url := default "" .Values.vault.url -}}
{{- if or (hasPrefix "http://" $url) (hasPrefix "https://" $url) -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "permesi.validateValues" -}}
{{- $socketMode := ne (default "" .Values.config.socketPath) "" -}}
{{- if and $socketMode .Values.service.enabled -}}
{{- fail "permesi: service.enabled must be false when config.socketPath is set" -}}
{{- end -}}

{{- $dsnSet := or (ne (default "" .Values.database.dsn.value) "") (ne (default "" .Values.database.dsn.existingSecret) "") -}}
{{- if not $dsnSet -}}
{{- fail "permesi: set database.dsn.value or database.dsn.existingSecret" -}}
{{- end -}}

{{- if eq (default "" .Values.admission.paserkUrl) "" -}}
{{- fail "permesi: admission.paserkUrl must be set" -}}
{{- end -}}

{{- if eq (default "" .Values.vault.url) "" -}}
{{- fail "permesi: vault.url must be set" -}}
{{- end -}}

{{- if and (not $socketMode) (eq (default "" .Values.tls.pemBundlePath) "") -}}
{{- fail "permesi: tls.pemBundlePath must be set when not running in socket mode" -}}
{{- end -}}

{{- $secretIdSet := or (ne (default "" .Values.vault.secretId.value) "") (ne (default "" .Values.vault.secretId.existingSecret) "") -}}
{{- $wrappedTokenSet := or (ne (default "" .Values.vault.wrappedToken.value) "") (ne (default "" .Values.vault.wrappedToken.existingSecret) "") -}}
{{- if and $secretIdSet $wrappedTokenSet -}}
{{- fail "permesi: vault.secretId and vault.wrappedToken are mutually exclusive" -}}
{{- end -}}

{{- $vaultIsTcp := eq (include "permesi.vaultIsTcp" .) "true" -}}
{{- $roleSet := or (ne (default "" .Values.vault.roleId.value) "") (ne (default "" .Values.vault.roleId.existingSecret) "") -}}
{{- if and $vaultIsTcp (not $roleSet) -}}
{{- fail "permesi: vault.roleId must be set when vault.url uses http:// or https://" -}}
{{- end -}}
{{- if and $vaultIsTcp (not (or $secretIdSet $wrappedTokenSet)) -}}
{{- fail "permesi: set vault.secretId or vault.wrappedToken when vault.url uses http:// or https://" -}}
{{- end -}}
{{- end -}}
