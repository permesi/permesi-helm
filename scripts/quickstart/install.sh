#!/usr/bin/env bash
# Permesi quickstart installer (DEVELOPMENT ONLY).
#
# Installs the disposable dependency chart scripts/quickstart/chart
# (PostgreSQL 18 + dev Vault + ordered bootstrap Job) and waits for the
# bootstrap to succeed.
#
# Every kubectl/helm call is pinned to the explicit --context; the kubeconfig
# current-context is never changed. Never deletes a cluster or namespace it did
# not create. Diagnostics never print Secret data, tokens or key material.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
QS_CHART="${SCRIPT_DIR}/chart"

CONTEXT=""
KIND_CLUSTER=""
NAMESPACE=""
RELEASE="permesi"
ACK=false
APP_SOURCE=""
CHARTS_DIR="${REPO_ROOT}/charts"
ALLOW_DIRTY=false
CLEANUP=false
TIMEOUT=900
QS_VALUES=()

usage() {
  cat <<'EOF'
Usage: bash scripts/quickstart/install.sh --acknowledge-development \
         (--context <kube-context> | --kind <cluster-name>) [options]

  --context <name>           Existing kube context (required unless --kind).
  --kind <name>              Use, or create, a disposable Kind cluster.
  --namespace <ns>           Target namespace (default: permesi-quickstart).
                             Created with Restricted PSA if absent.
  --release <name>           Base release name (default: permesi).
  --acknowledge-development  Required: disposable development profile.
  --app-source <path>        Package <path>/db/sql into ConfigMaps (a clean git
                             checkout; --allow-dirty to accept anything else).
                             Default: the chart fetches the pinned archive.
  --charts-dir <path>        Application charts directory (default: repo charts/).
  --allow-dirty              Accept a dirty/non-git --app-source.
  --quickstart-values <file> Extra values for the dependency chart (repeatable).
  --timeout <seconds>        Per-stage wait (default: 900).
  --cleanup                  On exit, remove only what this invocation created.
EOF
}

die() { echo "install.sh: ERROR: $*" >&2; exit 1; }
log() { echo "install.sh: $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="${2:?}"; shift 2 ;;
    --kind) KIND_CLUSTER="${2:?}"; shift 2 ;;
    --namespace) NAMESPACE="${2:?}"; shift 2 ;;
    --release) RELEASE="${2:?}"; shift 2 ;;
    --acknowledge-development) ACK=true; shift ;;
    --app-source) APP_SOURCE="${2:?}"; shift 2 ;;
    --charts-dir) CHARTS_DIR="${2:?}"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=true; shift ;;
    --quickstart-values) QS_VALUES+=("${2:?}"); shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    --cleanup) CLEANUP=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ "${ACK}" == "true" ]] || die "--acknowledge-development is required (disposable development profile, NOT for production)"
[[ -n "${CONTEXT}" || -n "${KIND_CLUSTER}" ]] || die "an explicit --context or --kind is required"
[[ -z "${CONTEXT}" || -z "${KIND_CLUSTER}" ]] || die "--context and --kind are mutually exclusive"
NAMESPACE="${NAMESPACE:-permesi-quickstart}"
[[ "${RELEASE}" =~ ^[a-z]([-a-z0-9]{0,28}[a-z0-9])?$ ]] || die "--release must be a DNS label of at most 30 characters"
[[ "${TIMEOUT}" =~ ^[0-9]+$ ]] || die "--timeout must be an integer number of seconds"
[[ -d "${CHARTS_DIR}" ]] || die "--charts-dir ${CHARTS_DIR} not found"
for f in "${QS_VALUES[@]}"; do [[ -f "${f}" ]] || die "values file not found: ${f}"; done
for t in helm kubectl; do command -v "${t}" >/dev/null || die "${t} not found on PATH"; done

# --- Derived names (one place; everything else uses these) -----------------
# Helm fullname rule: release if it contains the chart name, else release-chart.
fullname() { if [[ "$1" == *"$2"* ]]; then echo "$1"; else echo "$1-$2"; fi; }
QS_RELEASE="${RELEASE}-quickstart"
QS_FULLNAME="$(fullname "${QS_RELEASE}" permesi-quickstart)"
PERMESI_RELEASE="${RELEASE}"
PERMESI_NAME="$(fullname "${PERMESI_RELEASE}" permesi)"
GENESIS_RELEASE="${RELEASE}-genesis"
GENESIS_NAME="$(fullname "${GENESIS_RELEASE}" genesis)"

CREATED_CLUSTER=false
CREATED_NAMESPACE=false

