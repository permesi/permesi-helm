#!/usr/bin/env sh
# Permesi quickstart OpenBao bootstrap (development only). Idempotent; runs
# with the dev root token. Translates the application's
# openbao/contrib/opentofu module into explicit bao CLI operations, with
# Kubernetes auth instead of AppRole/cert auth. Existing mounts/keys are
# type-checked before reuse; failures are fatal (no `|| true`).
set -eu

export BAO_ADDR="${BAO_ADDR:?BAO_ADDR required}"
[ -n "${BAO_TOKEN:-}" ] || { echo "BAO_TOKEN required" >&2; exit 1; }

PG_HOST="${PG_HOST:?PG_HOST required}"
PG_PORT="${PG_PORT:-5432}"
NAMESPACE="${NAMESPACE:?NAMESPACE required}"
PERMESI_SA="${PERMESI_SA:?PERMESI_SA required}"
GENESIS_SA="${GENESIS_SA:?GENESIS_SA required}"
AUDIENCE="${AUDIENCE:-openbao}"
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
OPENBAO_PUBLIC_ADDR="${OPENBAO_PUBLIC_ADDR:?OPENBAO_PUBLIC_ADDR required}"
STATE_DIR="${STATE_DIR:-/state}"

log() { echo "openbao-bootstrap: $*"; }
die() { echo "openbao-bootstrap: ERROR: $*" >&2; exit 1; }

# Bounded wait for the dev OpenBao server.
i=0
until bao status >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -le 90 ] || die "OpenBao at ${BAO_ADDR} never became ready"
  sleep 2
done

# mount_type <path>: prints the secrets-engine type, or nothing if absent.
mount_type() { bao read -field=type "sys/mounts/$1" 2>/dev/null || true; }
auth_type()  { bao read -field=type "sys/auth/$1" 2>/dev/null || true; }

# ensure_mount <path> <type> [extra enable args...]
ensure_mount() {
  path="$1"; want="$2"; shift 2
  got="$(mount_type "$path")"
  if [ -z "$got" ]; then
    bao secrets enable -path="$path" "$@" "$want" >/dev/null
    log "enabled ${want} at ${path}/"
  elif [ "$got" != "$want" ]; then
    die "mount ${path}/ exists with type '${got}', expected '${want}'"
  fi
}

# ensure_transit_key <mount> <name> <type> <rotation>: create once
# (non-exportable, no plaintext backup); verify type/exportability on reuse.
ensure_transit_key() {
  mount="$1"; name="$2"; want="$3"; rotation="$4"
  got="$(bao read -field=type "${mount}/keys/${name}" 2>/dev/null || true)"
  if [ -z "$got" ]; then
    bao write "${mount}/keys/${name}" type="$want" auto_rotate_period="$rotation" \
      exportable=false allow_plaintext_backup=false >/dev/null
    log "created transit key ${mount}/keys/${name} (${want})"
  elif [ "$got" != "$want" ]; then
    die "transit key ${mount}/keys/${name} exists with type '${got}', expected '${want}'"
  fi
  [ "$(bao read -field=exportable "${mount}/keys/${name}")" = "false" ] \
    || die "transit key ${mount}/keys/${name} is exportable"
  bao write "${mount}/keys/${name}/config" auto_rotate_period="$rotation" deletion_allowed=false >/dev/null
}

# --- 1. auth/kubernetes -----------------------------------------------------
# No token_reviewer_jwt / kubernetes_ca_cert: OpenBao uses (and periodically
# re-reads) its own pod service-account token, which alone holds TokenReview.
got="$(auth_type kubernetes)"
if [ -z "$got" ]; then
  bao auth enable kubernetes >/dev/null
  log "enabled auth/kubernetes"
elif [ "$got" != "kubernetes" ]; then
  die "auth/kubernetes exists with type '${got}'"
fi
bao write auth/kubernetes/config kubernetes_host="${K8S_HOST}" >/dev/null

