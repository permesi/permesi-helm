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

{{/* Effective secret name for the database DSN: explicit existingSecret wins; otherwise
     the ESO-generated default target name when ESO is active; otherwise empty (inline). */}}
{{- define "permesi.dbSecretName" -}}
{{- if .Values.database.dsn.existingSecret -}}
{{- .Values.database.dsn.existingSecret -}}
{{- else if and .Values.externalSecret.enabled (ne (default "" .Values.database.dsn.externalSecret.remoteKey) "") -}}
{{- printf "%s-db" (include "permesi.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* Effective secret name for the TLS PEM bundle. */}}
{{- define "permesi.tlsSecretName" -}}
{{- if .Values.tls.existingSecret -}}
{{- .Values.tls.existingSecret -}}
{{- else if and .Values.externalSecret.enabled (ne (default "" .Values.tls.externalSecret.remoteKey) "") -}}
{{- printf "%s-tls" (include "permesi.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* Effective secret name for Vault AppRole credentials. When Vault ESO is active both
     role_id and secret_id are written to one Secret; this returns that single name. */}}
{{- define "permesi.vaultSecretName" -}}
{{- if .Values.vault.roleId.existingSecret -}}
{{- .Values.vault.roleId.existingSecret -}}
{{- else if .Values.vault.secretId.existingSecret -}}
{{- .Values.vault.secretId.existingSecret -}}
{{- else if and .Values.externalSecret.enabled (ne (default "" .Values.vault.externalSecret.remoteKey) "") -}}
{{- printf "%s-vault" (include "permesi.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* Effective secret name for the admission PASERK CA bundle. */}}
{{- define "permesi.admissionCaSecretName" -}}
{{- if .Values.admission.paserkCa.existingSecret -}}
{{- .Values.admission.paserkCa.existingSecret -}}
{{- else if and .Values.externalSecret.enabled (ne (default "" .Values.admission.paserkCa.externalSecret.remoteKey) "") -}}
{{- printf "%s-admission-ca" (include "permesi.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "permesi.validateValues" -}}
{{- $socketMode := ne (default "" .Values.config.socketPath) "" -}}
{{- $vaultEso := and .Values.externalSecret.enabled (ne (default "" .Values.vault.externalSecret.remoteKey) "") -}}
{{- $dsnEso := and .Values.externalSecret.enabled (ne (default "" .Values.database.dsn.externalSecret.remoteKey) "") -}}
{{- $anyRemoteKey := or (ne (default "" .Values.database.dsn.externalSecret.remoteKey) "") (ne (default "" .Values.tls.externalSecret.remoteKey) "") (ne (default "" .Values.vault.externalSecret.remoteKey) "") (ne (default "" .Values.admission.paserkCa.externalSecret.remoteKey) "") -}}
{{- if and .Values.externalSecret.enabled $anyRemoteKey (eq (default "" .Values.externalSecret.store) "") -}}
{{- fail "permesi: externalSecret.store must be set when externalSecret.enabled and any externalSecret.remoteKey is configured" -}}
{{- end -}}
{{- if and $vaultEso (ne (default "" .Values.vault.roleId.existingSecret) "") (ne (default "" .Values.vault.secretId.existingSecret) "") (ne .Values.vault.roleId.existingSecret .Values.vault.secretId.existingSecret) -}}
{{- fail "permesi: vault.roleId.existingSecret and vault.secretId.existingSecret must reference the same Secret when vault.externalSecret.remoteKey is set" -}}
{{- end -}}
{{- if and .Values.autoscaling.enabled (gt (int .Values.autoscaling.minReplicas) (int .Values.autoscaling.maxReplicas)) -}}
{{- fail "permesi: autoscaling.minReplicas must not exceed autoscaling.maxReplicas" -}}
{{- end -}}

{{- if and $socketMode .Values.service.enabled -}}
{{- fail "permesi: service.enabled must be false when config.socketPath is set" -}}
{{- end -}}

{{- $dsnSet := or (ne (default "" .Values.database.dsn.value) "") (ne (default "" .Values.database.dsn.existingSecret) "") $dsnEso -}}
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

{{- $secretIdSet := or (ne (default "" .Values.vault.secretId.value) "") (ne (default "" .Values.vault.secretId.existingSecret) "") $vaultEso -}}
{{- $wrappedTokenSet := or (ne (default "" .Values.vault.wrappedToken.value) "") (ne (default "" .Values.vault.wrappedToken.existingSecret) "") -}}
{{- if and $secretIdSet $wrappedTokenSet -}}
{{- fail "permesi: vault.secretId and vault.wrappedToken are mutually exclusive" -}}
{{- end -}}

{{- $vaultIsTcp := eq (include "permesi.vaultIsTcp" .) "true" -}}
{{- $roleSet := or (ne (default "" .Values.vault.roleId.value) "") (ne (default "" .Values.vault.roleId.existingSecret) "") $vaultEso -}}
{{- if and $vaultIsTcp (not $roleSet) -}}
{{- fail "permesi: vault.roleId must be set when vault.url uses http:// or https://" -}}
{{- end -}}
{{- if and $vaultIsTcp (not (or $secretIdSet $wrappedTokenSet)) -}}
{{- fail "permesi: set vault.secretId or vault.wrappedToken when vault.url uses http:// or https://" -}}
{{- end -}}
{{- end -}}
