#!/usr/bin/env bash
# Live drive of the registered contributions check (run exactly as the watcher
# runs it: timeout <bound> bash state/contributions.check.sh) at the incident's
# slow-link latencies, across repeated polls and operator settings.
# Usage: drive-poll-cases.sh <firstmate-root> <label>
set -u
. "$(dirname "$0")/slow-link-home.sh"
run "$ROOT/bin/fm-contributions.sh" arm >/dev/null
poll() { # title env...
  local title=$1 t0 rc=0; shift
  : > "$home/forge/calls"; t0=$(date +%s)
  run env "$@" timeout 138 bash "$home/state/contributions.check.sh" > "$home/out" 2>&1 || rc=$?
  echo "=== $title  [env: $*]"
  echo "    exit=$rc after $(( $(date +%s) - t0 ))s; forge calls=$(wc -l < "$home/forge/calls") (killed: $(grep -c KILLED "$home/forge/calls"))"
  if [ -s "$home/out" ]; then sed 's/^/    output: /' "$home/out"; else echo "    output: (silent - no wake line)"; fi
  jq -c '.records[0] | {error,observed:(.observation.head != null),pending:[.pending[].token],notified}' "$home/data/delivery/contributions.json" 2>/dev/null | sed 's/^/    record: /'
  echo "    wake queue lines: $(wc -l < "$home/state/.wake-queue" 2>/dev/null || echo 0)"
}
case "$LABEL" in
base)
  poll 'base poll 1 (defaults)'
  poll 'base poll 2 (defaults)'
  poll 'base: raise FM_CONTRIBUTIONS_BUDGET (reporter tried this)' FM_CONTRIBUTIONS_BUDGET=25 ;;
head)
  poll 'per-call bound 5s (old hard-coded value) poll 1' FM_CONTRIBUTIONS_CALL_TIMEOUT=5
  poll 'per-call bound 5s poll 2 (same failure episode)' FM_CONTRIBUTIONS_CALL_TIMEOUT=5
  poll 'defaults restored (per-call 15s)'
  poll 'immediate re-poll (inside freshness window)'
  jq '.records[0].notified = []' "$home/data/delivery/contributions.json" > "$home/x" && mv "$home/x" "$home/data/delivery/contributions.json"
  : > "$home/state/.wake-queue"
  poll 'record fresh but its review signal never got a wake (notified cleared, queue emptied)'
  poll 'expired freshness window (MAX_AGE=0)' FM_CONTRIBUTIONS_MAX_AGE=0
  poll 'budget too small for one PR, poll 1' FM_CONTRIBUTIONS_MAX_AGE=0 FM_CONTRIBUTIONS_BUDGET=20
  poll 'budget too small for one PR, poll 2' FM_CONTRIBUTIONS_MAX_AGE=0 FM_CONTRIBUTIONS_BUDGET=20
  poll 'check bound 30s, budget unset' FM_CONTRIBUTIONS_MAX_AGE=0 FM_CONTRIBUTIONS_CHECK_TIMEOUT=30
  poll 'invalid per-call timeout' FM_CONTRIBUTIONS_CALL_TIMEOUT=abc
  poll 'zero per-call timeout' FM_CONTRIBUTIONS_CALL_TIMEOUT=0 ;;
esac
rm -rf "$home"
