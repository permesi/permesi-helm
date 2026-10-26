#!/usr/bin/env bash
# Permesi quickstart verifier (DEVELOPMENT ONLY).
#
# Exercises the real dependencies installed by install.sh: PostgreSQL schema,
# ownership and grants; Vault mounts, key types, PKI issuance limits; and
# split-trust denials using tokens from the actual Kubernetes auth roles (or,
# before the application ServiceAccounts exist, tokens carrying exactly the
# roles' policies). Never prints Secret data, tokens or private keys.
set -euo pipefail

CONTEXT=""
NAMESPACE="permesi-quickstart"
RELEASE="permesi"
DEPS_ONLY=false
RUNTIME_ARGS=()

usage() {
  cat <<'EOF'
Usage: bash scripts/quickstart/verify.sh --context <kube-context> \
         [--namespace <ns>] [--release <name>] [--deps-only]
         [--exercise-lifecycle] [--rotation-timeout SECONDS]
Full mode requires python3, curl and Cargo (or QS_ADMISSION_BIN).
Lifecycle mode restarts/scales backend pods and verifies leaf rotation.
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="${2:?}"; shift 2 ;;
    --namespace) NAMESPACE="${2:?}"; shift 2 ;;
    --release) RELEASE="${2:?}"; shift 2 ;;
    --deps-only) DEPS_ONLY=true; shift ;;
    --exercise-lifecycle) RUNTIME_ARGS+=(--exercise-lifecycle); shift ;;
    --rotation-timeout) RUNTIME_ARGS+=(--rotation-timeout "${2:?}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo "verify.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "${CONTEXT}" ]] || { usage >&2; echo "verify.sh: --context is required" >&2; exit 2; }

K=(kubectl --context "${CONTEXT}" -n "${NAMESPACE}")
fullname() { if [[ "$1" == *"$2"* ]]; then echo "$1"; else echo "$1-$2"; fi; }
QS_RELEASE="${RELEASE}-quickstart"
QS_FULLNAME="${QS_RELEASE}"
PERMESI_NAME="$(fullname "${RELEASE}" permesi)"
GENESIS_NAME="$(fullname "${RELEASE}-genesis" genesis)"
VAULT_DEPLOY="${QS_FULLNAME}-vault"
PG_POD="${QS_FULLNAME}-postgresql-0"

FAILURES=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "${desc}"; else fail "${desc}"; fi; }
section() { echo; echo "== $* =="; }

# Root-token Vault CLI inside the dev Vault pod (token comes from the pod env).
vroot() { "${K[@]}" exec "deploy/${VAULT_DEPLOY}" -c vault -- vault "$@"; }
# Vault CLI with a caller-supplied token passed on stdin (never in argv).
vas() { local token="$1"; shift; printf '%s' "${token}" | "${K[@]}" exec -i "deploy/${VAULT_DEPLOY}" -c vault -- \
  sh -c 'VAULT_TOKEN="$(cat)" exec vault "$@"' vault "$@"; }
# psql as the PostgreSQL superuser over the in-pod Unix socket.
psql_q() { "${K[@]}" exec "${PG_POD}" -c postgresql -- psql -X -v ON_ERROR_STOP=1 -U postgres -tA "$@"; }
sql_is() { local want="$1" db="$2" q="$3"; [[ "$(psql_q -d "${db}" -c "${q}" 2>/dev/null)" == "${want}" ]]; }

echo "verify.sh: context=${CONTEXT} namespace=${NAMESPACE} release=${RELEASE}"

section "Dependencies"
check "PostgreSQL StatefulSet ready" test "$("${K[@]}" get statefulset "${QS_FULLNAME}-postgresql" -o jsonpath='{.status.readyReplicas}')" = 1
check "dev Vault Deployment ready" test "$("${K[@]}" get deployment "${VAULT_DEPLOY}" -o jsonpath='{.status.readyReplicas}')" = 1
boot_job="$("${K[@]}" get jobs -l "app.kubernetes.io/instance=${QS_RELEASE},app.kubernetes.io/component=bootstrap" \
  --sort-by=.metadata.creationTimestamp -o name | tail -n 1)"
check "latest bootstrap Job (${boot_job#job.batch/}) succeeded" test "$("${K[@]}" get "${boot_job}" -o jsonpath='{.status.succeeded}')" = 1
check "only ClusterIP Services" test -z "$("${K[@]}" get svc -l "app.kubernetes.io/instance=${QS_RELEASE}" -o jsonpath='{range .items[?(@.spec.type!="ClusterIP")]}{.metadata.name}{end}')"

section "PostgreSQL schema, ownership and grants"
check "databases genesis/permesi owned by vault_genesis/vault_permesi" sql_is "genesis:vault_genesis,permesi:vault_permesi" postgres \
  "SELECT string_agg(datname||':'||pg_get_userbyid(datdba), ',' ORDER BY datname) FROM pg_database WHERE datname IN ('genesis','permesi')"
