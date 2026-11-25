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

{{- define "genesis.openbaoIsTcp" -}}
{{- $url := default "" .Values.openbao.url -}}
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

{{- define "genesis.openbaoEsoActive" -}}
{{- if and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.openbao) "") -}}
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

{{- define "genesis.openbaoEsoTarget" -}}
{{- if .Values.openbao.roleId.existingSecret -}}
{{- .Values.openbao.roleId.existingSecret -}}
{{- else if .Values.openbao.secretId.existingSecret -}}
{{- .Values.openbao.secretId.existingSecret -}}
{{- else -}}
{{- printf "%s-openbao" (include "genesis.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "genesis.openbaoRoleIdSecretName" -}}
{{- if .Values.openbao.roleId.existingSecret -}}
{{- .Values.openbao.roleId.existingSecret -}}
{{- else if eq (include "genesis.openbaoEsoActive" .) "true" -}}
{{- include "genesis.openbaoEsoTarget" . -}}
{{- end -}}
{{- end -}}

{{- define "genesis.openbaoSecretIdSecretName" -}}
{{- if .Values.openbao.secretId.existingSecret -}}
{{- .Values.openbao.secretId.existingSecret -}}
{{- else if eq (include "genesis.openbaoEsoActive" .) "true" -}}
{{- include "genesis.openbaoEsoTarget" . -}}
{{- end -}}
{{- end -}}

{{- define "genesis.validateValues" -}}
{{- /* Chart 0.6 dropped HashiCorp Vault; stale keys would otherwise be ignored silently. */ -}}
{{- if hasKey .Values "vault" -}}
{{- fail "genesis: the vault values block was renamed to openbao; HashiCorp Vault is no longer supported" -}}
{{- end -}}
{{- if hasKey .Values "secretsProvider" -}}
{{- fail "genesis: secretsProvider was removed; the chart always uses OpenBao" -}}
{{- end -}}
{{- include "genesis.validateOpenbaoAuth" . -}}
{{- $socketMode := ne (default "" .Values.config.socketPath) "" -}}
{{- if and $socketMode .Values.service.enabled -}}
{{- fail "genesis: service.enabled must be false when config.socketPath is set" -}}
{{- end -}}

{{- $dbEsoActive := eq (include "genesis.dbEsoActive" .) "true" -}}
{{- $openbaoEsoActive := eq (include "genesis.openbaoEsoActive" .) "true" -}}

{{- if not .Values.admissionSigningVersion -}}
{{- fail "Genesis OpenBao requires an explicit admissionSigningVersion published by the core operator" -}}
{{- end -}}
{{- if or (empty .Values.image.digest) (and .Values.openbao.agent.enabled (or (empty .Values.openbao.agent.image.digest) (not (hasSuffix "/openbao" .Values.openbao.agent.image.repository)))) -}}
{{- fail "OpenBao workloads require pinned application and OpenBao Agent images" -}}
{{- end -}}
{{- range $e := .Values.extraEnv -}}
{{- $name := toString $e.name -}}
{{- if or (hasPrefix "PERMESI_OPENBAO_" $name) (hasPrefix "GENESIS_OPENBAO_" $name) (has $name (list "GENESIS_ADMISSION_SIGNING_VERSION" "GENESIS_TRANSIT_MOUNT")) -}}
{{- fail "Use managed values for OpenBao and admission trust" -}}
{{- end -}}
{{- end -}}
{{- $dsnSet := or (ne (default "" .Values.database.dsn.value) "") (ne (default "" .Values.database.dsn.existingSecret) "") $dbEsoActive -}}
{{- if not $dsnSet -}}
{{- fail "genesis: set database.dsn.value, database.dsn.existingSecret, or database.dsn.externalSecret.remoteKey" -}}
{{- end -}}

{{- if eq (default "" .Values.openbao.url) "" -}}
{{- fail "genesis: openbao.url must be set" -}}
{{- end -}}

{{- if and (not $socketMode) (eq (default "" .Values.tls.pemBundlePath) "") -}}
{{- fail "genesis: tls.pemBundlePath must be set when not running in socket mode" -}}
{{- end -}}

{{- if and .Values.autoscaling.enabled (gt (int (default 0 .Values.autoscaling.minReplicas)) (int (default 0 .Values.autoscaling.maxReplicas))) -}}
{{- fail "genesis: autoscaling.minReplicas must not exceed autoscaling.maxReplicas" -}}
{{- end -}}

{{- if .Values.externalSecret.enabled -}}
{{- $esoRemoteSet := or (ne (dig "externalSecret" "remoteKey" "" .Values.database.dsn) "") (ne (dig "externalSecret" "remoteKey" "" .Values.tls) "") (ne (dig "externalSecret" "remoteKey" "" .Values.openbao) "") -}}
{{- if and $esoRemoteSet (eq (default "" .Values.externalSecret.store) "") -}}
{{- fail "genesis: externalSecret.store must be set when any externalSecret.remoteKey is set" -}}
{{- end -}}
{{- end -}}

{{- if $openbaoEsoActive -}}
{{- $rid := default "" .Values.openbao.roleId.existingSecret -}}
{{- $sid := default "" .Values.openbao.secretId.existingSecret -}}
{{- if and (ne $rid "") (ne $sid "") (ne $rid $sid) -}}
{{- fail "genesis: when OpenBao ESO is enabled, openbao.roleId.existingSecret and openbao.secretId.existingSecret must reference the same Secret" -}}
{{- end -}}
{{- end -}}

{{- $secretIdSet := or (ne (default "" .Values.openbao.secretId.value) "") (ne (default "" .Values.openbao.secretId.existingSecret) "") $openbaoEsoActive -}}
{{- $wrappedTokenSet := or (ne (default "" .Values.openbao.wrappedToken.value) "") (ne (default "" .Values.openbao.wrappedToken.existingSecret) "") -}}
{{- if and $secretIdSet $wrappedTokenSet -}}
{{- fail "genesis: openbao.secretId and openbao.wrappedToken are mutually exclusive" -}}
{{- end -}}

{{- $openbaoIsTcp := eq (include "genesis.openbaoIsTcp" .) "true" -}}
{{- $roleSet := or (ne (default "" .Values.openbao.roleId.value) "") (ne (default "" .Values.openbao.roleId.existingSecret) "") $openbaoEsoActive -}}
{{- if and (not .Values.openbao.agent.enabled) (ne .Values.openbao.authMethod "kubernetes") $openbaoIsTcp (not $roleSet) -}}
{{- fail "genesis: openbao.roleId must be set when openbao.url uses http:// or https://" -}}
{{- end -}}
{{- if and (not .Values.openbao.agent.enabled) (ne .Values.openbao.authMethod "kubernetes") $openbaoIsTcp (not (or $secretIdSet $wrappedTokenSet)) -}}
{{- fail "genesis: set openbao.secretId or openbao.wrappedToken when openbao.url uses http:// or https://" -}}
{{- end -}}

{{- if .Values.openbao.agent.enabled -}}
{{- $agent := .Values.openbao.agent -}}
{{- $socketMode := ne (default "" .Values.config.socketPath) "" -}}

{{- /* Kubernetes >= 1.29 (native sidecars). */ -}}
{{- $minor := trimSuffix "+" (toString .Capabilities.KubeVersion.Minor) -}}
{{- if or (not (regexMatch "^[0-9]+$" $minor)) (lt (.Capabilities.KubeVersion.Major | int) 1) (and (eq (.Capabilities.KubeVersion.Major | int) 1) (lt ($minor | int) 29)) -}}
{{- fail "genesis: openbao.agent.enabled requires Kubernetes >= 1.29 (native sidecars)" -}}
{{- end -}}

{{- /* Unix target. */ -}}
{{- $url := default "" .Values.openbao.url -}}
{{- if or (hasPrefix "http://" $url) (hasPrefix "https://" $url) -}}
{{- fail "genesis: openbao.url must be a Unix socket path when openbao.agent.enabled" -}}
{{- end -}}
{{- $urlNoScheme := $url -}}
{{- if hasPrefix "unix://" $url -}}
{{- $urlNoScheme = trimPrefix "unix://" $url -}}
{{- end -}}
{{- if not (hasPrefix "/" $urlNoScheme) -}}
{{- fail "genesis: openbao.url must be an absolute socket path when openbao.agent.enabled" -}}
{{- end -}}

{{- /* OpenBao origin address. */ -}}
{{- if not (or (hasPrefix "http://" (default "" $agent.address)) (hasPrefix "https://" (default "" $agent.address))) -}}
{{- fail "genesis: openbao.agent.address must be an http(s) URL when openbao.agent.enabled" -}}
{{- end -}}

{{- /* Kubernetes auth role. */ -}}
{{- if eq (default "" $agent.auth.role) "" -}}
{{- fail "genesis: openbao.agent.auth.role must be set when openbao.agent.enabled" -}}
{{- end -}}

{{- /* Reject AppRole credentials / wrapped tokens. */ -}}
{{- $approleSet := or (ne (default "" .Values.openbao.roleId.value) "") (ne (default "" .Values.openbao.roleId.existingSecret) "") (ne (default "" .Values.openbao.secretId.value) "") (ne (default "" .Values.openbao.secretId.existingSecret) "") (ne (default "" .Values.openbao.wrappedToken.value) "") (ne (default "" .Values.openbao.wrappedToken.existingSecret) "") -}}
{{- if $approleSet -}}
{{- fail "genesis: openbao.roleId/secretId/wrappedToken must not be set when openbao.agent.enabled" -}}
{{- end -}}

{{- /* Reject OpenBao ESO credentials. */ -}}
{{- if and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.openbao) "") -}}
{{- fail "genesis: openbao.externalSecret.remoteKey must not be set when openbao.agent.enabled" -}}
{{- end -}}

{{- /* TLS managed by the agent in TCP mode. */ -}}
{{- if not $socketMode -}}
{{- if or (ne (default "" .Values.tls.existingSecret) "") (and .Values.externalSecret.enabled (ne (dig "externalSecret" "remoteKey" "" .Values.tls) "")) -}}
{{- fail "genesis: tls Secret/ESO must not be set when openbao.agent.enabled manages TLS" -}}
{{- end -}}
{{- if eq (default "" $agent.pki.role) "" -}}
{{- fail "genesis: openbao.agent.pki.role must be set when openbao.agent.enabled serves TLS" -}}
{{- end -}}
{{- if eq (default "" $agent.pki.commonName) "" -}}
{{- fail "genesis: openbao.agent.pki.commonName must be set when openbao.agent.enabled serves TLS" -}}
{{- end -}}
{{- $dnsOk := false -}}
{{- range $agent.pki.dnsNames -}}
{{- if ne (toString .) "" -}}{{- $dnsOk = true -}}{{- end -}}
{{- end -}}
{{- if not $dnsOk -}}
{{- fail "genesis: openbao.agent.pki.dnsNames must contain at least one SAN when openbao.agent.enabled serves TLS" -}}
{{- end -}}
{{- end -}}

{{- /* Injector annotations. */ -}}
{{- $hasInjector := false -}}
{{- range $k, $v := .Values.podAnnotations -}}
{{- if hasPrefix "vault.hashicorp.com/agent" $k -}}{{- $hasInjector = true -}}{{- end -}}
{{- end -}}
{{- if $hasInjector -}}
{{- fail "genesis: vault.hashicorp.com/agent-* injector annotations must not be used when openbao.agent.enabled" -}}
{{- end -}}

{{- /* Duplicate chart-owned env entries. */ -}}
{{- $dupEnv := false -}}
{{- range $e := .Values.extraEnv -}}
{{- if or (eq (toString $e.name) "GENESIS_OPENBAO_URL") (eq (toString $e.name) "GENESIS_TLS_PEM_BUNDLE") (eq (toString $e.name) "GENESIS_OPENBAO_ROLE_ID") (eq (toString $e.name) "GENESIS_OPENBAO_SECRET_ID") (eq (toString $e.name) "GENESIS_OPENBAO_WRAPPED_TOKEN") -}}{{- $dupEnv = true -}}{{- end -}}
{{- end -}}
{{- if $dupEnv -}}
{{- fail "genesis: extraEnv must not redefine chart-managed OpenBao/TLS env entries when openbao.agent.enabled" -}}
{{- end -}}

{{- /* Reserved mount collisions. */ -}}
{{- $reservedVol := false -}}
{{- range $v := .Values.extraVolumes -}}
{{- if or (eq (toString $v.name) "tls-bundle") (eq (toString $v.name) "openbao-agent-socket") (eq (toString $v.name) "openbao-agent-config") (eq (toString $v.name) "openbao-agent-token") (eq (toString $v.name) "openbao-agent-ca") (eq (toString $v.name) "openbao-agent-scratch") -}}{{- $reservedVol = true -}}{{- end -}}
{{- end -}}
{{- if $reservedVol -}}
{{- fail "genesis: extraVolumes must not use reserved volume names when openbao.agent.enabled" -}}
{{- end -}}
{{- /* The Agent-only projected JWT, config and scratch must never reach the application container. */ -}}
{{- range $m := .Values.extraVolumeMounts -}}
{{- if has (toString $m.name) (list "tls-bundle" "openbao-agent-socket" "openbao-agent-config" "openbao-agent-token" "openbao-agent-ca" "openbao-agent-scratch") -}}
{{- fail "genesis: extraVolumeMounts must not use reserved volume names when openbao.agent.enabled" -}}
{{- end -}}
{{- end -}}

{{- /* Nonroot UID/GID + fsGroup. */ -}}
{{- $ru := int (default 0 .Values.securityContext.runAsUser) -}}
{{- $rg := int (default 0 .Values.securityContext.runAsGroup) -}}
{{- $fsg := int (default 0 .Values.podSecurityContext.fsGroup) -}}
{{- if or (le $ru 0) (le $rg 0) (le $fsg 0) -}}
{{- fail "genesis: securityContext.runAsUser/runAsGroup and podSecurityContext.fsGroup must be positive integers when openbao.agent.enabled" -}}
{{- end -}}

{{- /* automount must be false. */ -}}
{{- if .Values.serviceAccount.automount -}}
{{- fail "genesis: serviceAccount.automount must be false when openbao.agent.enabled" -}}
{{- end -}}

{{- /* renewalThreshold strictly between 0 and 1 (no truthiness default). */ -}}
{{- $rt := float64 $agent.pki.renewalThreshold -}}
{{- if or (le $rt 0.0) (ge $rt 1.0) -}}
{{- fail "genesis: openbao.agent.pki.renewalThreshold must be strictly between 0 and 1" -}}
{{- end -}}

{{- /* Active artifacts only: inbound TLS is mounted when the agent manages it
     (TCP mode) or a legacy TLS Secret is requested. */ -}}
{{- $mountTls := or (not $socketMode) (ne (include "genesis.tlsSecretName" .) "") -}}

{{- /* Absolute writable artifact destinations. */ -}}
{{- if and $mountTls (not (hasPrefix "/" (clean (default "" .Values.tls.pemBundlePath)))) -}}
{{- fail "genesis: tls.pemBundlePath must be an absolute path when openbao.agent.enabled" -}}
{{- end -}}

{{- /* Each managed artifact needs its own mount directory: a file directly in
     / would yield an empty mountPath (or mount over the root filesystem). */ -}}
{{- $socketDir := clean (include "genesis.agentSocketDir" .) -}}
{{- if or (eq $socketDir ".") (eq $socketDir "/") -}}
{{- fail "genesis: openbao.url socket must be inside a dedicated directory, not directly in / when openbao.agent.enabled" -}}
{{- end -}}
{{- if $mountTls -}}
{{- $tlsDir := clean (include "genesis.agentTlsDir" .) -}}
{{- if or (eq $tlsDir ".") (eq $tlsDir "/") -}}
{{- fail "genesis: tls.pemBundlePath must be inside a dedicated directory, not directly in / when openbao.agent.enabled" -}}
{{- end -}}
{{- end -}}

{{- /* Normalized chart-owned mount directories: fixed agent locations, the
     socket and each active artifact. */ -}}
{{- $chartDirs := list "/openbao/config" "/var/run/secrets/openbao-token" "/tmp" $socketDir -}}
{{- if $mountTls -}}
{{- $chartDirs = append $chartDirs (clean (include "genesis.agentTlsDir" .)) -}}
{{- end -}}
{{- if .Values.openbao.agent.ca.existingConfigMap -}}
{{- $chartDirs = append $chartDirs "/openbao/ca" -}}
{{- end -}}
{{- if eq (include "genesis.dirsOverlap" $chartDirs) "true" -}}
{{- fail (printf "genesis: OpenBao Agent destination mount directories must not overlap (got: %s) when openbao.agent.enabled" (join ", " $chartDirs)) -}}
{{- end -}}

{{- /* extraVolumeMounts must not collide with chart-owned mount directories. */ -}}
{{- $extraCollision := false -}}
{{- range $m := .Values.extraVolumeMounts -}}
{{- $mp := clean (toString (default "" $m.mountPath)) -}}
{{- range $d := $chartDirs -}}
{{- if eq (include "genesis.dirsOverlap" (list $mp (toString $d))) "true" -}}
{{- $extraCollision = true -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $extraCollision -}}
{{- fail "genesis: extraVolumeMounts must not overlap chart-managed mount directories when openbao.agent.enabled" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Image reference for an image values block ({repository, tag, digest}).
A non-empty digest pins the image as repository@digest and takes precedence
over the tag; otherwise renders repository:tag.
*/}}
{{- define "genesis.image" -}}
{{- if .digest -}}
{{- printf "%s@%s" .repository .digest -}}
{{- else -}}
{{- printf "%s:%v" .repository .tag -}}
{{- end -}}
{{- end -}}
