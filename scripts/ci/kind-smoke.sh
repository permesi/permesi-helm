#!/usr/bin/env bash
# Kind smoke checks for the Permesi Helm charts.
#
# Requires a reachable cluster in the current kube context with `helm` and
# `kubectl` on PATH. Exports the base (pre-change) web chart from git so the
# upgrade path can be exercised, then installs the working-tree charts under
# the Restricted Pod Security Standard.
set -euo pipefail

BASE_REF="${BASE_REF:-origin/main}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

WEB_VALUES="scripts/ci/kind-smoke-web-values.yaml"

NS_UPGRADE="kind-smoke-upgrade"          # unrestricted: base -> working-tree web upgrade
NS_WEB_RESTRICTED="kind-smoke-web-restricted" # restricted: working-tree web must become Ready
NS_PERMESI="kind-smoke-permesi"          # restricted
NS_GENESIS="kind-smoke-genesis"          # restricted
NAMESPACES=("$NS_UPGRADE" "$NS_WEB_RESTRICTED" "$NS_PERMESI" "$NS_GENESIS")

BASE_DIR=""
PF_PID=""

FAILURES=0

cleanup() {
    [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
    [[ -n "$BASE_DIR" ]] && rm -rf -- "$BASE_DIR" 2>/dev/null || true
    for ns in "${NAMESPACES[@]}"; do
        kubectl delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
die_check() { echo "FAIL: $*"; exit 1; }

echo "BASE_REF=${BASE_REF}"
echo "kube context: $(kubectl config current-context)"

##############################################################################
# Check 1: upgrade compatibility (base chart -> working-tree chart)
##############################################################################
echo
echo "== Check 1: upgrade compatibility (base ${BASE_REF} -> working tree) =="

BASE_DIR="$(mktemp -d)"
git archive "$BASE_REF" charts/web | tar -x -C "$BASE_DIR" || die_check "export base web chart from ${BASE_REF}"

kubectl create namespace "$NS_UPGRADE" >/dev/null || die_check "create namespace ${NS_UPGRADE}"

helm install web "$BASE_DIR/charts/web" -n "$NS_UPGRADE" -f "$WEB_VALUES" --wait --timeout 5m >/dev/null \
    || die_check "install base web chart from ${BASE_REF}"
pass "base web chart installed (2 replicas, --wait)"

selector_before="$(kubectl get deployment web -n "$NS_UPGRADE" -o jsonpath='{.spec.selector.matchLabels}')" \
    || die_check "read Deployment selector before upgrade"

helm upgrade web charts/web -n "$NS_UPGRADE" -f "$WEB_VALUES" --wait --timeout 5m >/dev/null \
    || die_check "upgrade web to working-tree chart"
kubectl rollout status deployment/web -n "$NS_UPGRADE" --timeout=180s >/dev/null \
    || die_check "web rollout complete after upgrade"

selector_after="$(kubectl get deployment web -n "$NS_UPGRADE" -o jsonpath='{.spec.selector.matchLabels}')" \
    || die_check "read Deployment selector after upgrade"

if [[ "$selector_before" == "$selector_after" ]]; then
    pass "Deployment selector unchanged after upgrade"
else
    fail "Deployment selector unchanged after upgrade (before='${selector_before}' after='${selector_after}')"
fi

##############################################################################
# Check 2: runtime-config rollout rolls pods and serves the new config
##############################################################################
echo
echo "== Check 2: runtime-config rollout =="

NEW_API_BASE_URL="https://api2.permesi.example.com"

checksum_before="$(kubectl get deployment web -n "$NS_UPGRADE" -o jsonpath='{.spec.template.metadata.annotations.checksum/runtime-config}')" \
    || die_check "read checksum/runtime-config annotation before upgrade"

helm upgrade web charts/web -n "$NS_UPGRADE" -f "$WEB_VALUES" \
    --set "runtimeConfig.apiBaseUrl=${NEW_API_BASE_URL}" --wait --timeout 5m >/dev/null \
    || die_check "upgrade web with new runtimeConfig.apiBaseUrl"
kubectl rollout status deployment/web -n "$NS_UPGRADE" --timeout=180s >/dev/null \
    || die_check "web rollout complete after runtime-config upgrade"

checksum_after="$(kubectl get deployment web -n "$NS_UPGRADE" -o jsonpath='{.spec.template.metadata.annotations.checksum/runtime-config}')" \
    || die_check "read checksum/runtime-config annotation after upgrade"

if [[ -n "$checksum_before" && -n "$checksum_after" && "$checksum_before" != "$checksum_after" ]]; then
    pass "checksum/runtime-config annotation changed (${checksum_before:0:12}... -> ${checksum_after:0:12}...)"
else
    fail "checksum/runtime-config annotation changed (before='${checksum_before}' after='${checksum_after}')"
fi

# Fetch /config.js through the Service (port 8080) and confirm the new URL.
PF_PORT=18080
kubectl port-forward -n "$NS_UPGRADE" "svc/web" "${PF_PORT}:8080" >/dev/null 2>&1 &
PF_PID=$!
config_js=""
for ((i = 0; i < 30; i++)); do
    if config_js="$(curl -fsS "http://127.0.0.1:${PF_PORT}/config.js" 2>/dev/null)"; then
        break
    fi
    sleep 1
done
kill "$PF_PID" 2>/dev/null || true
wait "$PF_PID" 2>/dev/null || true
PF_PID=""

if [[ -n "$config_js" ]] && grep -qF "$NEW_API_BASE_URL" <<<"$config_js"; then
    pass "/config.js via Service contains new runtimeConfig.apiBaseUrl (${NEW_API_BASE_URL})"
else
    fail "/config.js via Service contains new runtimeConfig.apiBaseUrl (got: ${config_js:-<empty>})"
fi

##############################################################################
# Check 3: Restricted Pod Security admission
##############################################################################
echo
echo "== Check 3: Restricted Pod Security =="

kubectl create namespace "$NS_WEB_RESTRICTED" >/dev/null || die_check "create namespace ${NS_WEB_RESTRICTED}"
kubectl label namespace "$NS_WEB_RESTRICTED" \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=latest >/dev/null \
    || die_check "label namespace ${NS_WEB_RESTRICTED} as restricted"

helm install web charts/web -n "$NS_WEB_RESTRICTED" -f "$WEB_VALUES" --wait --timeout 5m >/dev/null \
    || die_check "install working-tree web chart under Restricted PSA"
kubectl rollout status deployment/web -n "$NS_WEB_RESTRICTED" --timeout=180s >/dev/null \
    || die_check "web rollout complete under Restricted PSA"
pass "working-tree web chart Ready under Restricted PSA"

# Backends: install without --wait; pods must be admitted but will NOT become
# Ready (no Vault/DB/TLS in the smoke environment).
for chart in permesi genesis; do
    ns="kind-smoke-${chart}"
    kubectl create namespace "$ns" >/dev/null || die_check "create namespace ${ns}"
    kubectl label namespace "$ns" \
        pod-security.kubernetes.io/enforce=restricted \
        pod-security.kubernetes.io/enforce-version=latest >/dev/null \
        || die_check "label namespace ${ns} as restricted"

    helm install "$chart" "charts/$chart" -n "$ns" --set replicaCount=1 --timeout 5m >/dev/null \
        || die_check "install ${chart} chart under Restricted PSA"
    echo "note: ${chart} pods are not expected to become Ready (no Vault/DB/TLS)"

    pod_name=""
    for ((i = 0; i < 30; i++)); do
        pod_name="$(kubectl get pods -n "$ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        [[ -n "$pod_name" ]] && break
        sleep 1
    done

    if [[ -n "$pod_name" ]]; then
        pass "${chart}: Pod object exists under Restricted PSA (${pod_name})"
    else
        fail "${chart}: Pod object exists under Restricted PSA (none after ~30s)"
    fi

    events="$(kubectl get events -n "$ns" --field-selector reason=FailedCreate \
        -o custom-columns=MSG:.message --no-headers 2>/dev/null || true)"
    if echo "$events" | grep -qi 'PodSecurity'; then
        fail "${chart}: no FailedCreate events mentioning PodSecurity (got: $(echo "$events" | head -n1))"
    else
        pass "${chart}: no FailedCreate events mentioning PodSecurity"
    fi

    if [[ -n "$pod_name" ]]; then
        seccomp="$(kubectl get pod "$pod_name" -n "$ns" -o jsonpath='{.spec.securityContext.seccompProfile.type}' 2>/dev/null || true)"
        grace="$(kubectl get pod "$pod_name" -n "$ns" -o jsonpath='{.spec.terminationGracePeriodSeconds}' 2>/dev/null || true)"
        if [[ "$seccomp" == "RuntimeDefault" ]]; then
            pass "${chart}: pod seccompProfile.type=RuntimeDefault"
        else
            fail "${chart}: pod seccompProfile.type=RuntimeDefault (got '${seccomp}')"
        fi
        if [[ "$grace" == "60" ]]; then
            pass "${chart}: pod terminationGracePeriodSeconds=60"
        else
            fail "${chart}: pod terminationGracePeriodSeconds=60 (got '${grace}')"
        fi
    fi
done

##############################################################################
# Check 4: web PDB
##############################################################################
echo
echo "== Check 4: web PodDisruptionBudget =="

pdb_min="$(kubectl get pdb web -n "$NS_WEB_RESTRICTED" -o jsonpath='{.spec.minAvailable}' 2>/dev/null || true)"
if [[ "$pdb_min" == "1" ]]; then
    pass "web PDB exists with minAvailable=1"
else
    fail "web PDB exists with minAvailable=1 (got '${pdb_min:-<missing>}')"
fi

##############################################################################
echo
if [[ "$FAILURES" -eq 0 ]]; then
    echo "SMOKE RESULT: PASS (all checks passed)"
else
    echo "SMOKE RESULT: FAIL (${FAILURES} check(s) failed)"
fi
exit "$FAILURES"
