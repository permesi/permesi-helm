#!/usr/bin/env sh
# Permesi quickstart Vault bootstrap (development only). Idempotent; runs with
# the dev root token. Translates permesi vault/contrib/terraform/*.tf
# semantics into explicit Vault CLI operations. Existing mounts/keys are
# type-checked before reuse; failures are fatal (no `|| true`).
set -eu

export VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR required}"
[ -n "${VAULT_TOKEN:-}" ] || { echo "VAULT_TOKEN required" >&2; exit 1; }

PG_HOST="${PG_HOST:?PG_HOST required}"
PG_PORT="${PG_PORT:-5432}"
NAMESPACE="${NAMESPACE:?NAMESPACE required}"
PERMESI_SA="${PERMESI_SA:?PERMESI_SA required}"
GENESIS_SA="${GENESIS_SA:?GENESIS_SA required}"
AUDIENCE="${AUDIENCE:-vault}"
ROLE_TTL="${ROLE_TTL:-1h}"
ROLE_MAX_TTL="${ROLE_MAX_TTL:-4h}"
K8S_HOST="${K8S_HOST:-https://kubernetes.default.svc}"
ROOT_CN="${ROOT_CN:?ROOT_CN required}"
INT_CN="${INT_CN:?INT_CN required}"
PKI_TTL="${PKI_TTL:-24h}"
PKI_MAX_TTL="${PKI_MAX_TTL:-72h}"
OIDC_ENABLED="${OIDC_ENABLED:-true}"
PERMESI_DNS_NAMES="${PERMESI_DNS_NAMES:?PERMESI_DNS_NAMES required}"
GENESIS_DNS_NAMES="${GENESIS_DNS_NAMES:?GENESIS_DNS_NAMES required}"
VAULT_PUBLIC_ADDR="${VAULT_PUBLIC_ADDR:?VAULT_PUBLIC_ADDR required}"
STATE_DIR="${STATE_DIR:-/state}"

log() { echo "vault-bootstrap: $*"; }
die() { echo "vault-bootstrap: ERROR: $*" >&2; exit 1; }

# Bounded wait for the dev Vault server.
i=0
until vault status >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -le 90 ] || die "vault at ${VAULT_ADDR} never became ready"
  sleep 2
done

# mount_type <path>: prints the secrets-engine type, or nothing if absent.
mount_type() { vault read -field=type "sys/mounts/$1" 2>/dev/null || true; }
auth_type()  { vault read -field=type "sys/auth/$1" 2>/dev/null || true; }

# ensure_mount <path> <type> [extra enable args...]
ensure_mount() {
  path="$1"; want="$2"; shift 2
  got="$(mount_type "$path")"
  if [ -z "$got" ]; then
    vault secrets enable -path="$path" "$@" "$want" >/dev/null
    log "enabled ${want} at ${path}/"
  elif [ "$got" != "$want" ]; then
    die "mount ${path}/ exists with type '${got}', expected '${want}'"
  fi
}

# ensure_transit_key <mount> <name> <type>: create once (non-exportable, no
# plaintext backup, 30-day rotation); verify type/exportability on reuse.
ensure_transit_key() {
  mount="$1"; name="$2"; want="$3"
  got="$(vault read -field=type "${mount}/keys/${name}" 2>/dev/null || true)"
  if [ -z "$got" ]; then
    vault write "${mount}/keys/${name}" type="$want" auto_rotate_period=720h \
      exportable=false allow_plaintext_backup=false >/dev/null
    log "created transit key ${mount}/keys/${name} (${want})"
  elif [ "$got" != "$want" ]; then
    die "transit key ${mount}/keys/${name} exists with type '${got}', expected '${want}'"
  fi
  [ "$(vault read -field=exportable "${mount}/keys/${name}")" = "false" ] \
    || die "transit key ${mount}/keys/${name} is exportable"
  vault write "${mount}/keys/${name}/config" auto_rotate_period=720h deletion_allowed=false >/dev/null
}

# --- 1. auth/kubernetes -----------------------------------------------------
# No token_reviewer_jwt / kubernetes_ca_cert: Vault uses (and periodically
# re-reads) its own pod service-account token, which alone holds TokenReview.
got="$(auth_type kubernetes)"
if [ -z "$got" ]; then
  vault auth enable kubernetes >/dev/null
  log "enabled auth/kubernetes"
elif [ "$got" != "kubernetes" ]; then
  die "auth/kubernetes exists with type '${got}'"
fi
vault write auth/kubernetes/config kubernetes_host="${K8S_HOST}" >/dev/null

