#!/usr/bin/env sh
# Schema acquisition (init container): populate /db/sql with the canonical
# permesi db/sql include tree, either from a pinned archive (sha256-verified;
# any failure is fatal, never a fallback) or from mounted SQL ConfigMaps.
set -eu

if [ -n "${SCHEMA_URL:-}" ]; then
  [ -n "${SCHEMA_SHA256:-}" ] || { echo "SCHEMA_SHA256 required with SCHEMA_URL" >&2; exit 1; }
  wget -q -T 60 -O /tmp/schema.tar.gz "${SCHEMA_URL}"
  printf '%s  %s\n' "${SCHEMA_SHA256}" /tmp/schema.tar.gz | sha256sum -c -
  mkdir /tmp/extract
  tar -xzf /tmp/schema.tar.gz -C /tmp/extract
  set -- /tmp/extract/*/db/sql/*.sql
  [ -f "$1" ] || { echo "archive contains no db/sql/*.sql" >&2; exit 1; }
  cp "$@" /db/sql/
  rm -rf /tmp/schema.tar.gz /tmp/extract
  echo "schema source: archive ${SCHEMA_URL}"
else
  set -- /input/*/*.sql
  [ -f "$1" ] || { echo "no *.sql keys found in mounted SQL ConfigMaps" >&2; exit 1; }
  cp "$@" /db/sql/
  echo "schema source: mounted ConfigMaps"
fi

for f in 00_init.sql bootstrap_ownership.sql 01_genesis.sql partitioning.sql seed_test_client.sql 02_permesi.sql verify_permesi.sql; do
  [ -f "/db/sql/${f}" ] || { echo "canonical SQL tree incomplete: missing ${f}" >&2; exit 1; }
done
echo "schema acquisition complete: $(ls /db/sql | wc -l) files"
