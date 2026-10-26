#!/usr/bin/env sh
# Create the bootstrap-only credentials Secret exactly once (development only).
# POST-only: an existing Secret yields 409 and is never read or replaced.
set -eu

NAMESPACE="${NAMESPACE:?NAMESPACE required}"
SECRET_NAME="${SECRET_NAME:?SECRET_NAME required}"
INSTANCE="${INSTANCE:?INSTANCE required}"
SA_DIR=/var/run/secrets/kubernetes.io/serviceaccount
API="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"

# busybox wget verifies TLS against SSL_CERT_FILE.
export SSL_CERT_FILE="${SA_DIR}/ca.crt"

# 32 base64url characters (safe in .pgpass, SQL literals and URLs).
gen() { head -c 24 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'; }
# Vault rejects custom root token IDs carrying a token-type prefix ("hvs.");
# 48 hex characters are a valid custom ID.
gen_token() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

umask 077
body="$(mktemp)"
trap 'rm -f "${body}"' EXIT
cat > "${body}" <<EOF
{"apiVersion":"v1","kind":"Secret","type":"Opaque",
 "metadata":{"name":"${SECRET_NAME}","namespace":"${NAMESPACE}",
  "labels":{"app.kubernetes.io/name":"permesi-quickstart","app.kubernetes.io/instance":"${INSTANCE}","app.kubernetes.io/component":"bootstrap-credentials"},
  "annotations":{"permesi.dev/lifecycle":"bootstrap-only development credentials; not Helm-owned; delete for a dev reset"}},
 "stringData":{"postgres-admin-password":"$(gen)","vault-root-token":"$(gen_token)",
  "vault-permesi-password":"$(gen)","vault-genesis-password":"$(gen)"}}
EOF

# The bearer token is visible only inside this single-purpose container.
status="$(wget -S -O /dev/null \
  --header "Authorization: Bearer $(cat "${SA_DIR}/token")" \
  --header "Content-Type: application/json" \
  --post-file "${body}" \
  "${API}/api/v1/namespaces/${NAMESPACE}/secrets" 2>&1 | sed -n 's#^ *HTTP/[0-9.]* \([0-9]*\).*#\1#p' | tail -n 1 || true)"

case "${status}" in
  201) echo "created credentials Secret ${SECRET_NAME}" ;;
  409) echo "credentials Secret ${SECRET_NAME} already exists; not regenerating" ;;
  *) echo "failed to create credentials Secret ${SECRET_NAME} (HTTP status '${status}')" >&2; exit 1 ;;
esac
