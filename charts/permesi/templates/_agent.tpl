{{/* vim: set filetype=mustache: */}}
{{/* Managed Vault Agent helpers (native sidecar). */}}

{{- define "permesi.agentSocketPath" -}}
{{- $url := .Values.vault.url -}}
{{- if hasPrefix "unix://" $url -}}
{{- trimPrefix "unix://" $url -}}
{{- else -}}
{{- $url -}}
{{- end -}}
{{- end -}}

{{- define "permesi.agentSocketDir" -}}
{{- include "permesi.pathDir" (include "permesi.agentSocketPath" .) -}}
{{- end -}}

{{- define "permesi.agentTlsDir" -}}
{{- include "permesi.pathDir" .Values.tls.pemBundlePath -}}
{{- end -}}

{{/* Admission PASERK CA destination: explicit paserkCaPath wins, otherwise the
     existing mountPath/fileName pair. */}}
{{- define "permesi.agentAdmissionCaPath" -}}
{{- $p := default "" .Values.admission.paserkCaPath -}}
{{- if ne $p "" -}}
{{- $p -}}
{{- else -}}
{{- printf "%s/%s" .Values.admission.paserkCa.mountPath .Values.admission.paserkCa.fileName -}}
{{- end -}}
{{- end -}}

{{- define "permesi.agentAdmissionCaDir" -}}
{{- include "permesi.pathDir" (include "permesi.agentAdmissionCaPath" .) -}}
{{- end -}}

{{- define "permesi.agentConfigName" -}}
{{- printf "%s-vault-agent" (include "permesi.fullname" .) -}}
{{- end -}}

{{/* The agent HCL. Contains no Go-template syntax: the template files live in
     separate ConfigMap keys and are referenced via `source`. */}}
{{- define "permesi.agentHCL" -}}
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
  address      = {{ include "permesi.agentSocketPath" . | quote }}
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
{{- if .Values.vault.agent.paserkCa.enabled }}

template {
  source      = "/vault/config/paserk-ca.tpl"
  destination = {{ include "permesi.agentAdmissionCaPath" . | quote }}
  perms       = "0644"
  error_on_missing_key = true
  backup      = false
}
{{- end }}

template_config {
  lease_renewal_threshold = {{ .Values.vault.agent.pki.renewalThreshold }}
}
{{- end -}}

{{/* TLS bundle Go-template source: one key, leaf first, then the complete
     issuer chain (consul-template v0.41.1 pkiCert exposes .Data.CAChain, the
     ordered deduplicated list of CA certificates; .Data.CA is only the first). */}}
{{- define "permesi.agentTlsTemplate" -}}
{{ "{{- with pkiCert" }} {{ printf "%s/issue/%s" .Values.vault.agent.pki.mount .Values.vault.agent.pki.role | quote }} {{ printf "common_name=%s" .Values.vault.agent.pki.commonName | quote }} {{ printf "alt_names=%s" (join "," .Values.vault.agent.pki.dnsNames) | quote }} {{ printf "ttl=%s" .Values.vault.agent.pki.ttl | quote }} {{ "}}" }}
{{ "{{ .Data.Key }}{{ .Data.Cert }}{{ range .Data.CAChain }}{{ . }}{{ end }}" }}
{{ "{{- end" }} {{ "}}" }}
{{- end -}}

{{/* Permesi PASERK CA Go-template source (authenticated JSON endpoint). */}}
{{- define "permesi.agentCaTemplate" -}}
{{ "{{- with secret" }} {{ .Values.vault.agent.paserkCa.path | quote }} {{ "}}" }}{{ "{{ .Data.certificate }}" }}{{ "{{- end" }} {{ "}}" }}
{{- end -}}

{{- define "permesi.agentConfigChecksum" -}}
{{- $hcl := include "permesi.agentHCL" . -}}
{{- $tls := include "permesi.agentTlsTemplate" . -}}
{{- $ca := include "permesi.agentCaTemplate" . -}}
{{- printf "%s\n%s\n%s" $hcl $tls $ca | sha256sum -}}
{{- end -}}

{{- define "permesi.agentProbeCommand" -}}
vault token lookup -address="unix://{{ include "permesi.agentSocketPath" . }}" >/dev/null 2>&1{{ if not (default "" .Values.config.socketPath) }} && test -s {{ .Values.tls.pemBundlePath | quote }}{{ end }}{{ if .Values.vault.agent.paserkCa.enabled }} && test -s {{ include "permesi.agentAdmissionCaPath" . | quote }}{{ end }}
{{- end -}}
