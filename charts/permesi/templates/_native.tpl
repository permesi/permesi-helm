{{/* Explicit application Vault authentication; independent of Agent PKI. */}}
{{- define "permesi.validateVaultAuth" -}}
{{- $method := .Values.vault.authMethod -}}
{{- $native := eq $method "kubernetes" -}}
{{- if and .Values.vault.agent.enabled (ne $method "auto") -}}
{{- fail "permesi: vault.agent.enabled requires vault.authMethod=auto" -}}
{{- end -}}
{{- if and (eq $method "approle") (ne (include "permesi.vaultIsTcp" .) "true") -}}
{{- fail "permesi: vault.authMethod=approle requires a TCP Vault URL" -}}
{{- end -}}
{{- if or (ne $method "auto") .Values.vault.agent.enabled -}}
{{- $reservedEnv := list "PERMESI_VAULT_AUTH_METHOD" "PERMESI_VAULT_KUBERNETES_AUTH_MOUNT" "PERMESI_VAULT_KUBERNETES_ROLE" "PERMESI_VAULT_KUBERNETES_TOKEN_PATH" -}}
{{- if $native -}}
{{- $reservedEnv = concat $reservedEnv (list "PERMESI_VAULT_URL" "PERMESI_VAULT_ROLE_ID" "PERMESI_VAULT_SECRET_ID" "PERMESI_VAULT_WRAPPED_TOKEN") -}}
{{- end -}}
{{- range .Values.extraEnv -}}
{{- if has .name $reservedEnv -}}
{{- fail "permesi: extraEnv must not override chart-managed Vault authentication or credentials" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $native -}}
{{- $auth := .Values.vault.kubernetes -}}
{{- if not (regexMatch "^https?://[^/?#@[:space:]]+/?$" .Values.vault.url) -}}
{{- fail "permesi: vault.authMethod=kubernetes requires a TCP Vault URL origin without credentials, path, query or fragment" -}}
{{- end -}}
{{- $origin := urlParse .Values.vault.url -}}
{{- if or (eq $origin.host "") (hasPrefix ":" $origin.host) -}}
{{- fail "permesi: vault.authMethod=kubernetes requires a TCP Vault URL origin with a hostname" -}}
{{- end -}}
{{- if eq (trim $auth.role) "" -}}
{{- fail "permesi: vault.kubernetes.role must be set when vault.authMethod=kubernetes" -}}
{{- end -}}
{{- if .Values.serviceAccount.automount -}}
{{- fail "permesi: serviceAccount.automount must be false when vault.authMethod=kubernetes" -}}
{{- end -}}
{{- range $name := list "roleId" "secretId" "wrappedToken" -}}
{{- $credential := index $.Values.vault $name -}}
{{- if or $credential.value $credential.existingSecret -}}
{{- fail "permesi: vault.roleId/secretId/wrappedToken must not be set when vault.authMethod=kubernetes" -}}
{{- end -}}
{{- end -}}
{{- if ne (dig "externalSecret" "remoteKey" "" .Values.vault) "" -}}
{{- fail "permesi: vault.externalSecret.remoteKey must not be set when vault.authMethod=kubernetes" -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$" $auth.authMount) -}}
{{- fail "permesi: vault.kubernetes.authMount must be a relative Vault auth mount without empty or traversal segments" -}}
{{- end -}}
{{- if eq (trim $auth.audience) "" -}}
{{- fail "permesi: vault.kubernetes.audience must not be empty" -}}
{{- end -}}
{{- $path := $auth.tokenPath -}}
{{- $tokenDir := clean (include "permesi.pathDir" $path) -}}
{{- if or (not (hasPrefix "/" $path)) (ne $path (clean $path)) (eq $tokenDir ".") (eq $tokenDir "/") -}}
{{- fail "permesi: vault.kubernetes.tokenPath must be a normalized absolute file path inside a dedicated directory, not directly in /" -}}
{{- end -}}
{{- $managedDirs := list $tokenDir -}}
{{- $applicationDirs := list -}}
{{- $mountTls := ne (include "permesi.tlsSecretName" .) "" -}}
{{- $tlsDir := clean (include "permesi.pathDir" .Values.tls.pemBundlePath) -}}
{{- if or (not .Values.config.socketPath) $mountTls -}}
{{- $applicationDirs = append $applicationDirs $tlsDir -}}
{{- end -}}
{{- if $mountTls -}}
{{- $managedDirs = append $managedDirs $tlsDir -}}
{{- end -}}
{{- if .Values.config.socketPath -}}
{{- $applicationDirs = append $applicationDirs (clean (include "permesi.pathDir" .Values.config.socketPath)) -}}
{{- end -}}
{{- if ne (include "permesi.admissionCaSecretName" .) "" -}}
{{- $caDir := clean .Values.admission.paserkCa.mountPath -}}
{{- $applicationDirs = append $applicationDirs $caDir -}}
{{- $managedDirs = append $managedDirs $caDir -}}
{{- else if .Values.admission.paserkCaPath -}}
{{- $applicationDirs = append $applicationDirs (clean (include "permesi.pathDir" .Values.admission.paserkCaPath)) -}}
{{- end -}}
{{- range $dir := $applicationDirs -}}
{{- if eq (include "permesi.dirsOverlap" (list $tokenDir $dir)) "true" -}}
{{- fail "permesi: native Vault token and application mount directories must not overlap" -}}
{{- end -}}
{{- end -}}
{{- $reservedVolumes := list "vault-native-token" "tls-bundle" "admission-paserk-ca" "vault-agent-socket" "vault-agent-config" "vault-agent-token" "vault-agent-ca" "vault-agent-scratch" -}}
{{- range .Values.extraVolumes -}}
{{- if has .name $reservedVolumes -}}
{{- fail "permesi: extraVolumes must not use reserved volume names when vault.authMethod=kubernetes" -}}
{{- end -}}
{{- end -}}
{{- range .Values.extraVolumeMounts -}}
{{- if has .name $reservedVolumes -}}
{{- fail "permesi: extraVolumeMounts must not use reserved volume names when vault.authMethod=kubernetes" -}}
{{- end -}}
{{- $mountDir := clean (toString .mountPath) -}}
{{- range $dir := $managedDirs -}}
{{- if eq (include "permesi.dirsOverlap" (list $mountDir $dir)) "true" -}}
{{- fail "permesi: extraVolumeMounts must not overlap native Vault token or application mount directories" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