on_exit() {
  local rc=$?
  if [[ "${CLEANUP}" == "true" ]]; then
    if [[ "${CREATED_CLUSTER}" == "true" ]]; then
      log "cleanup: deleting Kind cluster ${KIND_CLUSTER} (created by this invocation)"
      kind delete cluster --name "${KIND_CLUSTER}" || true
    elif [[ "${CREATED_NAMESPACE}" == "true" ]]; then
      log "cleanup: deleting namespace ${NAMESPACE} (created by this invocation)"
      kubectl --context "${CONTEXT}" delete namespace "${NAMESPACE}" --wait=false || true
      # Cluster-scoped TokenReview grant is Helm-owned; uninstall removes it.
      helm --kube-context "${CONTEXT}" uninstall "${QS_RELEASE}" -n "${NAMESPACE}" >/dev/null 2>&1 || true
    else
      log "cleanup: namespace ${NAMESPACE} pre-existed; uninstalling only this invocation's releases"
      helm --kube-context "${CONTEXT}" uninstall "${QS_RELEASE}" -n "${NAMESPACE}" --wait || true
      kubectl --context "${CONTEXT}" -n "${NAMESPACE}" delete secret,configmap \
        -l "app.kubernetes.io/instance=${QS_RELEASE},app.kubernetes.io/name=permesi-quickstart" || true
    fi
  elif [[ ${rc} -ne 0 ]]; then
    log "failed (exit ${rc}); resources left in namespace ${NAMESPACE} for diagnosis"
  fi
  exit "${rc}"
}
trap on_exit EXIT

# --- Cluster / context -------------------------------------------------------
if [[ -n "${KIND_CLUSTER}" ]]; then
  command -v kind >/dev/null || die "kind not found (required for --kind)"
  if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER}"; then
    log "using existing Kind cluster ${KIND_CLUSTER} (never deleted by this script)"
  else
    log "creating Kind cluster ${KIND_CLUSTER}"
    kind create cluster --name "${KIND_CLUSTER}" --wait 5m
    CREATED_CLUSTER=true
  fi
  CONTEXT="kind-${KIND_CLUSTER}"
fi
kubectl config get-contexts "${CONTEXT}" >/dev/null 2>&1 || die "kube context '${CONTEXT}' not found"
K=(kubectl --context "${CONTEXT}")
H=(helm --kube-context "${CONTEXT}")
"${K[@]}" version --request-timeout=20s >/dev/null || die "cluster for context '${CONTEXT}' is unreachable"
log "context=${CONTEXT} namespace=${NAMESPACE} release=${RELEASE}"
log "names: dependencies=${QS_FULLNAME} permesi=${PERMESI_NAME} genesis=${GENESIS_NAME}"

