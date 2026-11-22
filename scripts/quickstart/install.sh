#!/usr/bin/env bash
# Permesi quickstart installer (DEVELOPMENT ONLY).
#
# Installs disposable PostgreSQL + dev Vault, waits for ordered bootstrap, then
# installs Genesis, Permesi and web. Backend pods use native Vault Agents:
# Kubernetes auth, Unix proxy sockets and in-memory TLS files; no app Secrets.
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
DEPS_ONLY=false
PKI_TTL=24h
VALUES_TMP=""

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
  --deps-only                Bootstrap dependencies without application charts.
  --pki-ttl <duration>        Backend leaf TTL (default: 24h; CI rotation: 2m).
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
    --deps-only) DEPS_ONLY=true; shift ;;
    --pki-ttl) PKI_TTL="${2:?}"; shift 2 ;;
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
for t in helm kubectl python3; do command -v "${t}" >/dev/null || die "${t} not found on PATH"; done

lock() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); print(v["images"][sys.argv[2]][sys.argv[3]])' "${SCRIPT_DIR}/lock.json" "$1" "$2"; }
# repository:tag@digest is a standard OCI reference, compatible with the
# component charts before and after addition of a dedicated image.digest key.
locked_tag() { printf '%s@%s' "$(lock "$1" tag)" "$(lock "$1" digest)"; }

# --- Derived names (one place; everything else uses these) -----------------
# Helm fullname rule: release if it contains the chart name, else release-chart.
fullname() { if [[ "$1" == *"$2"* ]]; then echo "$1"; else echo "$1-$2"; fi; }
QS_RELEASE="${RELEASE}-quickstart"
QS_FULLNAME="${QS_RELEASE}"
PERMESI_RELEASE="${RELEASE}"
PERMESI_NAME="$(fullname "${PERMESI_RELEASE}" permesi)"
GENESIS_RELEASE="${RELEASE}-genesis"
GENESIS_NAME="$(fullname "${GENESIS_RELEASE}" genesis)"

CREATED_CLUSTER=false
CREATED_NAMESPACE=false