# --- 2. KV v2 secret/permesi ------------------------------------------------
# Dev mode pre-mounts KV v2 at secret/, which would shadow secret/permesi.
if [ "$(mount_type secret)" = "kv" ]; then
  bao secrets disable secret/ >/dev/null
  log "disabled dev-mode default secret/ mount"
fi
ensure_mount secret/permesi kv -version=2
kv_version="$(bao read -format=json sys/mounts/secret/permesi | grep -o '"version": *"[0-9]*"' | grep -o '[0-9]*' || true)"
[ "$kv_version" = "2" ] || die "secret/permesi/ is not KV version 2 (got '${kv_version}')"

# Retained database / lost OpenBao: never invent a replacement identity, even
# when the retained databases currently contain no users.
retained="$(cat "${STATE_DIR}/retained-database-count" 2>/dev/null || echo unknown)"

seed=no; pepper=no
bao kv get -mount=secret/permesi -field=opaque_server_seed config >/dev/null 2>&1 && seed=yes
bao kv get -mount=secret/permesi -field=mfa_recovery_pepper config >/dev/null 2>&1 && pepper=yes
if [ "$seed" = no ] && [ "$pepper" = no ]; then
  case "$retained" in
    0) ;;
    *) die "secret/permesi/config is absent with ${retained} retained application database(s): lost dev OpenBao state is not recoverable by generating a new OPAQUE seed. Reset the development install (delete the release namespace) or restore OpenBao." ;;
  esac
  # 32 random bytes, standard base64 (matches the module's random_id.b64_std).
  bao kv put -mount=secret/permesi config \
    opaque_server_seed="$(head -c 32 /dev/urandom | base64 | tr -d '\n')" \
    mfa_recovery_pepper="$(head -c 32 /dev/urandom | base64 | tr -d '\n')" >/dev/null
  log "generated opaque_server_seed and mfa_recovery_pepper"
elif [ "$seed" = yes ] && [ "$pepper" = yes ]; then
  log "secret/permesi/config already populated; not regenerating"
else
  die "secret/permesi/config is partially populated; refusing to replace cryptographic identity"
fi

# --- 3. transit mounts + keys ------------------------------------------------
# TOTP and OIDC keys rotate every 30 days. Operators stage, publish and activate
# admission signing versions explicitly, so genesis-signing never auto-rotates.
ensure_mount transit/permesi transit
ensure_mount transit/genesis transit
ensure_transit_key transit/permesi totp chacha20-poly1305 720h
ensure_transit_key transit/genesis genesis-signing ed25519 0
if [ "$OIDC_ENABLED" = "true" ]; then
  ensure_transit_key transit/permesi oidc-signing rsa-2048 720h
fi

