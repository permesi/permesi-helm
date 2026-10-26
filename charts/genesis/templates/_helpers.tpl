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

{{/* Reports "true" if any two normalized directory paths in the list overlap
     (equal, or one is an ancestor of the other). */}}
{{- define "genesis.dirsOverlap" -}}
{{- $dirs := . -}}
{{- $bad := false -}}
{{- range $i, $a := $dirs -}}
{{- range $j, $b := $dirs -}}
{{- if gt $j $i -}}
{{- $aa := toString $a -}}
{{- $bb := toString $b -}}
{{- if or (eq $aa $bb) (eq $aa "/") (eq $bb "/") (hasPrefix (printf "%s/" $aa) $bb) (hasPrefix (printf "%s/" $bb) $aa) -}}
{{- $bad = true -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $bad -}}true{{- else -}}false{{- end -}}
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
{{- if and (not .Values.vault.agent.enabled) $vaultIsTcp (not $roleSet) -}}
{{- fail "genesis: vault.roleId must be set when vault.url uses http:// or https://" -}}
{{- end -}}
{{- if and (not .Values.vault.agent.enabled) $vaultIsTcp (not (or $secretIdSet $wrappedTokenSet)) -}}
{{- fail "genesis: set vault.secretId or vault.wrappedToken when vault.url uses http:// or https://" -}}
{{- end -}}

{{- if .Values.vault.agent.enabled -}}
{{- $agent := .Values.vault.agent -}}
{{- $socketMode := ne (default "" .Values.config.socketPath) "" -}}

{{- /* Kubernetes >= 1.29 (native sidecars). */ -}}
{{- if or (lt (.Capabilities.KubeVersion.Major | int) 1) (and (eq (.Capabilities.KubeVersion.Major | int) 1) (lt (.Capabilities.KubeVersion.Minor | int) 29)) -}}
{{- fail "genesis: vault.agent.enabled requires Kubernetes >= 1.29 (native sidecars)" -}}
{{- end -}}

{{- /* Unix target. */ -}}
{{- $url := default "" .Values.vault.url -}}
{{- if or (hasPrefix "http://" $url) (hasPrefix "https://" $url) -}}
{{- fail "genesis: vault.url must be a Unix socket path when vault.agent.enabled" -}}
{{- end -}}
{{- $urlNoScheme := $url -}}
{{- if hasPrefix "unix://" $url -}}
{{- $urlNoScheme = trimPrefix "unix://" $url -}}
{{- end -}}
{{- if not (hasPrefix "/" $urlNoScheme) -}}
{{- fail "genesis: vault.url must be an absolute socket path when vault.agent.enabled" -}}
{{- end -}}

{{- /* Vault origin address. */ -}}
{{- if not (or (hasPrefix "http://" (default "" $agent.address)) (hasPrefix "https://" (default "" $agent.address))) -}}
{{- fail "genesis: vault.agent.address must be an http(s) URL when vault.agent.enabled" -}}
{{- end -}}

{{- /* Kubernetes auth role. */ -}}
{{- if eq (default "" $agent.auth.role) "" -}}
{{- fail "genesis: vault.agent.auth.role must be set when vault.agent.enabled" -}}
{{- end -}}

{{- /* Reject AppRole credentials / wrapped tokens. */ -}}
{{- $approleSet := or (ne (default "" .Values.vault.roleId.value) "") (ne (default "" .Values.vault.roleId.existingSecret) "") (ne (default "" .Values.vault.secretId.value) "") (ne (default "" .Values.vault.secretId.existingSecret) "") (ne (default "" .Values.vault.wrappedToken.value) "") (ne (default "" .Values.vault.wrappedToken.existingSecret) "") -}}
{{- if $approleSet -}}
{{- fail "genesis: vault.roleId/secretId/wrappedToken must not be set when vault.agent.enabled" -}}
{{- end -}}

{{- /* Reject Vault ESO credentials. */ -}}
{{- if and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.vault) "") -}}
{{- fail "genesis: vault.externalSecret.remoteKey must not be set when vault.agent.enabled" -}}
{{- end -}}

{{- /* TLS managed by the agent in TCP mode. */ -}}
{{- if not $socketMode -}}
{{- if or (ne (default "" .Values.tls.existingSecret) "") (and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.tls) "")) -}}
{{- fail "genesis: tls Secret/ESO must not be set when vault.agent.enabled manages TLS" -}}
{{- end -}}
{{- if eq (default "" $agent.pki.role) "" -}}
{{- fail "genesis: vault.agent.pki.role must be set when vault.agent.enabled serves TLS" -}}
{{- end -}}
{{- if eq (default "" $agent.pki.commonName) "" -}}
{{- fail "genesis: vault.agent.pki.commonName must be set when vault.agent.enabled serves TLS" -}}
{{- end -}}
{{- $dnsOk := false -}}
{{- range $agent.pki.dnsNames -}}
{{- if ne (toString .) "" -}}{{- $dnsOk = true -}}{{- end -}}
{{- end -}}
{{- if not $dnsOk -}}
{{- fail "genesis: vault.agent.pki.dnsNames must contain at least one SAN when vault.agent.enabled serves TLS" -}}
{{- end -}}
{{- end -}}

