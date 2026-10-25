{{/* vim: set filetype=mustache: */}}
{{- define "genesis.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "genesis.fullname" -}}
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

{{- define "genesis.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "genesis.labels" -}}
helm.sh/chart: {{ include "genesis.chart" . }}
{{ include "genesis.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "genesis.selectorLabels" -}}
app.kubernetes.io/name: {{ include "genesis.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "genesis.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "genesis.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "genesis.pathDir" -}}
{{- $path := . -}}
{{- if contains "/" $path -}}
{{- regexReplaceAll "/[^/]+$" $path "" -}}
{{- else -}}
.
{{- end -}}
{{- end -}}

{{- define "genesis.pathBase" -}}
{{- regexFind "[^/]+$" . -}}
{{- end -}}

{{- define "genesis.vaultIsTcp" -}}
{{- $url := default "" .Values.vault.url -}}
{{- if or (hasPrefix "http://" $url) (hasPrefix "https://" $url) -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "genesis.dbEsoActive" -}}
{{- if and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.database.dsn) "") -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "genesis.tlsEsoActive" -}}
{{- if and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.tls) "") -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "genesis.vaultEsoActive" -}}
{{- if and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.vault) "") -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "genesis.dbSecretName" -}}
{{- if .Values.database.dsn.existingSecret -}}
{{- .Values.database.dsn.existingSecret -}}
{{- else if eq (include "genesis.dbEsoActive" .) "true" -}}
{{- printf "%s-db" (include "genesis.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "genesis.tlsSecretName" -}}
{{- if .Values.tls.existingSecret -}}
{{- .Values.tls.existingSecret -}}
{{- else if eq (include "genesis.tlsEsoActive" .) "true" -}}
{{- printf "%s-tls" (include "genesis.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "genesis.vaultEsoTarget" -}}
{{- if .Values.vault.roleId.existingSecret -}}
{{- .Values.vault.roleId.existingSecret -}}
{{- else if .Values.vault.secretId.existingSecret -}}
{{- .Values.vault.secretId.existingSecret -}}
{{- else -}}
{{- printf "%s-vault" (include "genesis.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "genesis.vaultRoleIdSecretName" -}}
{{- if .Values.vault.roleId.existingSecret -}}
{{- .Values.vault.roleId.existingSecret -}}
{{- else if eq (include "genesis.vaultEsoActive" .) "true" -}}
{{- include "genesis.vaultEsoTarget" . -}}
{{- end -}}
{{- end -}}

{{- define "genesis.vaultSecretIdSecretName" -}}
{{- if .Values.vault.secretId.existingSecret -}}
{{- .Values.vault.secretId.existingSecret -}}
{{- else if eq (include "genesis.vaultEsoActive" .) "true" -}}
{{- include "genesis.vaultEsoTarget" . -}}
{{- end -}}
{{- end -}}

{{- define "genesis.validateValues" -}}
{{- $socketMode := ne (default "" .Values.config.socketPath) "" -}}
{{- if and $socketMode .Values.service.enabled -}}
{{- fail "genesis: service.enabled must be false when config.socketPath is set" -}}
{{- end -}}

{{- $dbEsoActive := eq (include "genesis.dbEsoActive" .) "true" -}}
{{- $vaultEsoActive := eq (include "genesis.vaultEsoActive" .) "true" -}}

{{- $dsnSet := or (ne (default "" .Values.database.dsn.value) "") (ne (default "" .Values.database.dsn.existingSecret) "") $dbEsoActive -}}
{{- if not $dsnSet -}}
{{- fail "genesis: set database.dsn.value, database.dsn.existingSecret, or database.dsn.externalSecret.remoteKey" -}}
{{- end -}}

{{- if eq (default "" .Values.vault.url) "" -}}
{{- fail "genesis: vault.url must be set" -}}
{{- end -}}

{{- if and (not $socketMode) (eq (default "" .Values.tls.pemBundlePath) "") -}}
{{- fail "genesis: tls.pemBundlePath must be set when not running in socket mode" -}}
{{- end -}}

{{- if and .Values.autoscaling.enabled (gt (int (default 0 .Values.autoscaling.minReplicas)) (int (default 0 .Values.autoscaling.maxReplicas))) -}}
{{- fail "genesis: autoscaling.minReplicas must not exceed autoscaling.maxReplicas" -}}
{{- end -}}

{{- if .Values.externalSecret.enabled -}}
{{- $esoRemoteSet := or (ne (dig "externalSecret" "remoteKey" "" .Values.database.dsn) "") (ne (dig "externalSecret" "remoteKey" "" .Values.tls) "") (ne (dig "externalSecret" "remoteKey" "" .Values.vault) "") -}}
{{- if and $esoRemoteSet (eq (default "" .Values.externalSecret.store) "") -}}
{{- fail "genesis: externalSecret.store must be set when any externalSecret.remoteKey is set" -}}
{{- end -}}
{{- end -}}

{{- if $vaultEsoActive -}}
{{- $rid := default "" .Values.vault.roleId.existingSecret -}}
{{- $sid := default "" .Values.vault.secretId.existingSecret -}}
{{- if and (ne $rid "") (ne $sid "") (ne $rid $sid) -}}
{{- fail "genesis: when vault ESO is enabled, vault.roleId.existingSecret and vault.secretId.existingSecret must reference the same Secret" -}}
{{- end -}}
{{- end -}}

{{- $secretIdSet := or (ne (default "" .Values.vault.secretId.value) "") (ne (default "" .Values.vault.secretId.existingSecret) "") $vaultEsoActive -}}
{{- $wrappedTokenSet := or (ne (default "" .Values.vault.wrappedToken.value) "") (ne (default "" .Values.vault.wrappedToken.existingSecret) "") -}}
{{- if and $secretIdSet $wrappedTokenSet -}}
{{- fail "genesis: vault.secretId and vault.wrappedToken are mutually exclusive" -}}
{{- end -}}

{{- $vaultIsTcp := eq (include "genesis.vaultIsTcp" .) "true" -}}
{{- $roleSet := or (ne (default "" .Values.vault.roleId.value) "") (ne (default "" .Values.vault.roleId.existingSecret) "") $vaultEsoActive -}}
{{- if and $vaultIsTcp (not $roleSet) -}}
{{- fail "genesis: vault.roleId must be set when vault.url uses http:// or https://" -}}
{{- end -}}
{{- if and $vaultIsTcp (not (or $secretIdSet $wrappedTokenSet)) -}}
{{- fail "genesis: set vault.secretId or vault.wrappedToken when vault.url uses http:// or https://" -}}
{{- end -}}
{{- end -}}