# --- 4. database secrets engine ---------------------------------------------
ensure_mount database database
# Connection credentials are written only for an absent config. A root-only KV
# marker separately records initial rotation, so interruption after config
# creation (or after rotation but before its marker write) is safe to retry.
db_config() {
  name="$1"; user="$2"; pw_file="$3"; management_db="$4"
  rotation_path="bootstrap/manager-rotation/${name}"
  if existing="$(bao read "database/config/${name}" 2>&1)"; then
    : # Validate below; never overwrite OpenBao's current private credentials.
  else
    [ "$existing" = "No value found at database/config/${name}" ] \
      || die "cannot inspect database/config/${name}; refusing to overwrite manager credentials"
    # Reset even a stale completed marker BEFORE creating a new connection.
    bao kv put -mount=secret/permesi "$rotation_path" state=pending manager="$user" >/dev/null
    bao write "database/config/${name}" \
      plugin_name=postgresql-database-plugin \
      allowed_roles="${name}" \
      connection_url="postgresql://{{username}}:{{password}}@${PG_HOST}:${PG_PORT}/${management_db}?sslmode=disable" \
      max_connection_lifetime=120s \
      username="${user}" password=@"${pw_file}" \
      root_rotation_statements="ALTER ROLE \"${user}\" WITH PASSWORD '{{password}}';" >/dev/null
    log "configured database/config/${name}"
  fi
  bao read -format=json -field=connection_details "database/config/${name}" \
    | grep -Eq '^[[:space:]]*"username": "'"${user}"'"[,]?[[:space:]]*$' \
    || die "database/config/${name} must use ${user}; legacy owner-as-manager installs require restoring a manager-separated OpenBao configuration or an explicit disposable development namespace reset (no automatic password reset)"
  allowed="$(bao read -format=json -field=allowed_roles "database/config/${name}" | tr -d '[:space:]')"
  [ "$allowed" = "[\"${name}\"]" ] \
    || die "database/config/${name} allowed_roles must be exactly ${name}; repair the OpenBao configuration before rerunning"

  if rotation_state="$(bao kv get -mount=secret/permesi -field=state "$rotation_path" 2>&1)"; then
    rotation_manager="$(bao kv get -mount=secret/permesi -field=manager "$rotation_path")" \
      || die "cannot read initial rotation marker manager for ${name}"
    [ "$rotation_manager" = "$user" ] \
      || die "initial rotation marker for ${name} must identify ${user}; repair the bootstrap marker before rerunning"
    case "$rotation_state" in
      completed)
        log "database/config/${name} initial rotation complete; leaving manager credentials untouched"
        return 0 ;;
      pending) ;;
      *) die "invalid initial rotation marker state for ${name}; repair the bootstrap marker before rerunning" ;;
    esac
  else
    # Only a confirmed missing KV value is an incomplete legacy/cutpoint state.
    # Authorization, transport and malformed-marker errors must fail closed.
    [ "$rotation_state" = "No value found at secret/permesi/data/${rotation_path}" ] \
      || die "cannot read initial rotation marker for ${name}; refusing to skip rotation"
  fi
  bao write -force "database/rotate-root/${name}" >/dev/null
  bao kv put -mount=secret/permesi "$rotation_path" state=completed manager="$user" >/dev/null
  log "completed initial manager rotation for database/config/${name}"
}
db_role() {
  name="$1"; runtime="$2"; connection_cap="$3"
  bao write "database/roles/${name}" \
    db_name="${name}" \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN ${connection_cap} PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';" \
    creation_statements="GRANT ${runtime} TO \"{{name}}\";" \
    renew_statements="ALTER ROLE \"{{name}}\" WITH VALID UNTIL '{{expiration}}';" \
    revocation_statements="SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.usename = '{{name}}';" \
    revocation_statements="REVOKE ${runtime} FROM \"{{name}}\";" \
    revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
    default_ttl=1h max_ttl=4h >/dev/null
}
# Genesis manages credentials from the maintenance database, so it keeps working
# while the genesis database is saturated; each Genesis lease is capped at 10
# connections (the module's genesis_login_connection_limit).
db_config permesi openbao_permesi_manager /credentials/openbao-permesi-password permesi
db_config genesis openbao_genesis_manager /credentials/openbao-genesis-password postgres
db_role permesi permesi_runtime ""
db_role genesis genesis_runtime "CONNECTION LIMIT 10"

# --- 5. PKI: root + intermediate (created once) -----------------------------
ensure_mount pki-root pki
bao secrets tune -max-lease-ttl=87600h pki-root >/dev/null
ensure_mount pki-int pki
bao secrets tune -max-lease-ttl=26280h pki-int >/dev/null
bao write pki-root/config/urls \
  issuing_certificates="${OPENBAO_PUBLIC_ADDR}/v1/pki-root/ca" \
  crl_distribution_points="${OPENBAO_PUBLIC_ADDR}/v1/pki-root/crl" >/dev/null
bao write pki-int/config/urls \
  issuing_certificates="${OPENBAO_PUBLIC_ADDR}/v1/pki-int/ca" \
  crl_distribution_points="${OPENBAO_PUBLIC_ADDR}/v1/pki-int/crl" >/dev/null

