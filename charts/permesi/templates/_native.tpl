{{/* Explicit application OpenBao authentication; independent of Agent PKI. */}}
{{- define "permesi.validateOpenbaoAuth" -}}
{{- $method := .Values.openbao.authMethod -}}
{{- $native := eq $method "kubernetes" -}}
{{- if and .Values.openbao.agent.enabled (ne $method "auto") -}}
{{- fail "permesi: openbao.agent.enabled requires openbao.authMethod=auto" -}}
{{- end -}}
{{- if and (eq $method "approle") (ne (include "permesi.openbaoIsTcp" .) "true") -}}
{{- fail "permesi: openbao.authMethod=approle requires a TCP OpenBao URL" -}}
{{- end -}}
{{- if or (ne $method "auto") .Values.openbao.agent.enabled -}}
{{- $reservedEnv := list "PERMESI_OPENBAO_AUTH_METHOD" "PERMESI_OPENBAO_KUBERNETES_AUTH_MOUNT" "PERMESI_OPENBAO_KUBERNETES_ROLE" "PERMESI_OPENBAO_KUBERNETES_TOKEN_PATH" -}}
{{- if ne $method "auto" -}}
{{- $reservedEnv = append $reservedEnv "PERMESI_OPENBAO_URL" -}}
{{- end -}}
{{- if $native -}}
{{- $reservedEnv = concat $reservedEnv (list "PERMESI_OPENBAO_ROLE_ID" "PERMESI_OPENBAO_SECRET_ID" "PERMESI_OPENBAO_WRAPPED_TOKEN") -}}
{{- end -}}
{{- range .Values.extraEnv -}}
{{- if has .name $reservedEnv -}}
{{- fail "permesi: extraEnv must not override chart-managed OpenBao authentication or credentials" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $native -}}
{{- $auth := .Values.openbao.kubernetes -}}
{{- if not (regexMatch "^https?://[^/?#@[:space:]]+/?$" .Values.openbao.url) -}}
{{- fail "permesi: openbao.authMethod=kubernetes requires a TCP OpenBao URL origin without credentials, path, query or fragment" -}}
{{- end -}}
{{- $origin := urlParse .Values.openbao.url -}}
{{- if or (eq $origin.host "") (hasPrefix ":" $origin.host) -}}
{{- fail "permesi: openbao.authMethod=kubernetes requires a TCP OpenBao URL origin with a hostname" -}}
{{- end -}}
{{- $port := trimPrefix ":" (regexFind ":[0-9]+$" $origin.host) -}}
{{- if and (ne $port "") (gt (float64 $port) 65535.0) -}}
{{- fail "permesi: TCP OpenBao URL origin port must be within 0-65535" -}}
{{- end -}}
{{- if eq (trim $auth.role) "" -}}
{{- fail "permesi: openbao.kubernetes.role must be set when openbao.authMethod=kubernetes" -}}
{{- end -}}
{{- if .Values.serviceAccount.automount -}}
{{- fail "permesi: serviceAccount.automount must be false when openbao.authMethod=kubernetes" -}}
{{- end -}}
{{- range $name := list "roleId" "secretId" "wrappedToken" -}}
{{- $credential := index $.Values.openbao $name -}}
{{- if or $credential.value $credential.existingSecret -}}
{{- fail "permesi: openbao.roleId/secretId/wrappedToken must not be set when openbao.authMethod=kubernetes" -}}
{{- end -}}
{{- end -}}
{{- if ne (dig "externalSecret" "remoteKey" "" .Values.openbao) "" -}}
{{- fail "permesi: openbao.externalSecret.remoteKey must not be set when openbao.authMethod=kubernetes" -}}
{{- end -}}
{{- if or (hasPrefix "auth/" $auth.authMount) (hasPrefix "v1/auth/" $auth.authMount) (not (regexMatch "^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$" $auth.authMount)) -}}
{{- fail "permesi: openbao.kubernetes.authMount must be a relative OpenBao auth mount without API prefixes, empty or traversal segments" -}}
{{- end -}}
{{- if eq (trim $auth.audience) "" -}}
{{- fail "permesi: openbao.kubernetes.audience must not be empty" -}}
{{- end -}}
{{- $path := $auth.tokenPath -}}
{{- $tokenDir := clean (include "permesi.pathDir" $path) -}}
{{- if or (not (hasPrefix "/" $path)) (ne $path (clean $path)) (eq $tokenDir ".") (eq $tokenDir "/") -}}
{{- fail "permesi: openbao.kubernetes.tokenPath must be a normalized absolute file path inside a dedicated directory, not directly in /" -}}
{{- end -}}
{{- if hasPrefix ".." (base $path) -}}
{{- fail "permesi: openbao.kubernetes.tokenPath filename must not start with '..'" -}}
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
{{- range $dir := $applicationDirs -}}
{{- if eq (include "permesi.dirsOverlap" (list $tokenDir $dir)) "true" -}}
{{- fail "permesi: native OpenBao token and application mount directories must not overlap" -}}
{{- end -}}
{{- end -}}
{{- $reservedVolumes := list "openbao-native-token" "tls-bundle" "openbao-agent-socket" "openbao-agent-config" "openbao-agent-token" "openbao-agent-ca" "openbao-agent-scratch" -}}
{{- range .Values.extraVolumes -}}
{{- if has .name $reservedVolumes -}}
{{- fail "permesi: extraVolumes must not use reserved volume names when openbao.authMethod=kubernetes" -}}
{{- end -}}
{{- end -}}
{{- range .Values.extraVolumeMounts -}}
{{- if has .name $reservedVolumes -}}
{{- fail "permesi: extraVolumeMounts must not use reserved volume names when openbao.authMethod=kubernetes" -}}
{{- end -}}
{{- if not (hasPrefix "/" (toString .mountPath)) -}}
{{- fail "permesi: extraVolumeMounts mountPath must be absolute when openbao.authMethod=kubernetes" -}}
{{- end -}}
{{- $mountDir := clean (toString .mountPath) -}}
{{- range $dir := $managedDirs -}}
{{- if eq (include "permesi.dirsOverlap" (list $mountDir $dir)) "true" -}}
{{- fail "permesi: extraVolumeMounts must not overlap native OpenBao token or application mount directories" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
