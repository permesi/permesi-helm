#!/usr/bin/env bash
# Development-only foreground port-forwards. Exports PUBLIC root CA only;
# never modifies host trust or disables certificate verification.
set -euo pipefail
CONTEXT="" NAMESPACE=permesi-quickstart RELEASE=permesi CA_OUT=quickstart-ca.pem
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="${2:?}"; shift 2 ;;
    --namespace) NAMESPACE="${2:?}"; shift 2 ;;
    --release) RELEASE="${2:?}"; shift 2 ;;
    --ca-out) CA_OUT="${2:?}"; shift 2 ;;
    -h|--help) echo 'Usage: connect.sh --context NAME [--namespace NS] [--release NAME] [--ca-out FILE]'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$CONTEXT" ]] || { echo '--context is required' >&2; exit 2; }
K=(kubectl --context "$CONTEXT" -n "$NAMESPACE")
fullname() { if [[ "$1" == *"$2"* ]]; then echo "$1"; else echo "$1-$2"; fi; }
qs="${RELEASE}-quickstart"
helper_settings="$(helm --kube-context "$CONTEXT" -n "$NAMESPACE" get values "$qs" --all -o json \
  | python3 "$(dirname "${BASH_SOURCE[0]}")/settings.py" --fullname "$qs" --namespace "$NAMESPACE" --lines)"
mapfile -t helper_fields <<< "$helper_settings"
"${K[@]}" exec "deploy/${helper_fields[3]}" -c vault -- vault read -field=certificate pki-root/cert/ca > "$CA_OUT"
[[ -s "$CA_OUT" ]] || { echo 'Failed to export public root CA' >&2; exit 1; }
echo "Public root CA: $CA_OUT (import explicitly into a disposable browser profile; no host trust changes)"
pids=()
cleanup() { for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT
forward() {
  "${K[@]}" port-forward --address 127.0.0.1 "svc/$1" "$2:8080" &
  pids+=("$!")
  echo "$3"
}
forward "$(fullname "${RELEASE}-web" web)" 8080 'Web: http://localhost:8080'
forward "$(fullname "$RELEASE" permesi)" 8443 'API: https://api.localhost:8443'
forward "$(fullname "${RELEASE}-genesis" genesis)" 9443 'Genesis: https://genesis.localhost:9443'
echo 'Resolve api.localhost and genesis.localhost to 127.0.0.1; curl can use --resolve. Ctrl-C stops all forwards.'
# Exit if any forward dies; EXIT trap stops the others.
wait -n "${pids[@]}"
