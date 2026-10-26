#!/usr/bin/env bash
# Permesi quickstart PostgreSQL bootstrap (development only).
# Pre-creates the vault_* owner roles with generated strong passwords, runs the
# canonical include tree (00_init.sql), then an explicit owner-authenticated
# verify_permesi.sql. Records the existing Permesi user count for the Vault
# container's retained-database / lost-Vault guard.
set -euo pipefail

PG_HOST="${PG_HOST:?PG_HOST required}"
PG_PORT="${PG_PORT:-5432}"
CRED_DIR="${CRED_DIR:-/credentials}"
STATE_DIR="${STATE_DIR:-/state}"

ADMIN_PW="$(cat "${CRED_DIR}/postgres-admin-password")"
PERMESI_PW="$(cat "${CRED_DIR}/vault-permesi-password")"
GENESIS_PW="$(cat "${CRED_DIR}/vault-genesis-password")"

# Bounded wait for PostgreSQL.
for _ in $(seq 1 90); do
  pg_isready -q -h "${PG_HOST}" -p "${PG_PORT}" && break
  sleep 2
done
pg_isready -h "${PG_HOST}" -p "${PG_PORT}"

# Restrictive .pgpass in this container's private memory volume: administrator
# and both owners. No PGPASSWORD, so `\connect` authenticates as each owner.
umask 077
PGPASSFILE="$(mktemp)"
export PGPASSFILE
trap 'rm -f "${PGPASSFILE}"' EXIT
cat > "${PGPASSFILE}" <<EOF
${PG_HOST}:${PG_PORT}:*:postgres:${ADMIN_PW}
${PG_HOST}:${PG_PORT}:genesis:vault_genesis:${GENESIS_PW}
${PG_HOST}:${PG_PORT}:permesi:vault_permesi:${PERMESI_PW}
EOF

admin_psql() { psql -X -h "${PG_HOST}" -p "${PG_PORT}" -U postgres -v ON_ERROR_STOP=1 "$@"; }

# Pre-create non-superuser LOGIN CREATEROLE owners so 00_init.sql never falls
# back to its 'change-me' placeholder. Never touch an existing role's password
# (Vault may have rotated it).
admin_psql -d postgres -q -v perm_pw="${PERMESI_PW}" -v gen_pw="${GENESIS_PW}" <<'SQL'
SELECT pg_catalog.format('CREATE ROLE %I WITH LOGIN PASSWORD %L CREATEROLE', 'vault_permesi', :'perm_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vault_permesi')\gexec
SELECT pg_catalog.format('CREATE ROLE %I WITH LOGIN PASSWORD %L CREATEROLE', 'vault_genesis', :'gen_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vault_genesis')\gexec
SQL

cd /db/sql
admin_psql -d postgres -f 00_init.sql
echo "sql-bootstrap: 00_init.sql complete"

# Explicit owner-authenticated verification (transactional, rolls back).
psql -X -h "${PG_HOST}" -p "${PG_PORT}" -U vault_permesi -d permesi -v ON_ERROR_STOP=1 -f verify_permesi.sql
echo "sql-bootstrap: verify_permesi.sql (as vault_permesi) complete"

users="$(admin_psql -d permesi -tA -c 'SELECT count(*) FROM public.users')"
printf '%s\n' "${users}" > "${STATE_DIR}/permesi-user-count"
chmod 0644 "${STATE_DIR}/permesi-user-count"  # nonsecret; read by the Vault container
echo "sql-bootstrap: complete (existing permesi users: ${users})"
