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

{{/* Reports "true" if any two normalized directory paths in the list overlap
     (equal, or one is an ancestor of the other). */}}
{{- define "permesi.dirsOverlap" -}}
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
{{- else if and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.database.dsn) "") -}}
{{- printf "%s-db" (include "permesi.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* Effective secret name for the TLS PEM bundle. */}}
{{- define "permesi.tlsSecretName" -}}
{{- if .Values.tls.existingSecret -}}
{{- .Values.tls.existingSecret -}}
{{- else if and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.tls) "") -}}
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
{{- else if and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.vault) "") -}}
{{- printf "%s-vault" (include "permesi.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* Effective secret name for the admission PASERK CA bundle. */}}
{{- define "permesi.admissionCaSecretName" -}}
{{- if .Values.admission.paserkCa.existingSecret -}}
{{- .Values.admission.paserkCa.existingSecret -}}
{{- else if and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.admission.paserkCa) "") -}}
{{- printf "%s-admission-ca" (include "permesi.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "permesi.validateValues" -}}
{{- $socketMode := ne (default "" .Values.config.socketPath) "" -}}
{{- $vaultEso := and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.vault) "") -}}
{{- $dsnEso := and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.database.dsn) "") -}}
{{- if .Values.externalSecret.enabled -}}
{{- $anyRemoteKey := or (ne (dig "externalSecret" "remoteKey" "" .Values.database.dsn) "") (ne (dig "externalSecret" "remoteKey" "" .Values.tls) "") (ne (dig "externalSecret" "remoteKey" "" .Values.vault) "") (ne (dig "externalSecret" "remoteKey" "" .Values.admission.paserkCa) "") -}}
{{- if and $anyRemoteKey (eq (default "" .Values.externalSecret.store) "") -}}
{{- fail "permesi: externalSecret.store must be set when externalSecret.enabled and any externalSecret.remoteKey is configured" -}}
{{- end -}}
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
{{- if and (not .Values.vault.agent.enabled) $vaultIsTcp (not $roleSet) -}}
{{- fail "permesi: vault.roleId must be set when vault.url uses http:// or https://" -}}
{{- end -}}
{{- if and (not .Values.vault.agent.enabled) $vaultIsTcp (not (or $secretIdSet $wrappedTokenSet)) -}}
{{- fail "permesi: set vault.secretId or vault.wrappedToken when vault.url uses http:// or https://" -}}
{{- end -}}

{{- if .Values.vault.agent.enabled -}}
{{- $agent := .Values.vault.agent -}}
{{- $socketMode := ne (default "" .Values.config.socketPath) "" -}}

{{- /* Kubernetes >= 1.29 (native sidecars). */ -}}
{{- if or (lt (.Capabilities.KubeVersion.Major | int) 1) (and (eq (.Capabilities.KubeVersion.Major | int) 1) (lt (.Capabilities.KubeVersion.Minor | int) 29)) -}}
{{- fail "permesi: vault.agent.enabled requires Kubernetes >= 1.29 (native sidecars)" -}}
{{- end -}}

{{- /* Unix target. */ -}}
{{- $url := default "" .Values.vault.url -}}
{{- if or (hasPrefix "http://" $url) (hasPrefix "https://" $url) -}}
{{- fail "permesi: vault.url must be a Unix socket path when vault.agent.enabled" -}}
{{- end -}}
{{- $urlNoScheme := $url -}}
{{- if hasPrefix "unix://" $url -}}
{{- $urlNoScheme = trimPrefix "unix://" $url -}}
{{- end -}}
{{- if not (hasPrefix "/" $urlNoScheme) -}}
{{- fail "permesi: vault.url must be an absolute socket path when vault.agent.enabled" -}}
{{- end -}}

{{- /* Vault origin address. */ -}}
{{- if not (or (hasPrefix "http://" (default "" $agent.address)) (hasPrefix "https://" (default "" $agent.address))) -}}
{{- fail "permesi: vault.agent.address must be an http(s) URL when vault.agent.enabled" -}}
{{- end -}}

