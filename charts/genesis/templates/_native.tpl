{{/* Explicit application Vault authentication; independent of Agent PKI. */}}
{{- define "genesis.validateVaultAuth" -}}
{{- $method := .Values.vault.authMethod -}}
{{- $native := eq $method "kubernetes" -}}
{{- if and .Values.vault.agent.enabled (ne $method "auto") -}}
{{- fail "genesis: vault.agent.enabled requires vault.authMethod=auto" -}}
{{- end -}}
{{- if and (eq $method "approle") (ne (include "genesis.vaultIsTcp" .) "true") -}}
{{- fail "genesis: vault.authMethod=approle requires a TCP Vault URL" -}}
{{- end -}}
{{- if or (ne $method "auto") .Values.vault.agent.enabled -}}
{{- $reservedEnv := list "GENESIS_VAULT_AUTH_METHOD" "GENESIS_VAULT_KUBERNETES_AUTH_MOUNT" "GENESIS_VAULT_KUBERNETES_ROLE" "GENESIS_VAULT_KUBERNETES_TOKEN_PATH" -}}
{{- if ne $method "auto" -}}
{{- $reservedEnv = append $reservedEnv "GENESIS_VAULT_URL" -}}
{{- end -}}
{{- if $native -}}
{{- $reservedEnv = concat $reservedEnv (list "GENESIS_VAULT_ROLE_ID" "GENESIS_VAULT_SECRET_ID" "GENESIS_VAULT_WRAPPED_TOKEN") -}}
{{- end -}}
{{- range .Values.extraEnv -}}
{{- if has .name $reservedEnv -}}
{{- fail "genesis: extraEnv must not override chart-managed Vault authentication or credentials" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $native -}}
{{- $auth := .Values.vault.kubernetes -}}
{{- if not (regexMatch "^https?://[^/?#@[:space:]]+/?$" .Values.vault.url) -}}
{{- fail "genesis: vault.authMethod=kubernetes requires a TCP Vault URL origin without credentials, path, query or fragment" -}}
{{- end -}}
{{- $origin := urlParse .Values.vault.url -}}
{{- if or (eq $origin.host "") (hasPrefix ":" $origin.host) -}}
{{- fail "genesis: vault.authMethod=kubernetes requires a TCP Vault URL origin with a hostname" -}}
{{- end -}}
{{- $port := trimPrefix ":" (regexFind ":[0-9]+$" $origin.host) -}}
{{- if and (ne $port "") (gt (float64 $port) 65535.0) -}}
{{- fail "genesis: TCP Vault URL origin port must be within 0-65535" -}}
{{- end -}}
{{- if eq (trim $auth.role) "" -}}
{{- fail "genesis: vault.kubernetes.role must be set when vault.authMethod=kubernetes" -}}
{{- end -}}
{{- if .Values.serviceAccount.automount -}}
{{- fail "genesis: serviceAccount.automount must be false when vault.authMethod=kubernetes" -}}
{{- end -}}
{{- range $name := list "roleId" "secretId" "wrappedToken" -}}
{{- $credential := index $.Values.vault $name -}}
{{- if or $credential.value $credential.existingSecret -}}
{{- fail "genesis: vault.roleId/secretId/wrappedToken must not be set when vault.authMethod=kubernetes" -}}
{{- end -}}
{{- end -}}
{{- if ne (dig "externalSecret" "remoteKey" "" .Values.vault) "" -}}
{{- fail "genesis: vault.externalSecret.remoteKey must not be set when vault.authMethod=kubernetes" -}}
{{- end -}}
{{- if or (hasPrefix "auth/" $auth.authMount) (hasPrefix "v1/auth/" $auth.authMount) (not (regexMatch "^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$" $auth.authMount)) -}}
{{- fail "genesis: vault.kubernetes.authMount must be a relative Vault auth mount without API prefixes, empty or traversal segments" -}}
{{- end -}}
{{- if eq (trim $auth.audience) "" -}}
{{- fail "genesis: vault.kubernetes.audience must not be empty" -}}
{{- end -}}
{{- $path := $auth.tokenPath -}}
{{- $tokenDir := clean (include "genesis.pathDir" $path) -}}
{{- if or (not (hasPrefix "/" $path)) (ne $path (clean $path)) (eq $tokenDir ".") (eq $tokenDir "/") -}}
{{- fail "genesis: vault.kubernetes.tokenPath must be a normalized absolute file path inside a dedicated directory, not directly in /" -}}
{{- end -}}
{{- if hasPrefix ".." (base $path) -}}
{{- fail "genesis: vault.kubernetes.tokenPath filename must not start with '..'" -}}
{{- end -}}
{{- $managedDirs := list $tokenDir -}}
{{- $applicationDirs := list -}}
{{- $mountTls := ne (include "genesis.tlsSecretName" .) "" -}}
{{- $tlsDir := clean (include "genesis.pathDir" .Values.tls.pemBundlePath) -}}
{{- if or (not .Values.config.socketPath) $mountTls -}}
{{- $applicationDirs = append $applicationDirs $tlsDir -}}
{{- end -}}
{{- if $mountTls -}}
{{- $managedDirs = append $managedDirs $tlsDir -}}
{{- end -}}
{{- if .Values.config.socketPath -}}
{{- $applicationDirs = append $applicationDirs (clean (include "genesis.pathDir" .Values.config.socketPath)) -}}
{{- end -}}
{{- range $dir := $applicationDirs -}}
{{- if eq (include "genesis.dirsOverlap" (list $tokenDir $dir)) "true" -}}
{{- fail "genesis: native Vault token and application mount directories must not overlap" -}}
{{- end -}}
{{- end -}}
{{- $reservedVolumes := list "vault-native-token" "tls-bundle" "vault-agent-socket" "vault-agent-config" "vault-agent-token" "vault-agent-ca" "vault-agent-scratch" -}}
{{- range .Values.extraVolumes -}}
{{- if has .name $reservedVolumes -}}
{{- fail "genesis: extraVolumes must not use reserved volume names when vault.authMethod=kubernetes" -}}
{{- end -}}
{{- end -}}
{{- range .Values.extraVolumeMounts -}}
{{- if has .name $reservedVolumes -}}
{{- fail "genesis: extraVolumeMounts must not use reserved volume names when vault.authMethod=kubernetes" -}}
{{- end -}}
{{- if not (hasPrefix "/" (toString .mountPath)) -}}
{{- fail "genesis: extraVolumeMounts mountPath must be absolute when vault.authMethod=kubernetes" -}}
{{- end -}}
{{- $mountDir := clean (toString .mountPath) -}}
{{- range $dir := $managedDirs -}}
{{- if eq (include "genesis.dirsOverlap" (list $mountDir $dir)) "true" -}}
{{- fail "genesis: extraVolumeMounts must not overlap native Vault token or application mount directories" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
