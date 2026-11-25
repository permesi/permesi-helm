{{/* vim: set filetype=mustache: */}}
{{/* Managed OpenBao Agent helpers (native sidecar). */}}

{{- define "genesis.agentSocketPath" -}}
{{- $url := .Values.openbao.url -}}
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
{{- printf "%s-openbao-agent" (include "genesis.fullname" .) -}}
{{- end -}}

{{- define "genesis.agentHCL" -}}
pid_file = "/tmp/openbao-agent.pid"

# OpenBao Agent keeps the upstream stanza name for the server connection.
vault {
  address = {{ .Values.openbao.agent.address | quote }}
{{- if .Values.openbao.agent.ca.existingConfigMap }}
  ca_cert = {{ printf "/openbao/ca/%s" .Values.openbao.agent.ca.key | quote }}
{{- end }}
}

auto_auth {
  method "kubernetes" {
    mount_path = {{ printf "auth/%s" .Values.openbao.agent.auth.mount | quote }}
    config = {
      role       = {{ .Values.openbao.agent.auth.role | quote }}
      token_path = "/var/run/secrets/openbao-token/token"
      audience   = {{ .Values.openbao.agent.auth.audience | quote }}
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
  source      = "/openbao/config/tls-bundle.tpl"
  destination = {{ .Values.tls.pemBundlePath | quote }}
  perms       = "0600"
  error_on_missing_key = true
  backup      = false
}
{{- end }}

template_config {
  lease_renewal_threshold = {{ .Values.openbao.agent.pki.renewalThreshold }}
}
{{- end -}}

{{/* TLS bundle Go-template source: one key, leaf first, then the complete
     issuer chain read from the PKI mount's ca_chain (OpenBao Agent's pkiCert
     result does not carry the full chain). */}}
{{- define "genesis.agentTlsTemplate" -}}
{{ "{{- with pkiCert" }} {{ printf "%s/issue/%s" .Values.openbao.agent.pki.mount .Values.openbao.agent.pki.role | quote }} {{ printf "common_name=%s" .Values.openbao.agent.pki.commonName | quote }} {{ printf "alt_names=%s" (join "," .Values.openbao.agent.pki.dnsNames) | quote }} {{ printf "ttl=%s" .Values.openbao.agent.pki.ttl | quote }} {{ "}}" }}
{{ "{{ .Data.Key }}{{ .Data.Cert }}{{ with secret" }} {{ printf "%s/cert/ca_chain" .Values.openbao.agent.pki.mount | quote }} {{ "}}{{ .Data.certificate }}{{ end }}" }}
{{ "{{- end" }} {{ "}}" }}
{{- end -}}

{{- define "genesis.agentConfigChecksum" -}}
{{- $hcl := include "genesis.agentHCL" . -}}
{{- $tls := include "genesis.agentTlsTemplate" . -}}
{{- printf "%s\n%s" $hcl $tls | sha256sum -}}
{{- end -}}

{{- define "genesis.agentProbeCommand" -}}
bao token lookup -address="unix://{{ include "genesis.agentSocketPath" . }}" >/dev/null 2>&1{{ if not (default "" .Values.config.socketPath) }} && test -s {{ .Values.tls.pemBundlePath | quote }}{{ end }}
{{- end -}}