{{- /* Kubernetes auth role. */ -}}
{{- if eq (default "" $agent.auth.role) "" -}}
{{- fail "permesi: vault.agent.auth.role must be set when vault.agent.enabled" -}}
{{- end -}}

{{- /* Reject AppRole credentials / wrapped tokens. */ -}}
{{- $approleSet := or (ne (default "" .Values.vault.roleId.value) "") (ne (default "" .Values.vault.roleId.existingSecret) "") (ne (default "" .Values.vault.secretId.value) "") (ne (default "" .Values.vault.secretId.existingSecret) "") (ne (default "" .Values.vault.wrappedToken.value) "") (ne (default "" .Values.vault.wrappedToken.existingSecret) "") -}}
{{- if $approleSet -}}
{{- fail "permesi: vault.roleId/secretId/wrappedToken must not be set when vault.agent.enabled" -}}
{{- end -}}

{{- /* Reject Vault ESO credentials. */ -}}
{{- if and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.vault) "") -}}
{{- fail "permesi: vault.externalSecret.remoteKey must not be set when vault.agent.enabled" -}}
{{- end -}}

{{- /* TLS managed by the agent in TCP mode. */ -}}
{{- if not $socketMode -}}
{{- if or (ne (default "" .Values.tls.existingSecret) "") (and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.tls) "")) -}}
{{- fail "permesi: tls Secret/ESO must not be set when vault.agent.enabled manages TLS" -}}
{{- end -}}
{{- if eq (default "" $agent.pki.role) "" -}}
{{- fail "permesi: vault.agent.pki.role must be set when vault.agent.enabled serves TLS" -}}
{{- end -}}
{{- if eq (default "" $agent.pki.commonName) "" -}}
{{- fail "permesi: vault.agent.pki.commonName must be set when vault.agent.enabled serves TLS" -}}
{{- end -}}
{{- $dnsOk := false -}}
{{- range $agent.pki.dnsNames -}}
{{- if ne (toString .) "" -}}{{- $dnsOk = true -}}{{- end -}}
{{- end -}}
{{- if not $dnsOk -}}
{{- fail "permesi: vault.agent.pki.dnsNames must contain at least one SAN when vault.agent.enabled serves TLS" -}}
{{- end -}}
{{- end -}}

{{- /* PASERK CA managed by the agent. */ -}}
{{- if $agent.paserkCa.enabled -}}
{{- if or (ne (default "" .Values.admission.paserkCa.existingSecret) "") (and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.admission.paserkCa) "")) -}}
{{- fail "permesi: admission.paserkCa Secret/ESO must not be set when vault.agent.paserkCa.enabled" -}}
{{- end -}}
{{- end -}}

{{- /* Injector annotations. */ -}}
{{- $hasInjector := false -}}
{{- range $k, $v := .Values.podAnnotations -}}
{{- if hasPrefix "vault.hashicorp.com/agent" $k -}}{{- $hasInjector = true -}}{{- end -}}
{{- end -}}
{{- if $hasInjector -}}
{{- fail "permesi: vault.hashicorp.com/agent-* injector annotations must not be used when vault.agent.enabled" -}}
{{- end -}}

{{- /* Duplicate chart-owned env entries. */ -}}
{{- $dupEnv := false -}}
{{- range $e := .Values.extraEnv -}}
{{- if or (eq (toString $e.name) "PERMESI_VAULT_URL") (eq (toString $e.name) "PERMESI_TLS_PEM_BUNDLE") (eq (toString $e.name) "PERMESI_ADMISSION_PASERK_CA_PATH") (eq (toString $e.name) "PERMESI_VAULT_ROLE_ID") (eq (toString $e.name) "PERMESI_VAULT_SECRET_ID") (eq (toString $e.name) "PERMESI_VAULT_WRAPPED_TOKEN") -}}{{- $dupEnv = true -}}{{- end -}}
{{- end -}}
{{- if $dupEnv -}}
{{- fail "permesi: extraEnv must not redefine chart-managed Vault/TLS/CA env entries when vault.agent.enabled" -}}
{{- end -}}

