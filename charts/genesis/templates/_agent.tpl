{{/* vim: set filetype=mustache: */}}
{{/* Managed Vault Agent helpers (native sidecar). */}}

{{- define "genesis.agentSocketPath" -}}
{{- $url := .Values.vault.url -}}
{{- if hasPrefix "unix://" $url -}}
{{- trimPrefix "unix://" $url -}}
{{- else -}}
{{- $url -}}
{{- end -}}
{{- end -}}

{{- define "genesis.agentSocketDir" -}}
{{- include "genesis.pathDir" (include "genesis.agentSocketPath" .) -}}
{{- end -}}

{{- define "genesis.agentTlsDir" -}}
{{- include "genesis.pathDir" .Values.tls.pemBundlePath -}}
{{- end -}}

{{- define "genesis.agentConfigName" -}}
{{- printf "%s-vault-agent" (include "genesis.fullname" .) -}}
{{- end -}}

{{- define "genesis.agentHCL" -}}
pid_file = "/tmp/vault-agent.pid"

vault {
  address = {{ .Values.vault.agent.address | quote }}
{{- if .Values.vault.agent.ca.existingConfigMap }}
  ca_cert = {{ printf "/vault/ca/%s" .Values.vault.agent.ca.key | quote }}
{{- end }}
}

auto_auth {
  method "kubernetes" {
    mount_path = {{ printf "auth/%s" .Values.vault.agent.auth.mount | quote }}
    config = {
      role       = {{ .Values.vault.agent.auth.role | quote }}
      token_path = "/var/run/secrets/vault-token/token"
      audience   = {{ .Values.vault.agent.auth.audience | quote }}
    }
  }
}

listener "unix" {
  address      = {{ include "genesis.agentSocketPath" . | quote }}
  tls_disable  = true
  socket_mode  = "0600"
  socket_user  = {{ .Values.securityContext.runAsUser | quote }}
  socket_group = {{ .Values.securityContext.runAsGroup | quote }}
}

api_proxy {
  use_auto_auth_token = true
}
{{- if ne (default "" .Values.config.socketPath) "" }}

# Application listens on a Unix socket: no inbound TLS bundle is rendered.
{{- else }}

template {
  source      = "/vault/config/tls-bundle.tpl"
  destination = {{ .Values.tls.pemBundlePath | quote }}
  perms       = "0600"
  error_on_missing_key = true
  backup      = false
}
{{- end }}

template_config {
  lease_renewal_threshold = {{ .Values.vault.agent.pki.renewalThreshold }}
}
{{- end -}}

{{- define "genesis.agentTlsTemplate" -}}
{{ "{{- with pkiCert" }} {{ printf "%s/issue/%s" .Values.vault.agent.pki.mount .Values.vault.agent.pki.role | quote }} {{ printf "common_name=%s" .Values.vault.agent.pki.commonName | quote }} {{ printf "alt_names=%s" (join "," .Values.vault.agent.pki.dnsNames) | quote }} {{ printf "ttl=%s" .Values.vault.agent.pki.ttl | quote }} {{ "}}" }}
{{ "{{ .Data.Key }}{{ .Data.Cert }}{{ .Data.CA }}" }}
{{ "{{- end" }} {{ "}}" }}
{{- end -}}

{{- define "genesis.agentConfigChecksum" -}}
{{- $hcl := include "genesis.agentHCL" . -}}
{{- $tls := include "genesis.agentTlsTemplate" . -}}
{{- printf "%s\n%s" $hcl $tls | sha256sum -}}
{{- end -}}

{{- define "genesis.agentProbeCommand" -}}
vault token lookup -address="unix://{{ include "genesis.agentSocketPath" . }}" >/dev/null 2>&1{{ if not (default "" .Values.config.socketPath) }} && test -s {{ .Values.tls.pemBundlePath | quote }}{{ end }}
{{- end -}}