if "${K[@]}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  enforce="$("${K[@]}" get namespace "${NAMESPACE}" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
  [[ "${enforce}" == "restricted" ]] || log "WARNING: existing namespace ${NAMESPACE} does not enforce Restricted PSA"
else
  "${K[@]}" create namespace "${NAMESPACE}" >/dev/null
  CREATED_NAMESPACE=true
  "${K[@]}" label namespace "${NAMESPACE}" \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=latest >/dev/null
  log "created namespace ${NAMESPACE} (Restricted PSA enforced)"
fi

# --- Schema source -----------------------------------------------------------
QS_ARGS=()
if [[ -n "${APP_SOURCE}" ]]; then
  sql_dir="${APP_SOURCE%/}/db/sql"
  [[ -f "${sql_dir}/00_init.sql" ]] || die "${sql_dir}/00_init.sql not found"
  revision="$(git -C "${APP_SOURCE}" rev-parse HEAD 2>/dev/null || true)"
  dirty="$(git -C "${APP_SOURCE}" status --porcelain -- db/sql 2>/dev/null || echo unknown)"
  if [[ -z "${revision}" || -n "${dirty}" ]]; then
    [[ "${ALLOW_DIRTY}" == "true" ]] || die "--app-source is not a clean git checkout; pass --allow-dirty to use it anyway"
    revision="${revision:-unknown}-dirty"
    log "WARNING: using dirty/unknown app source (${revision})"
  fi
  log "app SQL source ${sql_dir} revision=${revision}"

  # Split *.sql into ConfigMaps of at most 512 KiB (API object limit 1 MiB).
  mapfile -t sql_files < <(find "${sql_dir}" -maxdepth 1 -type f -name '*.sql' | LC_ALL=C sort)
  cms=() ; batch=() ; batch_bytes=0
  flush() {
    local name="${QS_FULLNAME}-sql-${#cms[@]}" args=() f
    for f in "${batch[@]}"; do args+=("--from-file=${f}"); done
    "${K[@]}" -n "${NAMESPACE}" create configmap "${name}" "${args[@]}" --dry-run=client -o yaml \
      | "${K[@]}" -n "${NAMESPACE}" apply -f - >/dev/null
    "${K[@]}" -n "${NAMESPACE}" label configmap "${name}" --overwrite \
      app.kubernetes.io/name=permesi-quickstart app.kubernetes.io/instance="${QS_RELEASE}" \
      app.kubernetes.io/component=sql-schema >/dev/null
    "${K[@]}" -n "${NAMESPACE}" annotate configmap "${name}" --overwrite \
      permesi.dev/schema-revision="${revision}" >/dev/null
    cms+=("${name}"); batch=(); batch_bytes=0
  }
  for f in "${sql_files[@]}"; do
    size="$(wc -c < "${f}")"
    (( size < 524288 )) || die "${f} exceeds the per-ConfigMap budget"
    if (( ${#batch[@]} > 0 && batch_bytes + size > 524288 )); then flush; fi
    batch+=("${f}"); batch_bytes=$((batch_bytes + size))
  done
  (( ${#batch[@]} > 0 )) && flush
  # Remove stale schema ConfigMaps from a previous, larger split.
  while read -r cm; do
    [[ -z "${cm}" || " ${cms[*]} " == *" ${cm} "* ]] || "${K[@]}" -n "${NAMESPACE}" delete configmap "${cm}" >/dev/null
  done < <("${K[@]}" -n "${NAMESPACE}" get configmap -o name \
            -l "app.kubernetes.io/instance=${QS_RELEASE},app.kubernetes.io/component=sql-schema" | sed 's#^configmap/##')
  log "packaged ${#sql_files[@]} SQL files into: ${cms[*]}"
  cm_json="$(printf '"%s",' "${cms[@]}")"
  QS_ARGS+=(--set bootstrap.schema.sourceUrl= --set bootstrap.schema.sha256=
            --set "bootstrap.schema.revision=${revision}"
            --set-json "bootstrap.schema.existingConfigMaps=[${cm_json%,}]")
fi

# --- Dependencies + ordered bootstrap ----------------------------------------
diagnose_bootstrap() {
  log "diagnostics (sanitized: workload states, events, bootstrap logs)"
  "${K[@]}" -n "${NAMESPACE}" get pods,jobs -l "app.kubernetes.io/instance=${QS_RELEASE}" -o wide || true
  "${K[@]}" -n "${NAMESPACE}" get events --sort-by=.lastTimestamp | tail -n 25 || true
  local job
  job="$("${K[@]}" -n "${NAMESPACE}" get jobs -l "app.kubernetes.io/instance=${QS_RELEASE},app.kubernetes.io/component=bootstrap" \
          --sort-by=.metadata.creationTimestamp -o name | tail -n 1)"
  [[ -n "${job}" ]] && "${K[@]}" -n "${NAMESPACE}" logs "${job}" --all-containers --tail=40 || true
}

log "installing dependency chart ${QS_RELEASE} (PostgreSQL + dev Vault + bootstrap)"
qs_values=()
for f in "${QS_VALUES[@]}"; do qs_values+=(-f "${f}"); done
if ! "${H[@]}" upgrade --install "${QS_RELEASE}" "${QS_CHART}" -n "${NAMESPACE}" \
    --set acknowledgeDevelopment=true \
    --set "bootstrap.services.permesi.serviceName=${PERMESI_NAME}" \
    --set "bootstrap.services.genesis.serviceName=${GENESIS_NAME}" \
    --set "bootstrap.kubernetesRoles.permesi.serviceAccount=${PERMESI_NAME}" \
    --set "bootstrap.kubernetesRoles.genesis.serviceAccount=${GENESIS_NAME}" \
    "${QS_ARGS[@]}" "${qs_values[@]}" \
    --wait --wait-for-jobs --timeout "${TIMEOUT}s"; then
  diagnose_bootstrap
  die "dependency install/bootstrap failed"
fi
revision_no="$("${H[@]}" -n "${NAMESPACE}" history "${QS_RELEASE}" --max 1 -o json | sed -n 's/.*"revision":\([0-9][0-9]*\).*/\1/p')"
boot_job="${QS_FULLNAME}-bootstrap-${revision_no}"
succeeded="$("${K[@]}" -n "${NAMESPACE}" get job "${boot_job}" -o jsonpath='{.status.succeeded}')"
[[ "${succeeded}" == "1" ]] || { diagnose_bootstrap; die "bootstrap Job ${boot_job} did not succeed"; }
log "bootstrap Job ${boot_job} succeeded"
log "done. Verify: bash scripts/quickstart/verify.sh --context ${CONTEXT} --namespace ${NAMESPACE} --release ${RELEASE}"
