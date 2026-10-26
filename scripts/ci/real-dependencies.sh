#!/usr/bin/env bash
# Real dependencies: exact quickstart entry points, no alternate bootstrap.
# Locally use QS_APP_SOURCE=/app QS_CHARTS_DIR=.scratch/charts via hc, with
# QS_ADMISSION_BIN pointing at a host-built static-musl admission client.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
CONTEXT="${QS_CONTEXT:-$(kubectl config current-context)}"
NAMESPACE="${QS_NAMESPACE:-qs-ci}"
RELEASE="${QS_RELEASE:-permesi}"
APP_SOURCE="${QS_APP_SOURCE:-app}"
CHARTS_DIR="${QS_CHARTS_DIR:-charts}"
LOCKED_COMMIT="$(python3 -c 'import json; print(json.load(open("scripts/quickstart/lock.json"))["appRevision"])')"
[[ "$(git -C "$APP_SOURCE" rev-parse HEAD)" == "$LOCKED_COMMIT" ]] || { echo 'app SQL checkout does not match lock.json' >&2; exit 1; }

if [[ -z "${QS_ADMISSION_BIN:-}" ]]; then
  target="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/quickstart-admission"
  cargo build --locked --release --manifest-path scripts/quickstart/admission/Cargo.toml --target-dir "$target"
  export QS_ADMISSION_BIN="$target/release/quickstart-admission"
fi
log_dir="$(mktemp -d)"
trap 'rm -rf "$log_dir"' EXIT
install=(bash scripts/quickstart/install.sh --context "$CONTEXT" --namespace "$NAMESPACE" --release "$RELEASE"
         --acknowledge-development --app-source "$APP_SOURCE" --charts-dir "$CHARTS_DIR" --pki-ttl 2m)
verify=(bash scripts/quickstart/verify.sh --context "$CONTEXT" --namespace "$NAMESPACE" --release "$RELEASE")

"${install[@]}"
"${verify[@]}" --exercise-lifecycle | tee "$log_dir/before.log"

# Snapshot existing application records BEFORE reinstall and before the second
# verifier creates any new accounts. SQL verification itself is transactional.
qs="${RELEASE}-quickstart"
records() {
  kubectl --context "$CONTEXT" -n "$NAMESPACE" exec "$qs-postgresql-0" -c postgresql -- \
    psql -X -U postgres -d permesi -tAc "SELECT count(*)||':'||coalesce(md5(string_agg(id::text||email::text||encode(opaque_registration_record,'hex'),',' ORDER BY id)),'empty') FROM users"
}
before_records="$(records)"
"${install[@]}"
[[ "$before_records" == "$(records)" ]] || { echo 'Existing user data changed across reinstall' >&2; exit 1; }
echo 'PASS: full-stack reinstall preserved existing user IDs, emails and OPAQUE records'
"${verify[@]}" | tee "$log_dir/after.log"
before="$(grep '^INFO: .*sha256' "$log_dir/before.log")"
after="$(grep '^INFO: .*sha256' "$log_dir/after.log")"
[[ -n "$before" && "$before" == "$after" ]] || { echo 'Cryptographic identity changed across reinstall' >&2; exit 1; }
echo 'PASS: full-stack reinstall preserved OPAQUE seed, CA and signing-key fingerprints'
echo 'real-dependencies.sh: PASS'