{{- /* Injector annotations. */ -}}
{{- $hasInjector := false -}}
{{- range $k, $v := .Values.podAnnotations -}}
{{- if hasPrefix "vault.hashicorp.com/agent" $k -}}{{- $hasInjector = true -}}{{- end -}}
{{- end -}}
{{- if $hasInjector -}}
{{- fail "genesis: vault.hashicorp.com/agent-* injector annotations must not be used when vault.agent.enabled" -}}
{{- end -}}

{{- /* Duplicate chart-owned env entries. */ -}}
{{- $dupEnv := false -}}
{{- range $e := .Values.extraEnv -}}
{{- if or (eq (toString $e.name) "GENESIS_VAULT_URL") (eq (toString $e.name) "GENESIS_TLS_PEM_BUNDLE") (eq (toString $e.name) "GENESIS_VAULT_ROLE_ID") (eq (toString $e.name) "GENESIS_VAULT_SECRET_ID") (eq (toString $e.name) "GENESIS_VAULT_WRAPPED_TOKEN") -}}{{- $dupEnv = true -}}{{- end -}}
{{- end -}}
{{- if $dupEnv -}}
{{- fail "genesis: extraEnv must not redefine chart-managed Vault/TLS env entries when vault.agent.enabled" -}}
{{- end -}}

{{- /* Reserved mount collisions. */ -}}
{{- $reservedVol := false -}}
{{- range $v := .Values.extraVolumes -}}
{{- if or (eq (toString $v.name) "tls-bundle") (eq (toString $v.name) "vault-agent-socket") (eq (toString $v.name) "vault-agent-config") (eq (toString $v.name) "vault-agent-token") (eq (toString $v.name) "vault-agent-ca") (eq (toString $v.name) "vault-agent-scratch") -}}{{- $reservedVol = true -}}{{- end -}}
{{- end -}}
{{- if $reservedVol -}}
{{- fail "genesis: extraVolumes must not use reserved volume names when vault.agent.enabled" -}}
{{- end -}}

{{- /* Nonroot UID/GID + fsGroup. */ -}}
{{- $ru := int (default 0 .Values.securityContext.runAsUser) -}}
{{- $rg := int (default 0 .Values.securityContext.runAsGroup) -}}
{{- $fsg := int (default 0 .Values.podSecurityContext.fsGroup) -}}
{{- if or (le $ru 0) (le $rg 0) (le $fsg 0) -}}
{{- fail "genesis: securityContext.runAsUser/runAsGroup and podSecurityContext.fsGroup must be positive integers when vault.agent.enabled" -}}
{{- end -}}

{{- /* automount must be false. */ -}}
{{- if .Values.serviceAccount.automount -}}
{{- fail "genesis: serviceAccount.automount must be false when vault.agent.enabled" -}}
{{- end -}}

{{- /* renewalThreshold strictly between 0 and 1. */ -}}
{{- $rt := float64 (default 0.8 $agent.pki.renewalThreshold) -}}
{{- if or (le $rt 0.0) (ge $rt 1.0) -}}
{{- fail "genesis: vault.agent.pki.renewalThreshold must be strictly between 0 and 1" -}}
{{- end -}}

{{- /* Normalized destination mount directories. */ -}}
{{- $socketDir := clean (include "genesis.agentSocketDir" .) -}}
{{- $tlsDir := clean (include "genesis.agentTlsDir" .) -}}

{{- /* Absolute writable artifact destinations. */ -}}
{{- if not (hasPrefix "/" (clean .Values.tls.pemBundlePath)) -}}
{{- fail "genesis: tls.pemBundlePath must be an absolute path when vault.agent.enabled" -}}
{{- end -}}

{{- /* Chart-owned mount directories: fixed agent locations + socket/TLS. */ -}}
{{- $chartDirs := list "/vault/config" "/var/run/secrets/vault-token" "/tmp" $socketDir $tlsDir -}}
{{- if .Values.vault.agent.ca.existingConfigMap -}}
{{- $chartDirs = append $chartDirs "/vault/ca" -}}
{{- end -}}
{{- if eq (include "genesis.dirsOverlap" $chartDirs) "true" -}}
{{- fail (printf "genesis: vault agent destination mount directories must not overlap (got: %s) when vault.agent.enabled" (join ", " $chartDirs)) -}}
{{- end -}}

{{- /* extraVolumeMounts must not collide with chart-owned mount directories. */ -}}
{{- $extraCollision := false -}}
{{- range $m := .Values.extraVolumeMounts -}}
{{- $mp := clean (toString (default "" $m.mountPath)) -}}
{{- range $d := $chartDirs -}}
{{- $dd := toString $d -}}
{{- if or (eq $mp $dd) (hasPrefix (printf "%s/" $dd) $mp) (hasPrefix (printf "%s/" $mp) $dd) -}}
{{- $extraCollision = true -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $extraCollision -}}
{{- fail "genesis: extraVolumeMounts must not overlap chart-managed mount directories when vault.agent.enabled" -}}
{{- end -}}
{{- end -}}
{{- end -}}