# --- 2. KV v2 secret/permesi ------------------------------------------------
# Dev mode pre-mounts KV v2 at secret/, which would shadow secret/permesi.
if [ "$(mount_type secret)" = "kv" ]; then
  vault secrets disable secret/ >/dev/null
  log "disabled dev-mode default secret/ mount"
fi
ensure_mount secret/permesi kv -version=2
kv_version="$(vault read -format=json sys/mounts/secret/permesi | grep -o '"version": *"[0-9]*"' | grep -o '[0-9]*' || true)"
[ "$kv_version" = "2" ] || die "secret/permesi/ is not KV version 2 (got '${kv_version}')"

# Retained database / lost Vault: never invent a replacement identity, even
# when the retained databases currently contain no users.
retained="$(cat "${STATE_DIR}/retained-database-count" 2>/dev/null || echo unknown)"

seed=no; pepper=no
vault kv get -mount=secret/permesi -field=opaque_server_seed config >/dev/null 2>&1 && seed=yes
vault kv get -mount=secret/permesi -field=mfa_recovery_pepper config >/dev/null 2>&1 && pepper=yes
if [ "$seed" = no ] && [ "$pepper" = no ]; then
  case "$retained" in
    0) ;;
    *) die "secret/permesi/config is absent with ${retained} retained application database(s): lost dev Vault state is not recoverable by generating a new OPAQUE seed. Reset the development install (delete the release namespace) or restore Vault." ;;
  esac
  # 32 random bytes, standard base64 (matches Terraform random_id.b64_std).
  vault kv put -mount=secret/permesi config \
    opaque_server_seed="$(head -c 32 /dev/urandom | base64 | tr -d '\n')" \
    mfa_recovery_pepper="$(head -c 32 /dev/urandom | base64 | tr -d '\n')" >/dev/null
  log "generated opaque_server_seed and mfa_recovery_pepper"
elif [ "$seed" = yes ] && [ "$pepper" = yes ]; then
  log "secret/permesi/config already populated; not regenerating"
else
  die "secret/permesi/config is partially populated; refusing to replace cryptographic identity"
fi

# --- 3. transit mounts + keys (30-day rotation) -----------------------------
ensure_mount transit/permesi transit
ensure_mount transit/genesis transit
ensure_transit_key transit/permesi totp chacha20-poly1305
ensure_transit_key transit/genesis genesis-signing ed25519
if [ "$OIDC_ENABLED" = "true" ]; then
  ensure_transit_key transit/permesi oidc-signing rsa-2048
fi

# --- 4. database secrets engine ---------------------------------------------
ensure_mount database database
# Connection config is written once: a rerun must never overwrite a manager
# password that an operator may since have rotated via rotate-root.
db_config() {
  name="$1"; user="$2"; pw_file="$3"
  if vault read "database/config/${name}" >/dev/null 2>&1; then
    log "database/config/${name} exists; leaving manager credentials untouched"
    return 0
  fi
  vault write "database/config/${name}" \
    plugin_name=postgresql-database-plugin \
    allowed_roles="${name}" \
    connection_url="postgresql://{{username}}:{{password}}@${PG_HOST}:${PG_PORT}/${name}?sslmode=disable" \
    max_connection_lifetime=120s \
    username="${user}" password=@"${pw_file}" \
    root_rotation_statements="ALTER ROLE \"${user}\" WITH PASSWORD '{{password}}';" >/dev/null
  log "configured database/config/${name}"
}
db_role() {
  name="$1"; runtime="$2"
  vault write "database/roles/${name}" \
    db_name="${name}" \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';" \
    creation_statements="GRANT ${runtime} TO \"{{name}}\";" \
    renew_statements="ALTER ROLE \"{{name}}\" WITH VALID UNTIL '{{expiration}}';" \
    revocation_statements="SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.usename = '{{name}}';" \
    revocation_statements="REVOKE ${runtime} FROM \"{{name}}\";" \
    revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
    default_ttl=1h max_ttl=4h >/dev/null
}
db_config permesi vault_permesi /credentials/vault-permesi-password
db_config genesis vault_genesis /credentials/vault-genesis-password
db_role permesi permesi_runtime
db_role genesis genesis_runtime

# --- 5. PKI: root + intermediate (created once) -----------------------------
ensure_mount pki-root pki
vault secrets tune -max-lease-ttl=87600h pki-root >/dev/null
ensure_mount pki-int pki
vault secrets tune -max-lease-ttl=26280h pki-int >/dev/null
vault write pki-root/config/urls \
  issuing_certificates="${VAULT_PUBLIC_ADDR}/v1/pki-root/ca" \
  crl_distribution_points="${VAULT_PUBLIC_ADDR}/v1/pki-root/crl" >/dev/null
