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

{{- define "permesi.openbaoIsTcp" -}}
{{- $url := default "" .Values.openbao.url -}}
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

{{/* Effective secret name for OpenBao AppRole credentials. When OpenBao ESO is active both
     role_id and secret_id are written to one Secret; this returns that single name. */}}
{{- define "permesi.openbaoSecretName" -}}
{{- if .Values.openbao.roleId.existingSecret -}}
{{- .Values.openbao.roleId.existingSecret -}}
{{- else if .Values.openbao.secretId.existingSecret -}}
{{- .Values.openbao.secretId.existingSecret -}}
{{- else if and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.openbao) "") -}}
{{- printf "%s-openbao" (include "permesi.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "permesi.validateValues" -}}
{{- /* Chart 0.6 dropped HashiCorp Vault; stale keys would otherwise be ignored silently. */ -}}
{{- if hasKey .Values "vault" -}}
{{- fail "permesi: the vault values block was renamed to openbao; HashiCorp Vault is no longer supported" -}}
{{- end -}}
{{- if hasKey .Values "secretsProvider" -}}
{{- fail "permesi: secretsProvider was removed; the chart always uses OpenBao" -}}
{{- end -}}
{{- include "permesi.validateOpenbaoAuth" . -}}
{{- $socketMode := ne (default "" .Values.config.socketPath) "" -}}
{{- $openbaoEso := and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.openbao) "") -}}
{{- $dsnEso := and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.database.dsn) "") -}}
{{- if .Values.externalSecret.enabled -}}
{{- $anyRemoteKey := or (ne (dig "externalSecret" "remoteKey" "" .Values.database.dsn) "") (ne (dig "externalSecret" "remoteKey" "" .Values.tls) "") (ne (dig "externalSecret" "remoteKey" "" .Values.openbao) "") -}}
{{- if and $anyRemoteKey (eq (default "" .Values.externalSecret.store) "") -}}
{{- fail "permesi: externalSecret.store must be set when externalSecret.enabled and any externalSecret.remoteKey is configured" -}}
{{- end -}}
{{- end -}}
{{- if and $openbaoEso (ne (default "" .Values.openbao.roleId.existingSecret) "") (ne (default "" .Values.openbao.secretId.existingSecret) "") (ne .Values.openbao.roleId.existingSecret .Values.openbao.secretId.existingSecret) -}}
{{- fail "permesi: openbao.roleId.existingSecret and openbao.secretId.existingSecret must reference the same Secret when openbao.externalSecret.remoteKey is set" -}}
{{- end -}}
{{- if and .Values.autoscaling.enabled (gt (int .Values.autoscaling.minReplicas) (int .Values.autoscaling.maxReplicas)) -}}
{{- fail "permesi: autoscaling.minReplicas must not exceed autoscaling.maxReplicas" -}}
{{- end -}}

{{- if and $socketMode .Values.service.enabled -}}
{{- fail "permesi: service.enabled must be false when config.socketPath is set" -}}
{{- end -}}

{{- if or (empty .Values.image.digest) (and .Values.openbao.agent.enabled (or (empty .Values.openbao.agent.image.digest) (not (hasSuffix "/openbao" .Values.openbao.agent.image.repository)))) -}}
{{- fail "OpenBao workloads require pinned application and OpenBao Agent images" -}}
{{- end -}}
{{- range $e := .Values.extraEnv -}}
{{- $name := toString $e.name -}}
{{- if or (hasPrefix "PERMESI_OPENBAO_" $name) (hasPrefix "GENESIS_OPENBAO_" $name) (hasPrefix "PERMESI_ADMISSION_" $name) -}}
{{- fail "Use managed values for OpenBao and admission trust" -}}
{{- end -}}
{{- end -}}
{{- $dsnSet := or (ne (default "" .Values.database.dsn.value) "") (ne (default "" .Values.database.dsn.existingSecret) "") $dsnEso -}}
{{- if not $dsnSet -}}
{{- fail "permesi: set database.dsn.value or database.dsn.existingSecret" -}}
{{- end -}}

{{- if eq (default "" .Values.openbao.url) "" -}}
{{- fail "permesi: openbao.url must be set" -}}
{{- end -}}

