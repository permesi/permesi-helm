{{/* Parent-only checks: never mutate sibling values or rely on render order. */}}
{{- define "permesi-stack.validateQuickstart" -}}
{{- if .Values.quickstart.enabled -}}
{{- $q := .Values.quickstart -}}
{{- if not $q.acknowledgeDevelopment -}}
{{- fail "permesi-stack: quickstart.acknowledgeDevelopment must be true (DEVELOPMENT ONLY)" -}}
{{- end -}}
{{- range $name := list "permesi" "genesis" "web" -}}
{{- if not (index $.Values $name).enabled -}}
{{- fail "permesi-stack: quickstart requires permesi, genesis and web enabled; partial stacks are unsupported" -}}
{{- end -}}
{{- end -}}
{{- $qc := dict "Values" $q "Chart" (dict "Name" "quickstart") "Release" .Release -}}
{{- $vaultAddress := include "quickstart.vaultAddr" $qc -}}
{{- $pgHost := printf "%s.%s.svc" (include "quickstart.postgresqlServiceName" $qc) .Release.Namespace -}}
{{- range $name := list "permesi" "genesis" -}}
{{- $v := index $.Values $name -}}
{{- $ctx := dict "Values" $v "Chart" (dict "Name" $name) "Release" $.Release -}}
{{- $fullname := include (printf "%s.fullname" $name) $ctx -}}
{{- $sa := include (printf "%s.serviceAccountName" $name) $ctx -}}
{{- $bootSvc := index $q.bootstrap.services $name -}}
{{- $bootName := include "quickstart.applicationName" (dict "root" $qc "service" $name) -}}
{{- $bootSA := (index $q.bootstrap.kubernetesRoles $name).serviceAccount | default $bootName -}}
{{- if or (ne $bootName $fullname) (ne $bootSA $sa) -}}
{{- fail (printf "permesi-stack: quickstart %s bootstrap serviceName/serviceAccount must match actual component names" $name) -}}
{{- end -}}
{{- if or (not $v.service.enabled) (ne $v.config.socketPath "") (ne $v.service.type "ClusterIP") $v.ingress.enabled -}}
{{- fail (printf "permesi-stack: quickstart %s requires an internal ClusterIP HTTPS Service, no ingress or application socket mode" $name) -}}
{{- end -}}
{{- if or (not $v.vault.agent.enabled) $v.serviceAccount.automount (ne $v.vault.authMethod "auto") -}}
{{- fail (printf "permesi-stack: quickstart %s requires Vault Agent mode and serviceAccount.automount=false" $name) -}}
{{- end -}}
{{- $a := $v.vault.agent -}}
{{- if or (ne $a.address $vaultAddress) (ne $a.auth.mount "kubernetes") (ne $a.auth.role $name) (ne $a.auth.audience $q.bootstrap.kubernetesRoles.audience) -}}
{{- fail (printf "permesi-stack: quickstart %s Agent address/auth must match bootstrap Vault, role, mount and audience" $name) -}}
{{- end -}}
{{- if or (ne $a.pki.mount "pki-int") (ne $a.pki.role (printf "%s-runtime" $name)) -}}
{{- fail (printf "permesi-stack: quickstart %s Agent PKI mount/role must match bootstrap" $name) -}}
{{- end -}}
{{- $dns := list $fullname (printf "%s.%s" $fullname $.Release.Namespace) (printf "%s.%s.svc" $fullname $.Release.Namespace) (printf "%s.%s.svc.cluster.local" $fullname $.Release.Namespace) -}}
{{- $allowed := concat $dns ($bootSvc.browserDnsNames | default list) -}}
{{- if not (has $a.pki.commonName $allowed) -}}
{{- fail (printf "permesi-stack: quickstart %s PKI commonName is outside bootstrap exact DNS names" $name) -}}
{{- end -}}
{{- range $san := $a.pki.dnsNames -}}
{{- if not (has $san $allowed) -}}
{{- fail (printf "permesi-stack: quickstart %s PKI SAN is outside bootstrap exact DNS names" $name) -}}
{{- end -}}
{{- end -}}
{{- $browser := ternary "api.localhost" "genesis.localhost" (eq $name "permesi") -}}
{{- range $required := list (last $dns) $browser -}}
{{- if not (and (has $required $allowed) (has $required $a.pki.dnsNames)) -}}
{{- fail (printf "permesi-stack: quickstart %s PKI SANs must include Service FQDN and browser hostname" $name) -}}
{{- end -}}
{{- end -}}
{{- $dsn := printf "postgres://placeholder@%s:%v/%s?sslmode=disable" $pgHost $q.postgresql.service.port $name -}}
{{- if or (ne $v.database.dsn.value $dsn) $v.database.dsn.existingSecret $v.database.dsn.externalSecret.remoteKey -}}
{{- fail (printf "permesi-stack: quickstart %s DSN must use bootstrap PostgreSQL/database with placeholder user, no credential Secret" $name) -}}
{{- end -}}
{{- if ne $v.vault.transitMount (printf "transit/%s" $name) -}}
{{- fail (printf "permesi-stack: quickstart %s transitMount must match bootstrap policy" $name) -}}
{{- end -}}
{{- if $v.extraEnvFrom -}}
{{- fail (printf "permesi-stack: quickstart %s extraEnvFrom can override bootstrap wiring; use explicit extraEnv" $name) -}}
{{- end -}}
{{- $env := dict -}}
{{- $prefix := upper $name -}}
{{- range $e := $v.extraEnv -}}
{{- if hasKey $env $e.name -}}{{- fail (printf "permesi-stack: quickstart %s duplicate extraEnv name" $name) -}}{{- end -}}
{{- $_ := set $env $e.name ($e.value | default "") -}}
{{- if has $e.name (list (printf "%s_DSN" $prefix) (printf "%s_PORT" $prefix) (printf "%s_SOCKET_PATH" $prefix) (printf "%s_VAULT_AUTH_METHOD" $prefix) (printf "%s_TRANSIT_MOUNT" $prefix) "PERMESI_ADMISSION_PASERK_URL" "PERMESI_ADMISSION_ISS" "PERMESI_ADMISSION_AUD" "PERMESI_FRONTEND_BASE_URL" "PERMESI_CORS_ALLOWED_ORIGINS" "PERMESI_OPAQUE_SERVER_ID" "PERMESI_VAULT_KV_MOUNT" "PERMESI_VAULT_KV_PATH" "PERMESI_VAULT_TRANSIT_MOUNT") -}}
{{- fail (printf "permesi-stack: quickstart %s extraEnv must not override component wiring" $name) -}}
{{- end -}}
{{- end -}}
{{- if eq $name "genesis" -}}
{{- if or (ne (get $env "GENESIS_ADMISSION_ISS") $.Values.permesi.admission.issuer) (ne (get $env "GENESIS_ADMISSION_AUD") $.Values.permesi.admission.audience) -}}
{{- fail "permesi-stack: quickstart Genesis issuer/audience must match Permesi admission" -}}
{{- end -}}
{{- else -}}
{{- range $key, $expected := dict "PERMESI_EMAIL_DELIVERY" "outbox" "PERMESI_SIGNUP_MODE" "restricted" "PERMESI_SIGNUP_ALLOWED_DOMAINS" "example.test" "PERMESI_SIGNUP_DEVELOPMENT_DOMAINS" "example.test" -}}
{{- if ne (get $env $key) $expected -}}
{{- fail "permesi-stack: quickstart requires outbox-only delivery and restricted example.test development signup" -}}
{{- end -}}
{{- end -}}
{{- if or (ne $v.vault.kvMount "secret/permesi") (ne $v.vault.kvPath "config") -}}
{{- fail "permesi-stack: quickstart Permesi KV mount/path must match bootstrap" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $gctx := dict "Values" .Values.genesis "Chart" (dict "Name" "genesis") "Release" .Release -}}
{{- $paserk := printf "https://%s.%s.svc.cluster.local:%v/paserk.json" (include "genesis.fullname" $gctx) .Release.Namespace .Values.genesis.service.port -}}
{{- $p := .Values.permesi -}}
{{- if or (ne $p.admission.paserkUrl $paserk) (not $p.vault.agent.paserkCa.enabled) (ne $p.vault.agent.paserkCa.path "pki-int/cert/ca_chain") -}}
{{- fail "permesi-stack: quickstart requires Genesis Service HTTPS PASERK URL and bootstrap CA chain" -}}
{{- end -}}
{{- $w := .Values.web -}}
{{- if or $w.ingress.enabled (ne $w.service.type "ClusterIP") $w.runtimeConfig.existingConfigMap $w.extraEnvFrom -}}
{{- fail "permesi-stack: quickstart web requires managed runtimeConfig and internal ClusterIP, no ingress" -}}
{{- end -}}
{{- if or (ne $w.runtimeConfig.apiBaseUrl "https://api.localhost:8443") (ne $w.runtimeConfig.tokenBaseUrl "https://genesis.localhost:9443") (ne $w.runtimeConfig.clientId "00000000-0000-0000-0000-000000000000") (ne $w.runtimeConfig.opaqueServerId "api.localhost") (ne $p.auth.frontendBaseUrl "http://localhost:8080") (ne $p.auth.corsAllowedOrigins "http://localhost:8080") (ne $p.auth.opaqueServerId $w.runtimeConfig.opaqueServerId) (ne $p.admission.issuer $w.runtimeConfig.tokenBaseUrl) (eq $p.admission.audience "") -}}
{{- fail "permesi-stack: quickstart frontend/admission settings must match the seeded development client and localhost profile" -}}
{{- end -}}
{{- end -}}
{{- end -}}