on_exit() {
  local rc=$?
  [[ -z "${VALUES_TMP}" ]] || rm -rf -- "${VALUES_TMP}"
  if [[ "${CLEANUP}" == "true" ]]; then
    if [[ "${CREATED_CLUSTER}" == "true" ]]; then
      log "cleanup: deleting Kind cluster ${KIND_CLUSTER} (created by this invocation)"
      kind delete cluster --name "${KIND_CLUSTER}" || true
    elif [[ "${CREATED_NAMESPACE}" == "true" ]]; then
      # Uninstall while release metadata still exists, removing the
      # cluster-scoped TokenReview grant before namespace deletion.
      helm --kube-context "${CONTEXT}" uninstall "${QS_RELEASE}" -n "${NAMESPACE}" >/dev/null 2>&1 || true
      log "cleanup: deleting namespace ${NAMESPACE} (created by this invocation)"
      kubectl --context "${CONTEXT}" delete namespace "${NAMESPACE}" --wait=false || true
    else
      log "cleanup: no namespace/cluster was created; leaving existing resources untouched"
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

# Render the effective switch (including all --quickstart-values overrides)
# before namespace/SQL ConfigMap mutation. Pregranted installations need no
# cluster-scoped creation rights; namespaced credential RBAC remains enabled.
qs_values=()
for f in "${QS_VALUES[@]}"; do qs_values+=(-f "${f}"); done
rbac_manifest="$("${H[@]}" template "${QS_RELEASE}" "${QS_CHART}" -n "${NAMESPACE}" \
  --set acknowledgeDevelopment=true --set-string "fullnameOverride=${QS_FULLNAME}" \
  "${qs_values[@]}")" \
  || die "cannot render dependency RBAC preflight"
if [[ "$rbac_manifest" == *$'\nkind: ClusterRoleBinding\n'* ]]; then
  for resource in clusterroles.rbac.authorization.k8s.io clusterrolebindings.rbac.authorization.k8s.io; do
    [[ "$("${K[@]}" auth can-i create "$resource")" == yes ]] \
      || die "cannot create ${resource}; ask a cluster administrator to pregrant tokenreviews.create to system:serviceaccount:${NAMESPACE}:${QS_FULLNAME}-vault ONLY, then set rbac.createTokenReviewBinding=false in --quickstart-values"
  done
fi

if "${K[@]}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  [[ "$CLEANUP" != true ]] || die "--cleanup requires a new namespace; refusing to remove resources from existing ${NAMESPACE}"
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
QS_ARGS=(--set-string "postgresql.image.digest=$(lock postgresql digest)"
         --set-string "vault.image.digest=$(lock vault digest)")
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
if ! "${H[@]}" upgrade --install "${QS_RELEASE}" "${QS_CHART}" -n "${NAMESPACE}" \
    --set acknowledgeDevelopment=true \
    --set-string "fullnameOverride=${QS_FULLNAME}" \
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

if [[ "${DEPS_ONLY}" != true ]]; then
  VALUES_TMP="$(mktemp -d)"
  helper_settings="$("${H[@]}" -n "$NAMESPACE" get values "$QS_RELEASE" --all -o json \
    | python3 "$SCRIPT_DIR/settings.py" --fullname "$QS_FULLNAME" --namespace "$NAMESPACE" --lines)" \
    || die "cannot resolve effective dependency settings"
  mapfile -t helper_fields <<< "$helper_settings"
  pg_host="${helper_fields[1]}"
  pg_port="${helper_fields[2]}"
  vault_address="${helper_fields[4]}"
  for svc in genesis permesi; do
    if [[ "$svc" == genesis ]]; then app_release="$GENESIS_RELEASE"; app_name="$GENESIS_NAME"; else app_release="$PERMESI_RELEASE"; app_name="$PERMESI_NAME"; fi
    cat > "${VALUES_TMP}/${svc}.yaml" <<EOF
replicaCount: 2
serviceAccount:
  automount: false
  name: "${app_name}"
database:
  dsn:
    value: "postgres://placeholder@${pg_host}:${pg_port}/${svc}?sslmode=disable"
vault:
  agent:
    enabled: true
    image:
      tag: "$(locked_tag vault)"
    address: "${vault_address}"
    auth:
      role: "${svc}"
    pki:
      role: "${svc}-runtime"
      commonName: "${app_name}.${NAMESPACE}.svc.cluster.local"
      dnsNames: ["${app_name}", "${app_name}.${NAMESPACE}", "${app_name}.${NAMESPACE}.svc", "${app_name}.${NAMESPACE}.svc.cluster.local", "$(if [[ "$svc" == permesi ]]; then echo api.localhost; else echo genesis.localhost; fi)"]
      ttl: "${PKI_TTL}"
EOF
    if [[ "$svc" == genesis ]]; then
      cat >> "${VALUES_TMP}/${svc}.yaml" <<'EOF'
extraEnv:
  - {name: GENESIS_ADMISSION_ISS, value: "https://genesis.localhost:9443"}
  - {name: GENESIS_ADMISSION_AUD, value: "permesi"}
EOF
    else
      cat >> "${VALUES_TMP}/${svc}.yaml" <<EOF
admission:
  paserkUrl: "https://${GENESIS_NAME}.${NAMESPACE}.svc.cluster.local:8080/paserk.json"
  issuer: "https://genesis.localhost:9443"
  audience: "permesi"
auth:
  frontendBaseUrl: "http://localhost:8080"
  corsAllowedOrigins: "http://localhost:8080"
  opaqueServerId: "api.localhost"
extraEnv:
  - {name: PERMESI_EMAIL_DELIVERY, value: "outbox"}
  - {name: PERMESI_SIGNUP_MODE, value: "restricted"}
  - {name: PERMESI_SIGNUP_ALLOWED_DOMAINS, value: "example.test"}
  - {name: PERMESI_SIGNUP_DEVELOPMENT_DOMAINS, value: "example.test"}
EOF
    fi
    log "installing ${svc} (${app_release}, two replicas, native Agent)"
    "${H[@]}" upgrade --install "$app_release" "${CHARTS_DIR}/${svc}" -n "$NAMESPACE" \
      -f "${VALUES_TMP}/${svc}.yaml" \
      --set-string "image.repository=$(lock "$svc" repository)" \
      --set-string "image.tag=$(lock "$svc" tag)" --set-string "image.digest=$(lock "$svc" digest)" \
      --wait --timeout "${TIMEOUT}s"
  done
  "${H[@]}" upgrade --install "${RELEASE}-web" "${CHARTS_DIR}/web" -n "$NAMESPACE" \
    --set-string "image.repository=$(lock web repository)" \
    --set-string "image.tag=$(lock web tag)" --set-string "image.digest=$(lock web digest)" \
    --set runtimeConfig.apiBaseUrl=https://api.localhost:8443 \
    --set runtimeConfig.tokenBaseUrl=https://genesis.localhost:9443 \
    --set-string runtimeConfig.clientId=00000000-0000-0000-0000-000000000000 \
    --set runtimeConfig.opaqueServerId=api.localhost --wait --timeout "${TIMEOUT}s"
fi
log "done. Verify: bash scripts/quickstart/verify.sh --context ${CONTEXT} --namespace ${NAMESPACE} --release ${RELEASE}"