{{- if and (not $socketMode) (eq (default "" .Values.tls.pemBundlePath) "") -}}
{{- fail "permesi: tls.pemBundlePath must be set when not running in socket mode" -}}
{{- end -}}

{{- $secretIdSet := or (ne (default "" .Values.openbao.secretId.value) "") (ne (default "" .Values.openbao.secretId.existingSecret) "") $openbaoEso -}}
{{- $wrappedTokenSet := or (ne (default "" .Values.openbao.wrappedToken.value) "") (ne (default "" .Values.openbao.wrappedToken.existingSecret) "") -}}
{{- if and $secretIdSet $wrappedTokenSet -}}
{{- fail "permesi: openbao.secretId and openbao.wrappedToken are mutually exclusive" -}}
{{- end -}}

{{- $openbaoIsTcp := eq (include "permesi.openbaoIsTcp" .) "true" -}}
{{- $roleSet := or (ne (default "" .Values.openbao.roleId.value) "") (ne (default "" .Values.openbao.roleId.existingSecret) "") $openbaoEso -}}
{{- if and (not .Values.openbao.agent.enabled) (ne .Values.openbao.authMethod "kubernetes") $openbaoIsTcp (not $roleSet) -}}
{{- fail "permesi: openbao.roleId must be set when openbao.url uses http:// or https://" -}}
{{- end -}}
{{- if and (not .Values.openbao.agent.enabled) (ne .Values.openbao.authMethod "kubernetes") $openbaoIsTcp (not (or $secretIdSet $wrappedTokenSet)) -}}
{{- fail "permesi: set openbao.secretId or openbao.wrappedToken when openbao.url uses http:// or https://" -}}
{{- end -}}

{{- if .Values.openbao.agent.enabled -}}
{{- $agent := .Values.openbao.agent -}}
{{- $socketMode := ne (default "" .Values.config.socketPath) "" -}}

{{- /* Kubernetes >= 1.29 (native sidecars). */ -}}
{{- $minor := trimSuffix "+" (toString .Capabilities.KubeVersion.Minor) -}}
{{- if or (not (regexMatch "^[0-9]+$" $minor)) (lt (.Capabilities.KubeVersion.Major | int) 1) (and (eq (.Capabilities.KubeVersion.Major | int) 1) (lt ($minor | int) 29)) -}}
{{- fail "permesi: openbao.agent.enabled requires Kubernetes >= 1.29 (native sidecars)" -}}
{{- end -}}

{{- /* Unix target. */ -}}
{{- $url := default "" .Values.openbao.url -}}
{{- if or (hasPrefix "http://" $url) (hasPrefix "https://" $url) -}}
{{- fail "permesi: openbao.url must be a Unix socket path when openbao.agent.enabled" -}}
{{- end -}}
{{- $urlNoScheme := $url -}}
{{- if hasPrefix "unix://" $url -}}
{{- $urlNoScheme = trimPrefix "unix://" $url -}}
{{- end -}}
{{- if not (hasPrefix "/" $urlNoScheme) -}}
{{- fail "permesi: openbao.url must be an absolute socket path when openbao.agent.enabled" -}}
{{- end -}}

{{- /* OpenBao origin address. */ -}}
{{- if not (or (hasPrefix "http://" (default "" $agent.address)) (hasPrefix "https://" (default "" $agent.address))) -}}
{{- fail "permesi: openbao.agent.address must be an http(s) URL when openbao.agent.enabled" -}}
{{- end -}}

{{- /* Kubernetes auth role. */ -}}
{{- if eq (default "" $agent.auth.role) "" -}}
{{- fail "permesi: openbao.agent.auth.role must be set when openbao.agent.enabled" -}}
{{- end -}}

{{- /* Reject AppRole credentials / wrapped tokens. */ -}}
{{- $approleSet := or (ne (default "" .Values.openbao.roleId.value) "") (ne (default "" .Values.openbao.roleId.existingSecret) "") (ne (default "" .Values.openbao.secretId.value) "") (ne (default "" .Values.openbao.secretId.existingSecret) "") (ne (default "" .Values.openbao.wrappedToken.value) "") (ne (default "" .Values.openbao.wrappedToken.existingSecret) "") -}}
{{- if $approleSet -}}
{{- fail "permesi: openbao.roleId/secretId/wrappedToken must not be set when openbao.agent.enabled" -}}
{{- end -}}

