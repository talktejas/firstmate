#!/usr/bin/env bash
# Live drive: a real firstmate home, the real watcher sweep, and a gh on PATH
# whose calls take the incident's measured wall-clock latencies (4-12s).
# Usage: drive-slow-link.sh <firstmate-root> <label> [extra env...]
set -u
ROOT=$1; LABEL=$2; shift 2
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
home=$(mktemp -d /tmp/fm-live-$LABEL.XXXXXX)
mkdir -p "$home"/{data/delivery,state,config,projects,fakebin,forge,root/bin,wt}
printf '# Backlog\n\n## Queued\n- [ ] delivery - Contribution https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' > "$home/data/backlog.md"
printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"; printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
printf 'worktree=%s/wt\nkind=ship\n' "$home" > "$home/state/delivery.meta"; chmod 600 "$home/state/delivery.meta"
# A maintainer review is waiting on the PR: the signal the incident says is missed.
printf '[{"id":77,"user":{"login":"maintainer"},"author_association":"OWNER","body":"Please rename the flag","html_url":"https://github.com/o/r/pull/8#pullrequestreview-77","submitted_at":"2026-09-21T08:01:00Z","commit_id":"%s","state":"CHANGES_REQUESTED"}]\n' "$HEAD_A" > "$home/forge/reviews.json"
cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
start=$(date +%s.%N)
case "$*" in
  'api repos/o/r/pulls/8') d=7.4; out=$(jq -n --arg h "$HEAD_A" '{state:"open",user:{login:"author"},head:{sha:$h},draft:false,mergeable:true,merged_at:null}') ;;
  'api repos/o/r/issues/8/comments?'*) d=5.0; out='[[]]' ;;
  'api repos/o/r/pulls/8/reviews?'*) d=12.2; out=$(jq -s . "$FORGE/reviews.json") ;;
  'api repos/o/r/pulls/8/comments?'*) d=6; out='[[]]' ;;
  'api repos/o/r/commits/'*'/check-runs?'*) d=8; out='[{"check_runs":[{"name":"test","id":1,"status":"completed","conclusion":"success","started_at":"2026-09-21T08:00:00Z"}]}]' ;;
  'api repos/o/r/commits/'*'/statuses?'*) d=4; out='[[]]' ;;
  'api repos/o/r') d=4; out='{"permissions":{"push":false}}' ;;
  'pr view '*) d=6; out=$(jq -n --arg h "$HEAD_A" '{headRefOid:$h,reviewDecision:"CHANGES_REQUESTED"}') ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
trap 'printf "%s\tKILLED after %.1fs\n" "$*" "$(echo "$(date +%s.%N) - $start" | bc)" >> "$FORGE/calls"' TERM
sleep "$d" & wait $!
trap - TERM
printf '%s\t%ss\n' "$*" "$d" >> "$FORGE/calls"
printf '%s\n' "$out"
SH
chmod +x "$home/fakebin/gh"
run() { PATH="$home/fakebin:$PATH" FORGE="$home/forge" HEAD_A="$HEAD_A" FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$@"; }
echo "HOME=$home"
run "$ROOT/bin/fm-contributions.sh" arm >/dev/null && echo "armed: $(ls "$home/state"/*.check.sh)"
sweep() {
  local t0=$(date +%s) rc=0
  : > "$home/forge/calls"
  run env "$@" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 170 > "$home/out" 2>&1 || rc=$?
  echo "--- watcher checkpoint exit=$rc after $(( $(date +%s) - t0 ))s; surfaced:"; grep -v '^$' "$home/out" | sed 's/^/    /'
  echo "--- forge calls (wall clock):"; sed 's/^/    /' "$home/forge/calls"
  echo "--- durable record:"; jq -c '.records[0] | {checked_at,error,head:.observation.head,review_decision:.observation.review_decision,pending:[.pending[].token],notified}' "$home/data/delivery/contributions.json" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  echo "--- wake queue lines: $(wc -l < "$home/state/.wake-queue" 2>/dev/null || echo 0)"
}
echo "=== sweep 1 ($*)"; sweep "$@"
echo "=== sweep 2 ($*)"; sweep "$@"
rm -rf "$home"
