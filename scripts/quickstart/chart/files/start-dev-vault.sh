#!/usr/bin/env sh
# Keep only Vault's credential banner out of pod logs; never spool raw output.
set -eu
umask 077
work="$(mktemp -d)"
server_pid=""
filter_pid=""
pending_signal=""
cleanup() {
  rc=$?
  trap - EXIT TERM INT
  if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid" 2>/dev/null || :
    wait "$server_pid" 2>/dev/null || :
  fi
  if [ -n "$filter_pid" ]; then wait "$filter_pid" || rc=1; fi
  rm -rf "$work"
  exit "$rc"
}
forward() {
  pending_signal="$1"
  if [ -n "$server_pid" ]; then kill -"$1" "$server_pid" 2>/dev/null || :; fi
}
trap cleanup EXIT
trap 'forward TERM' TERM
trap 'forward INT' INT
mkfifo "$work/output"
# The pipe contains raw bytes only in kernel memory. Flush useful diagnostics
# immediately, including startup errors; discard only the two banner labels.
awk '/^[[:space:]]*(Root Token|Unseal Key):/ { next } { print; fflush() }' < "$work/output" &
filter_pid=$!
vault server -dev -dev-listen-address=0.0.0.0:8200 -dev-no-store-token "$@" > "$work/output" 2>&1 &
server_pid=$!
if [ -n "$pending_signal" ]; then kill -"$pending_signal" "$server_pid" 2>/dev/null || :; fi
# A trapped signal interrupts wait. Re-wait until the actual server has exited,
# retaining its status rather than the shell's interrupted-wait status.
while :; do
  rc=0
  wait "$server_pid" || rc=$?
  kill -0 "$server_pid" 2>/dev/null || break
done
server_pid=""
exit "$rc"