{{- /* Reject OpenBao ESO credentials. */ -}}
{{- if and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.openbao) "") -}}
{{- fail "permesi: openbao.externalSecret.remoteKey must not be set when openbao.agent.enabled" -}}
{{- end -}}

{{- /* TLS managed by the agent in TCP mode. */ -}}
{{- if not $socketMode -}}
{{- if or (ne (default "" .Values.tls.existingSecret) "") (and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.tls) "")) -}}
{{- fail "permesi: tls Secret/ESO must not be set when openbao.agent.enabled manages TLS" -}}
{{- end -}}
{{- if eq (default "" $agent.pki.role) "" -}}
{{- fail "permesi: openbao.agent.pki.role must be set when openbao.agent.enabled serves TLS" -}}
{{- end -}}
{{- if eq (default "" $agent.pki.commonName) "" -}}
{{- fail "permesi: openbao.agent.pki.commonName must be set when openbao.agent.enabled serves TLS" -}}
{{- end -}}
{{- $dnsOk := false -}}
{{- range $agent.pki.dnsNames -}}
{{- if ne (toString .) "" -}}{{- $dnsOk = true -}}{{- end -}}
{{- end -}}
{{- if not $dnsOk -}}
{{- fail "permesi: openbao.agent.pki.dnsNames must contain at least one SAN when openbao.agent.enabled serves TLS" -}}
{{- end -}}
{{- end -}}

{{- /* Injector annotations. */ -}}
{{- $hasInjector := false -}}
{{- range $k, $v := .Values.podAnnotations -}}
{{- if hasPrefix "vault.hashicorp.com/agent" $k -}}{{- $hasInjector = true -}}{{- end -}}
{{- end -}}
{{- if $hasInjector -}}
{{- fail "permesi: vault.hashicorp.com/agent-* injector annotations must not be used when openbao.agent.enabled" -}}
{{- end -}}

{{- /* Duplicate chart-owned env entries. */ -}}
{{- $dupEnv := false -}}
{{- range $e := .Values.extraEnv -}}
{{- if or (eq (toString $e.name) "PERMESI_OPENBAO_URL") (eq (toString $e.name) "PERMESI_TLS_PEM_BUNDLE") (eq (toString $e.name) "PERMESI_OPENBAO_ROLE_ID") (eq (toString $e.name) "PERMESI_OPENBAO_SECRET_ID") (eq (toString $e.name) "PERMESI_OPENBAO_WRAPPED_TOKEN") -}}{{- $dupEnv = true -}}{{- end -}}
{{- end -}}
{{- if $dupEnv -}}
{{- fail "permesi: extraEnv must not redefine chart-managed OpenBao/TLS/CA env entries when openbao.agent.enabled" -}}
{{- end -}}

{{- /* Reserved mount collisions. */ -}}
{{- $reservedVol := false -}}
{{- range $v := .Values.extraVolumes -}}
{{- if or (eq (toString $v.name) "tls-bundle") (eq (toString $v.name) "openbao-agent-socket") (eq (toString $v.name) "openbao-agent-config") (eq (toString $v.name) "openbao-agent-token") (eq (toString $v.name) "openbao-agent-ca") (eq (toString $v.name) "openbao-agent-scratch") -}}{{- $reservedVol = true -}}{{- end -}}
{{- end -}}
{{- if $reservedVol -}}
{{- fail "permesi: extraVolumes must not use reserved volume names when openbao.agent.enabled" -}}
{{- end -}}

{{- /* Nonroot UID/GID + fsGroup. */ -}}
{{- $ru := int (default 0 .Values.securityContext.runAsUser) -}}
{{- $rg := int (default 0 .Values.securityContext.runAsGroup) -}}
{{- $fsg := int (default 0 .Values.podSecurityContext.fsGroup) -}}
{{- if or (le $ru 0) (le $rg 0) (le $fsg 0) -}}
{{- fail "permesi: securityContext.runAsUser/runAsGroup and podSecurityContext.fsGroup must be positive integers when openbao.agent.enabled" -}}
{{- end -}}