vault write pki-int/config/urls \
  issuing_certificates="${VAULT_PUBLIC_ADDR}/v1/pki-int/ca" \
  crl_distribution_points="${VAULT_PUBLIC_ADDR}/v1/pki-int/crl" >/dev/null

if ! vault list pki-root/issuers >/dev/null 2>&1; then
  vault write pki-root/root/generate/internal common_name="${ROOT_CN}" \
    issuer_name=permesi-root key_type=ec key_bits=256 ttl=87600h >/dev/null
  log "generated root CA"
fi
if ! vault list pki-int/issuers >/dev/null 2>&1; then
  vault write -field=csr pki-int/intermediate/generate/internal \
    common_name="${INT_CN}" key_type=ec key_bits=256 > /tmp/int.csr
  # pem_bundle = intermediate followed by the root, so pki-int's issuer chain
  # (and every issued ca_chain) includes the full path to the root.
  vault write -field=certificate pki-root/root/sign-intermediate csr=@/tmp/int.csr \
    common_name="${INT_CN}" ttl=26280h format=pem_bundle > /tmp/int.pem
  vault write pki-int/intermediate/set-signed certificate=@/tmp/int.pem >/dev/null
  rm -f /tmp/int.csr /tmp/int.pem
  log "generated and signed intermediate CA"
fi
# The default issuer must be the intermediate that holds a key (set-signed
# also imports the keyless root certificate as an issuer).
int_issuer=""
for id in $(vault list -format=json pki-int/issuers | tr -d '[]", ' | tr '\n' ' '); do
  if [ "$(vault read -field=key_id "pki-int/issuer/${id}" 2>/dev/null || true)" != "" ]; then
    int_issuer="$id"; break
  fi
done
[ -n "$int_issuer" ] || die "pki-int has no issuer with a private key"
vault write pki-int/config/issuers default="${int_issuer}" >/dev/null

# Per-service listener roles: exact Service DNS names + explicit browser
# hostnames only (no subdomains/globs/wildcards/IPs/any-name).
pki_role() {
  name="$1"; domains="$2"
  vault write "pki-int/roles/${name}" \
    allowed_domains="${domains}" \
    allow_bare_domains=true allow_subdomains=false allow_glob_domains=false \
    allow_wildcard_certificates=false allow_any_name=false enforce_hostnames=true \
    allow_localhost=false allow_ip_sans=false \
    server_flag=true client_flag=false \
    key_type=ec key_bits=256 key_usage="DigitalSignature,KeyAgreement" \
    ttl="${PKI_TTL}" max_ttl="${PKI_MAX_TTL}" >/dev/null
}
pki_role permesi-runtime "${PERMESI_DNS_NAMES}"
pki_role genesis-runtime "${GENESIS_DNS_NAMES}"

# --- 6. policies + SA-bound kubernetes roles (last) -------------------------
vault policy write permesi /policies/permesi.hcl >/dev/null
vault policy write permesi-pki /policies/permesi-pki.hcl >/dev/null
vault policy write genesis /policies/genesis.hcl >/dev/null
vault policy write genesis-pki /policies/genesis-pki.hcl >/dev/null
permesi_policies="permesi,permesi-pki"
if [ "$OIDC_ENABLED" = "true" ]; then
  vault policy write permesi-oidc /policies/permesi-oidc.hcl >/dev/null
  permesi_policies="${permesi_policies},permesi-oidc"
elif vault policy read permesi-oidc >/dev/null 2>&1; then
  vault policy delete permesi-oidc >/dev/null
fi

k8s_role() {
  name="$1"; sa="$2"; policies="$3"
  vault write "auth/kubernetes/role/${name}" \
    bound_service_account_names="${sa}" \
    bound_service_account_namespaces="${NAMESPACE}" \
    audience="${AUDIENCE}" \
    token_policies="${policies}" \
    token_ttl="${ROLE_TTL}" token_max_ttl="${ROLE_MAX_TTL}" >/dev/null
}
k8s_role permesi "${PERMESI_SA}" "${permesi_policies}"
k8s_role genesis "${GENESIS_SA}" "genesis,genesis-pki"

log "complete (namespace=${NAMESPACE}, permesi sa=${PERMESI_SA}, genesis sa=${GENESIS_SA})"
