#!/usr/bin/env bash
# Permesi quickstart PostgreSQL bootstrap (development only).
# Pre-creates the openbao_* owner roles with generated strong passwords, runs the
# canonical include tree (00_init.sql), then an explicit owner-authenticated
# verify_permesi.sql. Records the existing Permesi user count for the OpenBao
# container's retained-database / lost-OpenBao guard.
set -euo pipefail

PG_HOST="${PG_HOST:?PG_HOST required}"
PG_PORT="${PG_PORT:-5432}"
CRED_DIR="${CRED_DIR:-/credentials}"
STATE_DIR="${STATE_DIR:-/state}"

# Preserve trailing bytes while reading, then reject line breaks unsupported by
# libpq's line-oriented password file. Never include credential bytes in errors.
read_password() {
  local value
  value="$(cat "${CRED_DIR}/$1" && printf '.')" || return
  value="${value%.}"
  case "$value" in
    *$'\n'*|*$'\r'*) echo "sql-bootstrap: credential $1 contains unsupported line breaks" >&2; exit 1 ;;
  esac
  printf '%s' "$value"
}
ADMIN_PW="$(read_password postgres-admin-password)"
PERMESI_PW="$(read_password openbao-permesi-password)"
GENESIS_PW="$(read_password openbao-genesis-password)"

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
pgpass_escape() {
  local value="${1//\\/\\\\}"
  printf '%s' "${value//:/\\:}"
}
{
  printf '%s:%s:*:postgres:%s\n' "$PG_HOST" "$PG_PORT" "$(pgpass_escape "$ADMIN_PW")"
  printf '%s:%s:genesis:%s:%s\n' "$PG_HOST" "$PG_PORT" "openbao_genesis" "$(pgpass_escape "$GENESIS_PW")"
  printf '%s:%s:permesi:%s:%s\n' "$PG_HOST" "$PG_PORT" "openbao_permesi" "$(pgpass_escape "$PERMESI_PW")"
} > "$PGPASSFILE"

admin_psql() { psql -X -h "${PG_HOST}" -p "${PG_PORT}" -U postgres -v ON_ERROR_STOP=1 "$@"; }

# Conservatively couple ALL retained application databases to their OpenBao
# identity, even before any user exists. Partial bootstrap requires explicit
# dev reset if it created databases but never persisted the OpenBao seed.
retained="$(admin_psql -d postgres -tA -c "SELECT count(*) FROM pg_database WHERE datname IN ('permesi','genesis')")"
printf '%s\n' "$retained" > "${STATE_DIR}/retained-database-count"
chmod 0644 "${STATE_DIR}/retained-database-count"

# Pre-create canonical owners with strong passwords, never resetting them.
# OpenBao uses separate managers below; root rotation must not change these
# owner-authenticated schema bootstrap credentials.
admin_psql -d postgres -q -v perm_owner=openbao_permesi -v gen_owner=openbao_genesis -v perm_pw="${PERMESI_PW}" -v gen_pw="${GENESIS_PW}" <<'SQL'
SELECT pg_catalog.format('CREATE ROLE %I WITH LOGIN PASSWORD %L CREATEROLE', :'perm_owner', :'perm_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'perm_owner')\gexec
SELECT pg_catalog.format('CREATE ROLE %I WITH LOGIN PASSWORD %L CREATEROLE', :'gen_owner', :'gen_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'gen_owner')\gexec
SQL

cd /db/sql
admin_psql -d postgres -f 00_init.sql
echo "sql-bootstrap: 00_init.sql complete"

# Credential managers have no schema ownership or inherited runtime access.
# Bootstrap with the corresponding owner password once; OpenBao immediately
# rotates it and owns the steady-state credential. Never reset existing roles.
admin_psql -d postgres -q -v perm_pw="${PERMESI_PW}" -v gen_pw="${GENESIS_PW}" <<'SQL'
SELECT pg_catalog.format('CREATE ROLE %I WITH LOGIN PASSWORD %L CREATEROLE', 'openbao_permesi_manager', :'perm_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'openbao_permesi_manager')\gexec
SELECT pg_catalog.format('CREATE ROLE %I WITH LOGIN PASSWORD %L CREATEROLE', 'openbao_genesis_manager', :'gen_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'openbao_genesis_manager')\gexec
GRANT permesi_runtime TO openbao_permesi_manager WITH ADMIN TRUE, INHERIT FALSE, SET FALSE;
GRANT genesis_runtime TO openbao_genesis_manager WITH ADMIN TRUE, INHERIT FALSE, SET FALSE;
GRANT CONNECT ON DATABASE permesi TO openbao_permesi_manager;
GRANT CONNECT ON DATABASE genesis TO openbao_genesis_manager;
GRANT pg_signal_backend TO openbao_permesi_manager, openbao_genesis_manager;
-- The Genesis connection manages credentials from the maintenance database.
GRANT CONNECT ON DATABASE postgres TO openbao_genesis_manager;
SQL

# Explicit owner-authenticated verification (transactional, rolls back).
psql -X -h "${PG_HOST}" -p "${PG_PORT}" -U openbao_permesi -d permesi -v ON_ERROR_STOP=1 -f verify_permesi.sql
echo "sql-bootstrap: verify_permesi.sql (as openbao_permesi) complete"

users="$(admin_psql -d permesi -tA -c 'SELECT count(*) FROM public.users')"
printf '%s\n' "${users}" > "${STATE_DIR}/permesi-user-count"
chmod 0644 "${STATE_DIR}/permesi-user-count"  # nonsecret; read by the OpenBao container
echo "sql-bootstrap: complete (existing permesi users: ${users})"