{{- /* automount must be false. */ -}}
{{- if .Values.serviceAccount.automount -}}
{{- fail "permesi: serviceAccount.automount must be false when openbao.agent.enabled" -}}
{{- end -}}

{{- /* renewalThreshold strictly between 0 and 1 (no truthiness default). */ -}}
{{- $rt := float64 $agent.pki.renewalThreshold -}}
{{- if or (le $rt 0.0) (ge $rt 1.0) -}}
{{- fail "permesi: openbao.agent.pki.renewalThreshold must be strictly between 0 and 1" -}}
{{- end -}}

{{- /* Active artifacts only: inbound TLS is mounted when the agent manages it
     (TCP mode) or a legacy TLS Secret is requested. */ -}}
{{- $agentManagesTls := not $socketMode -}}
{{- $mountTls := or $agentManagesTls (ne (include "permesi.tlsSecretName" .) "") -}}

{{- /* Absolute writable artifact destinations. */ -}}
{{- if and $mountTls (not (hasPrefix "/" (clean (default "" .Values.tls.pemBundlePath)))) -}}
{{- fail "permesi: tls.pemBundlePath must be an absolute path when openbao.agent.enabled" -}}
{{- end -}}

{{- /* Each managed artifact needs its own mount directory: a file directly in
     / would yield an empty mountPath (or mount over the root filesystem). */ -}}
{{- $socketDir := clean (include "permesi.agentSocketDir" .) -}}
{{- if or (eq $socketDir ".") (eq $socketDir "/") -}}
{{- fail "permesi: openbao.url socket must be inside a dedicated directory, not directly in / when openbao.agent.enabled" -}}
{{- end -}}
{{- if $mountTls -}}
{{- $tlsDir := clean (include "permesi.agentTlsDir" .) -}}
{{- if or (eq $tlsDir ".") (eq $tlsDir "/") -}}
{{- fail "permesi: tls.pemBundlePath must be inside a dedicated directory, not directly in / when openbao.agent.enabled" -}}
{{- end -}}
{{- end -}}

{{- /* Normalized chart-owned mount directories: fixed agent locations, the
     socket and each active artifact. */ -}}
{{- $chartDirs := list "/openbao/config" "/var/run/secrets/openbao-token" "/tmp" $socketDir -}}
{{- if $mountTls -}}
{{- $chartDirs = append $chartDirs (clean (include "permesi.agentTlsDir" .)) -}}
{{- end -}}
{{- if .Values.openbao.agent.ca.existingConfigMap -}}
{{- $chartDirs = append $chartDirs "/openbao/ca" -}}
{{- end -}}
{{- if eq (include "permesi.dirsOverlap" $chartDirs) "true" -}}
{{- fail (printf "permesi: OpenBao Agent destination mount directories must not overlap (got: %s) when openbao.agent.enabled" (join ", " $chartDirs)) -}}
{{- end -}}

{{- /* extraVolumeMounts must not collide with chart-owned mount directories. */ -}}
{{- $extraCollision := false -}}
{{- range $m := .Values.extraVolumeMounts -}}
{{- $mp := clean (toString (default "" $m.mountPath)) -}}
{{- range $d := $chartDirs -}}
{{- if eq (include "permesi.dirsOverlap" (list $mp (toString $d))) "true" -}}
{{- $extraCollision = true -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $extraCollision -}}
{{- fail "permesi: extraVolumeMounts must not overlap chart-managed mount directories when openbao.agent.enabled" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Image reference for an image values block ({repository, tag, digest}).
A non-empty digest pins the image as repository@digest and takes precedence
over the tag; otherwise renders repository:tag.
*/}}
{{- define "permesi.image" -}}
{{- if .digest -}}
{{- printf "%s@%s" .repository .digest -}}
{{- else -}}
{{- printf "%s:%v" .repository .tag -}}
{{- end -}}
{{- end -}}