check "vault_* owners: LOGIN CREATEROLE, not superuser" sql_is "2" postgres \
  "SELECT count(*) FROM pg_roles WHERE rolname IN ('vault_genesis','vault_permesi') AND rolcanlogin AND rolcreaterole AND NOT rolsuper AND NOT rolcreatedb"
if "${K[@]}" exec "${PG_POD}" -c postgresql -- sh -c 'cd /tmp && PGPASSWORD=change-me psql -X -U vault_permesi -d permesi -h 127.0.0.1 -c "select 1"' >/dev/null 2>&1; then
  fail "vault_permesi must not accept the change-me placeholder password"
else
  pass "vault_permesi rejects the change-me placeholder password"
fi
check "runtime roles NOLOGIN, not superuser" sql_is "2" postgres \
  "SELECT count(*) FROM pg_roles WHERE rolname IN ('genesis_runtime','permesi_runtime') AND NOT rolcanlogin AND NOT rolsuper AND NOT rolcreaterole"
check "owners hold runtime roles WITH ADMIN OPTION (canonical grant)" sql_is "2" postgres \
  "SELECT count(*) FROM pg_auth_members m WHERE m.admin_option AND (pg_get_userbyid(m.roleid),pg_get_userbyid(m.member)) IN (('genesis_runtime','vault_genesis'),('permesi_runtime','vault_permesi'))"
check "owners hold pg_signal_backend (lease revocation)" sql_is "2" postgres \
  "SELECT count(*) FROM pg_auth_members WHERE roleid='pg_signal_backend'::regrole AND pg_get_userbyid(member) IN ('vault_genesis','vault_permesi')"
check "permesi_runtime has no CREATE on schema public" sql_is "f" permesi "SELECT has_schema_privilege('permesi_runtime','public','CREATE')"
check "genesis_runtime has no CREATE on schema public" sql_is "f" genesis "SELECT has_schema_privilege('genesis_runtime','public','CREATE')"
check "no cross-database CONNECT for the other owner" sql_is "false,false" postgres \
  "SELECT has_database_privilege('vault_genesis','permesi','CONNECT')::text||','||has_database_privilege('vault_permesi','genesis','CONNECT')::text"
check "Genesis test client 00000000-0000-0000-0000-000000000000 seeded" sql_is "1" genesis \
  "SELECT count(*) FROM clients WHERE uuid='00000000-0000-0000-0000-000000000000'"
check "no trust authentication for TCP connections" sql_is "0" postgres \
  "SELECT count(*) FROM pg_hba_file_rules WHERE type LIKE 'host%' AND auth_method='trust'"
if "${K[@]}" exec "${PG_POD}" -c postgresql -- sh -c 'cd /tmp && psql -X -U vault_permesi -d permesi -h 127.0.0.1 -w -c "select 1"' >/dev/null 2>&1; then
  fail "TCP login without a password must fail"
else
  pass "TCP login without a password fails"
fi
echo "INFO: verify_permesi.sql ran as vault_permesi in the bootstrap Job; check.sql (pg_cron) is NOT exercised by the quickstart"

section "Vault mounts, keys and PKI"
mount_type() { vroot read -field=type "sys/mounts/$1" 2>/dev/null; }
check "auth/kubernetes enabled" test "$(vroot read -field=type sys/auth/kubernetes 2>/dev/null)" = kubernetes
check "secret/permesi is KV v2" sh -c "test '$(mount_type secret/permesi)' = kv && test '$(vroot read -field=options sys/mounts/secret/permesi 2>/dev/null)' = 'map[version:2]'"
for m in transit/permesi:transit transit/genesis:transit database:database pki-root:pki pki-int:pki; do
  check "${m%%:*} is ${m##*:}" test "$(mount_type "${m%%:*}")" = "${m##*:}"
done
check "dev-mode default secret/ mount removed" test -z "$(mount_type secret)"
for k in transit/permesi/keys/totp:chacha20-poly1305 transit/genesis/keys/genesis-signing:ed25519 transit/permesi/keys/oidc-signing:rsa-2048; do
  key="${k%%:*}"
  check "${key} type ${k##*:}" test "$(vroot read -field=type "${key}" 2>/dev/null)" = "${k##*:}"
  check "${key} non-exportable, no plaintext backup, 30d rotation" test \
    "$(vroot read -field=exportable "${key}")/$(vroot read -field=allow_plaintext_backup "${key}")/$(vroot read -field=auto_rotate_period "${key}")" = "false/false/2592000"
