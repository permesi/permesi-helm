#!/usr/bin/env bash
# Real-dependency integration gate (CI): runs the exact quickstart entry
# points (install.sh + verify.sh) against the current Kind context, with the
# canonical SQL tree from a read-only checkout of permesi/permesi at the
# locked commit. This is not a second bootstrap implementation.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "${REPO_ROOT}"

CONTEXT="${QS_CONTEXT:-$(kubectl config current-context)}"
NAMESPACE="${QS_NAMESPACE:-qs-ci}"
RELEASE="${QS_RELEASE:-permesi}"
APP_SOURCE="${QS_APP_SOURCE:-app}"
LOCKED_COMMIT="04783bc009cdef4e8ba71910c12ecbd25aa74dfd"

actual="$(git -C "${APP_SOURCE}" rev-parse HEAD)"
[[ "${actual}" == "${LOCKED_COMMIT}" ]] || { echo "app source is at ${actual}, expected locked ${LOCKED_COMMIT}" >&2; exit 1; }

echo "== install (context=${CONTEXT} namespace=${NAMESPACE} release=${RELEASE}) =="
bash scripts/quickstart/install.sh --context "${CONTEXT}" --namespace "${NAMESPACE}" \
  --release "${RELEASE}" --acknowledge-development --app-source "${APP_SOURCE}"

echo "== verify =="
bash scripts/quickstart/verify.sh --context "${CONTEXT}" --namespace "${NAMESPACE}" --release "${RELEASE}"

echo "== rerun install (idempotent: identity must not change) =="
before="$(bash scripts/quickstart/verify.sh --context "${CONTEXT}" --namespace "${NAMESPACE}" --release "${RELEASE}" | grep '^INFO: .*sha256' )"
bash scripts/quickstart/install.sh --context "${CONTEXT}" --namespace "${NAMESPACE}" \
  --release "${RELEASE}" --acknowledge-development --app-source "${APP_SOURCE}"
after="$(bash scripts/quickstart/verify.sh --context "${CONTEXT}" --namespace "${NAMESPACE}" --release "${RELEASE}" | grep '^INFO: .*sha256' )"
[[ -n "${before}" && "${before}" == "${after}" ]] || { echo "identity fingerprints changed across rerun" >&2; exit 1; }
echo "identity fingerprints unchanged across rerun"

echo "real-dependencies.sh: PASS"