{{- /* Reserved mount collisions. */ -}}
{{- $reservedVol := false -}}
{{- range $v := .Values.extraVolumes -}}
{{- if or (eq (toString $v.name) "tls-bundle") (eq (toString $v.name) "admission-paserk-ca") (eq (toString $v.name) "vault-agent-socket") (eq (toString $v.name) "vault-agent-config") (eq (toString $v.name) "vault-agent-token") (eq (toString $v.name) "vault-agent-ca") (eq (toString $v.name) "vault-agent-scratch") -}}{{- $reservedVol = true -}}{{- end -}}
{{- end -}}
{{- if $reservedVol -}}
{{- fail "permesi: extraVolumes must not use reserved volume names when vault.agent.enabled" -}}
{{- end -}}

{{- /* Nonroot UID/GID + fsGroup. */ -}}
{{- $ru := int (default 0 .Values.securityContext.runAsUser) -}}
{{- $rg := int (default 0 .Values.securityContext.runAsGroup) -}}
{{- $fsg := int (default 0 .Values.podSecurityContext.fsGroup) -}}
{{- if or (le $ru 0) (le $rg 0) (le $fsg 0) -}}
{{- fail "permesi: securityContext.runAsUser/runAsGroup and podSecurityContext.fsGroup must be positive integers when vault.agent.enabled" -}}
{{- end -}}

{{- /* automount must be false. */ -}}
{{- if .Values.serviceAccount.automount -}}
{{- fail "permesi: serviceAccount.automount must be false when vault.agent.enabled" -}}
{{- end -}}

{{- /* renewalThreshold strictly between 0 and 1 (no truthiness default). */ -}}
{{- $rt := float64 $agent.pki.renewalThreshold -}}
{{- if or (le $rt 0.0) (ge $rt 1.0) -}}
{{- fail "permesi: vault.agent.pki.renewalThreshold must be strictly between 0 and 1" -}}
{{- end -}}

{{- /* Normalized destination mount directories. */ -}}
{{- $socketDir := clean (include "permesi.agentSocketDir" .) -}}
{{- $tlsDir := clean (include "permesi.agentTlsDir" .) -}}
{{- $caDir := clean (include "permesi.agentAdmissionCaDir" .) -}}

{{- /* Absolute writable artifact destinations. */ -}}
{{- if not (hasPrefix "/" (clean .Values.tls.pemBundlePath)) -}}
{{- fail "permesi: tls.pemBundlePath must be an absolute path when vault.agent.enabled" -}}
{{- end -}}
{{- if not (hasPrefix "/" $caDir) -}}
{{- fail "permesi: admission PASERK CA destination must be an absolute path when vault.agent.enabled" -}}
{{- end -}}

{{- /* Chart-owned mount directories: fixed agent locations + socket/TLS/CA. */ -}}
{{- $chartDirs := list "/vault/config" "/var/run/secrets/vault-token" "/tmp" $socketDir $tlsDir $caDir -}}
{{- if .Values.vault.agent.ca.existingConfigMap -}}
{{- $chartDirs = append $chartDirs "/vault/ca" -}}
{{- end -}}
{{- if eq (include "permesi.dirsOverlap" $chartDirs) "true" -}}
{{- fail (printf "permesi: vault agent destination mount directories must not overlap (got: %s) when vault.agent.enabled" (join ", " $chartDirs)) -}}
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
{{- fail "permesi: extraVolumeMounts must not overlap chart-managed mount directories when vault.agent.enabled" -}}
{{- end -}}
{{- end -}}
{{- end -}}