done
seed_fp="$(vroot kv get -mount=secret/permesi -field=opaque_server_seed config 2>/dev/null | sha256sum | cut -c1-12 || true)"
pepper_len="$(vroot kv get -mount=secret/permesi -field=mfa_recovery_pepper config 2>/dev/null | base64 -d 2>/dev/null | wc -c || true)"
seed_len="$(vroot kv get -mount=secret/permesi -field=opaque_server_seed config 2>/dev/null | base64 -d 2>/dev/null | wc -c || true)"
check "opaque_server_seed and mfa_recovery_pepper are 32-byte standard base64" test "${seed_len}/${pepper_len}" = "32/32"
check "database/config/{permesi,genesis} restricted to their own role" test \
  "$(vroot read -field=allowed_roles database/config/permesi)/$(vroot read -field=allowed_roles database/config/genesis)" = "[permesi]/[genesis]"
ca_chain="$(vroot read -field=certificate pki-int/cert/ca_chain 2>/dev/null || true)"
check "pki-int CA chain = intermediate + root (2 certificates)" test "$(grep -c 'BEGIN CERTIFICATE' <<<"${ca_chain}")" = 2
ca_fp="$(printf '%s' "${ca_chain}" | sha256sum | cut -c1-12)"
svc_fqdn="${PERMESI_NAME}.${NAMESPACE}.svc"
check "permesi-runtime issues exact Service DNS (${svc_fqdn})" vroot write -field=serial_number pki-int/issue/permesi-runtime common_name="${svc_fqdn}" ttl=5m
for bad in "evil.${svc_fqdn}" "*.${NAMESPACE}.svc" "${GENESIS_NAME}.${NAMESPACE}.svc" "localhost" "example.com"; do
  if vroot write -field=serial_number pki-int/issue/permesi-runtime common_name="${bad}" ttl=5m >/dev/null 2>&1; then
    fail "permesi-runtime must refuse ${bad}"
  else
    pass "permesi-runtime refuses ${bad}"
  fi
done
if vroot write -field=serial_number pki-int/issue/permesi-runtime common_name="${svc_fqdn}" ip_sans=127.0.0.1 ttl=5m >/dev/null 2>&1; then
  fail "permesi-runtime must refuse IP SANs"
else
  pass "permesi-runtime refuses IP SANs"
fi

section "Kubernetes auth roles"
for svc in permesi:"${PERMESI_NAME}" genesis:"${GENESIS_NAME}"; do
  role="${svc%%:*}" sa="${svc##*:}"
  check "role ${role} bound to SA ${sa} in ${NAMESPACE} only, audience vault" test \
    "$(vroot read -field=bound_service_account_names "auth/kubernetes/role/${role}")|$(vroot read -field=bound_service_account_namespaces "auth/kubernetes/role/${role}")|$(vroot read -field=audience "auth/kubernetes/role/${role}")" \
    = "[${sa}]|[${NAMESPACE}]|vault"
done

# role_token <role> <sa>: real Kubernetes-auth login when the application
# ServiceAccount exists, otherwise a short-lived token with exactly the role's
# policies. Prints the token (captured, never echoed).
token_source() {
  if "${K[@]}" get serviceaccount "$1" >/dev/null 2>&1; then echo "kubernetes auth login (SA $1)"; else echo "policy-equivalent token (SA $1 not created yet)"; fi
}
role_token() {
  local role="$1" sa="$2"
  if "${K[@]}" get serviceaccount "${sa}" >/dev/null 2>&1; then
    "${K[@]}" create token "${sa}" --audience vault --duration 10m \
      | "${K[@]}" exec -i "deploy/${VAULT_DEPLOY}" -c vault -- \
          vault write -field=token auth/kubernetes/login role="${role}" jwt=-
  else
    local p args=()
    for p in $(vroot read -field=token_policies "auth/kubernetes/role/${role}" | tr -d '[]'); do args+=("-policy=${p}"); done
    vroot token create -field=token -ttl=10m "${args[@]}"
  fi
}

section "Split trust (real requests with service tokens)"
PT="$(role_token permesi "${PERMESI_NAME}" || true)"; echo "INFO: permesi token: $(token_source "${PERMESI_NAME}")"
GT="$(role_token genesis "${GENESIS_NAME}" || true)"; echo "INFO: genesis token: $(token_source "${GENESIS_NAME}")"
[[ -n "${PT}" && -n "${GT}" ]] || fail "could not obtain service tokens"

allow() { local desc="$1" tok="$2"; shift 2; if vas "${tok}" "$@" >/dev/null 2>&1; then pass "allowed: ${desc}"; else fail "should be allowed: ${desc}"; fi; }
deny()  { local desc="$1" tok="$2"; shift 2; local out; if out="$(vas "${tok}" "$@" 2>&1)"; then fail "should be denied: ${desc}"; elif grep -q 'permission denied' <<<"${out}"; then pass "denied: ${desc}"; else fail "unexpected error (not a permission denial): ${desc}"; fi; }