if ! bao list pki-root/issuers >/dev/null 2>&1; then
  bao write pki-root/root/generate/internal common_name="${ROOT_CN}" \
    issuer_name=permesi-root key_type=ec key_bits=256 ttl=87600h >/dev/null
  log "generated root CA"
fi
if ! bao list pki-int/issuers >/dev/null 2>&1; then
  bao write -field=csr pki-int/intermediate/generate/internal \
    common_name="${INT_CN}" key_type=ec key_bits=256 > /tmp/int.csr
  # pem_bundle = intermediate followed by the root, so pki-int's issuer chain
  # (and every issued ca_chain) includes the full path to the root.
  bao write -field=certificate pki-root/root/sign-intermediate csr=@/tmp/int.csr \
    common_name="${INT_CN}" ttl=26280h format=pem_bundle > /tmp/int.pem
  bao write pki-int/intermediate/set-signed certificate=@/tmp/int.pem >/dev/null
  rm -f /tmp/int.csr /tmp/int.pem
  log "generated and signed intermediate CA"
fi
# The default issuer must be the intermediate that holds a key (set-signed
# also imports the keyless root certificate as an issuer).
int_issuer=""
for id in $(bao list -format=json pki-int/issuers | tr -d '[]", ' | tr '\n' ' '); do
  if [ "$(bao read -field=key_id "pki-int/issuer/${id}" 2>/dev/null || true)" != "" ]; then
    int_issuer="$id"; break
  fi
done
[ -n "$int_issuer" ] || die "pki-int has no issuer with a private key"
bao write pki-int/config/issuers default="${int_issuer}" >/dev/null

# Per-service listener roles: exact Service DNS names + explicit browser
# hostnames only (no subdomains/globs/wildcards/IPs/any-name).
pki_role() {
  name="$1"; domains="$2"
  bao write "pki-int/roles/${name}" \
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
bao policy write permesi /policies/permesi.hcl >/dev/null
bao policy write permesi-pki /policies/permesi-pki.hcl >/dev/null
bao policy write genesis /policies/genesis.hcl >/dev/null
bao policy write genesis-pki /policies/genesis-pki.hcl >/dev/null
permesi_policies="permesi,permesi-pki"
if [ "$OIDC_ENABLED" = "true" ]; then
  bao policy write permesi-oidc /policies/permesi-oidc.hcl >/dev/null
  permesi_policies="${permesi_policies},permesi-oidc"
elif bao policy read permesi-oidc >/dev/null 2>&1; then
  bao policy delete permesi-oidc >/dev/null
fi

k8s_role() {
  name="$1"; sa="$2"; policies="$3"
  bao write "auth/kubernetes/role/${name}" \
    bound_service_account_names="${sa}" \
    bound_service_account_namespaces="${NAMESPACE}" \
    audience="${AUDIENCE}" \
    token_no_default_policy=true token_policies="${policies}" \
    token_ttl="${ROLE_TTL}" token_max_ttl="${ROLE_MAX_TTL}" >/dev/null
}
k8s_role permesi "${PERMESI_SA}" "${permesi_policies}"
k8s_role genesis "${GENESIS_SA}" "genesis,genesis-pki"

# --- 7. Genesis edge rate quotas (module quotas.tf) --------------------------
# Separate buckets per edge path; the login quota binds the genesis role on the
# Kubernetes auth mount, written with the trailing slash OpenBao stores.
for path in transit/genesis/sign/genesis-signing database/creds/genesis pki-int/issue/genesis-runtime; do
  bao write "sys/quotas/rate-limit/genesis-$(echo "$path" | tr / -)" path="$path" rate=30 interval=1s >/dev/null
done
bao write sys/quotas/rate-limit/genesis-login path=auth/kubernetes/ role=genesis rate=30 interval=1s >/dev/null

log "complete (namespace=${NAMESPACE}, permesi sa=${PERMESI_SA}, genesis sa=${GENESIS_SA})"
