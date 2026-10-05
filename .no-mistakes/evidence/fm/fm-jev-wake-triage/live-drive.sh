#!/usr/bin/env bash
# Live drive of bin/fm-watch.sh routine-wake triage: real watcher process, real
# tmux server (isolated socket dir), real fm-crew-state.sh, real fm-pr-state.sh
# (gh), real curl through a recording pass-through. No fakes for the product.
# Usage: live-drive.sh <worktree> <scenario> <pr-url-or-empty> [env assignments...]
set -u
ROOT=$1; NAME=$2; PR=$3; shift 3
. "$ROOT/tests/wake-helpers.sh" >/dev/null
D=$(mktemp -d "/tmp/fm-live-$NAME.XXXXXX")
mkdir -p "$D/state" "$D/config" "$D/bin" "$D/tmux"
REAL_CURL=$(command -v curl)
cat > "$D/bin/curl" <<SH
#!/usr/bin/env bash
# pass-through recorder: logs the URL argv only, then runs the real curl
for a in "\$@"; do case "\$a" in http*) printf '%s\n' "\$a" >> "$D/curl-calls" ;; esac; done
exec "$REAL_CURL" \${LIVE_CURL_EXTRA:-} "\$@"
SH
chmod +x "$D/bin/curl"
# stand-in harness: a long-lived process whose name the product classifies as an agent
printf '#!/bin/bash\nprintf "idle at the prompt\\n"\nwhile :; do read -r -t 600 _; done\n' > "$D/bin/claude"
chmod +x "$D/bin/claude"
export TMUX_TMPDIR="$D/tmux"; unset TMUX
tmux new-session -d -s test -n fm-park -x 120 -y 30 "$D/bin/claude"
sleep 1
metaargs=("window=test:fm-park" "kind=ship")
[ -z "$PR" ] || metaargs+=("pr=$PR")
fm_write_meta "$D/state/park.meta" "${metaargs[@]}"
printf 'working: implementing\n' > "$D/state/park.status"
prime_status_seen "$D/state" "$D/state/park.status"
printf 'paused: PR is open and green, waiting for the merge\n' >> "$D/state/park.status"
run() {  # <out> [env...]
  local out=$1; shift
  env PATH="$D/bin:$PATH" FM_HOME="$D" FM_STATE_OVERRIDE="$D/state" FM_CONFIG_OVERRIDE="$D/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" \
    timeout 60 "$ROOT/bin/fm-watch.sh" > "$out" 2>"$out.err"
  echo "watcher exit=$?"
}
echo "=== scenario: $NAME  pr=${PR:-<none>}  env: $(printf '%s ' "$@" | sed 's/TYPESAFE_API_KEY=[^ ]*/TYPESAFE_API_KEY=<set>/')"
echo "--- agent state seen by product: $(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux test:fm-park' _ "$ROOT")"
echo "--- run 1 (first sight of the new paused: line)"
run "$D/run1.out" "$@"
echo "stdout: $(cat "$D/run1.out")"
echo "curl calls so far: $(cat "$D/curl-calls" 2>/dev/null || echo none)"
echo "--- run 2 (successor watcher: stale recheck of the same paused worker)"
run "$D/run2.out" FM_WATCH_HANDLING_SUCCESSOR=1 "$@"
echo "stdout: $(cat "$D/run2.out")"
echo "--- wake queue"; cat "$D/state/.wake-queue" 2>/dev/null
echo "--- triage log"; cat "$D/state/.watch-triage.log" 2>/dev/null
echo "--- curl calls: $(cat "$D/curl-calls" 2>/dev/null || echo none)"
echo "--- streak file: $(cat "$D/state/.jev-triage-streak-park" 2>/dev/null || echo absent)"
tmux kill-server 2>/dev/null
echo "dir=$D"