allow "permesi reads secret/permesi/data/config" "${PT}" kv get -mount=secret/permesi -field=opaque_server_seed config
allow "permesi generates a TOTP data key (transit/permesi/datakey/plaintext/totp)" "${PT}" write -f -field=ciphertext transit/permesi/datakey/plaintext/totp
allow "permesi signs with transit/permesi/sign/oidc-signing" "${PT}" write -field=signature transit/permesi/sign/oidc-signing input=cXVpY2tzdGFydA==
allow "permesi issues its listener certificate" "${PT}" write -field=serial_number pki-int/issue/permesi-runtime common_name="${svc_fqdn}" ttl=5m
allow "permesi reads pki-int/cert/ca_chain" "${PT}" read -field=certificate pki-int/cert/ca_chain
allow "genesis signs with transit/genesis/sign/genesis-signing" "${GT}" write -field=signature transit/genesis/sign/genesis-signing input=cXVpY2tzdGFydA==
allow "genesis issues its listener certificate" "${GT}" write -field=serial_number pki-int/issue/genesis-runtime common_name="${GENESIS_NAME}.${NAMESPACE}.svc" ttl=5m
deny "permesi -> transit/genesis/sign/genesis-signing" "${PT}" write transit/genesis/sign/genesis-signing input=cXVpY2tzdGFydA==
deny "permesi -> database/creds/genesis" "${PT}" read database/creds/genesis
deny "permesi -> pki-int/issue/genesis-runtime" "${PT}" write pki-int/issue/genesis-runtime common_name="${GENESIS_NAME}.${NAMESPACE}.svc"
deny "permesi -> transit/permesi/keys/oidc-signing/rotate" "${PT}" write -f transit/permesi/keys/oidc-signing/rotate
deny "permesi -> token creation" "${PT}" token create -ttl=5m
deny "genesis -> secret/permesi/data/config" "${GT}" read secret/permesi/data/config
deny "genesis -> database/creds/permesi" "${GT}" read database/creds/permesi
deny "genesis -> transit/permesi/decrypt/totp" "${GT}" write transit/permesi/decrypt/totp ciphertext=vault:v1:AAAA
deny "genesis -> transit/permesi/sign/oidc-signing" "${GT}" write transit/permesi/sign/oidc-signing input=cXVpY2tzdGFydA==
deny "genesis -> pki-int/issue/permesi-runtime" "${GT}" write pki-int/issue/permesi-runtime common_name="${svc_fqdn}"
deny "genesis -> sys/mounts" "${GT}" read sys/mounts

# Dynamic DB credentials: issue as each service, check the role, revoke.
for pair in permesi:"${PT}" genesis:"${GT}"; do
  svc="${pair%%:*}" tok="${pair#*:}"
  if lease="$(vas "${tok}" read -format=json "database/creds/${svc}" 2>/dev/null | sed -n 's/.*"lease_id": *"\([^"]*\)".*/\1/p')" && [[ -n "${lease}" ]]; then
    user_count="$(psql_q -d postgres -c "SELECT count(*) FROM pg_auth_members WHERE roleid='${svc}_runtime'::regrole AND pg_get_userbyid(member) LIKE 'v-%'")"
    vroot lease revoke "${lease}" >/dev/null 2>&1 || true
    [[ "${user_count}" -ge 1 ]] && pass "database/creds/${svc} issues a ${svc}_runtime member (lease revoked)" \
      || fail "database/creds/${svc} user not granted ${svc}_runtime"
  else
    fail "database/creds/${svc} not issued for ${svc}"
  fi
done
vas "${PT}" token revoke -self >/dev/null 2>&1 || true
vas "${GT}" token revoke -self >/dev/null 2>&1 || true

section "Identity fingerprints (compare across reruns; no secret material)"
echo "INFO: opaque_server_seed sha256[:12]=${seed_fp}"
echo "INFO: pki-int ca_chain sha256[:12]=${ca_fp}"
echo "INFO: transit genesis-signing latest_version=$(vroot read -field=latest_version transit/genesis/keys/genesis-signing)"
echo "INFO: transit genesis-signing public keys sha256[:12]=$(vroot read -field=keys transit/genesis/keys/genesis-signing | sha256sum | cut -c1-12)"

if [[ "$DEPS_ONLY" != true ]]; then
  section "Real application runtime"
  python3 "$(dirname "${BASH_SOURCE[0]}")/verify-runtime.py" \
    --context "$CONTEXT" --namespace "$NAMESPACE" --release "$RELEASE" "${RUNTIME_ARGS[@]}" \
    || fail "application runtime verification"
fi

echo
if [[ ${FAILURES} -eq 0 ]]; then
  echo "verify.sh: ALL CHECKS PASSED"
else
  echo "verify.sh: ${FAILURES} CHECK(S) FAILED"
  exit 1
fi
