#!/usr/bin/env bash
# Live drive of the routine-wake triage: a real bin/fm-watch.sh process over an
# isolated firstmate home, a real tmux server on a private socket, the real
# bin/fm-pr-state.sh reading real GitHub pull requests, and real Jev calls.
# Usage: live-drive.sh <repo-root> <label> <agent: exited|running|missing> <pr-url-or-empty> <status-line>...
set -u
ROOT=$1 LABEL=$2 AGENT=$3 PR=$4; shift 4
KEY_HOME=${KEY_HOME:-/home/tds/p/firstmate}
D=$(mktemp -d /tmp/fm-live-XXXXXX)
mkdir -p "$D/state" "$D/config" "$D/tmux" "$D/agentbin"
export TMUX_TMPDIR="$D/tmux"; unset TMUX
# A stand-in agent: a process the backend's own classifier names as the claude harness.
printf '#!/bin/bash\nwhile :; do sleep 1000; done\n' > "$D/agentbin/claude"; chmod +x "$D/agentbin/claude"
case "$AGENT" in
  exited)  tmux new-session -d -s fmlive -n fm-park -x 120 -y 30 'exec bash --norc' ;;
  running) tmux new-session -d -s fmlive -n fm-park -x 120 -y 30 "exec $D/agentbin/claude" ;;
  missing) tmux new-session -d -s fmlive -n other -x 120 -y 30 'exec bash --norc' ;;
esac
sleep 1
. "$ROOT/bin/fm-backend.sh" 2>/dev/null
{ printf 'window=fmlive:fm-park\nkind=ship\n'; [ -z "$PR" ] || printf 'pr=%s\n' "$PR"; } > "$D/state/park.meta"
printf '%s\n' "$@" > "$D/state/park.status"
touch -d "@$(( $(date +%s) - 14520 ))" "$D/state/park.status"
printf '### %s\n' "$LABEL"
printf 'watcher: %s @ %s\n' "$ROOT/bin/fm-watch.sh" "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || cat "$ROOT/.rev")"
printf 'agent state read by the backend: %s\n' "$(fm_backend_agent_state tmux fmlive:fm-park)"
[ -z "$PR" ] || printf 'pull request read (%s): [%s]\n' "$PR" "$("$ROOT/bin/fm-pr-state.sh" "$PR" 2>&1 | tr '\n' '|')"
printf 'newest status: %s\n' "$(tail -n 1 "$D/state/park.status")"
run() {  # <seconds> [env...]
  local secs=$1; shift
  env FM_HOME="$D" FM_STATE_OVERRIDE="$D/state" FM_CONFIG_OVERRIDE="$D/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" \
    timeout "$secs" "$ROOT/bin/fm-watch.sh" > "$D/watch.out" 2> "$D/watch.err"
  printf 'exit=%s\n' "$?"
}
# Run 1, no key: the paused: status line is delivered as the news it is.
printf -- '-- run 1 (no key; the new paused: line is reported): '; run 25
sed 's/^/   stdout: /' "$D/watch.out"
cp "$D/state/.wake-queue" "$D/queue.1" 2>/dev/null || : > "$D/queue.1"
: > "$D/state/.watch-triage.log"
# Run 2, with the key: the successor watcher meets the stale recheck.
KEY=$(sed -n 's/^TYPESAFE_API_KEY=//p' "$KEY_HOME/.env" | head -n 1)
printf -- '-- run 2 (key present; the stale recheck; 124 = still watching, nothing delivered): '
run "${RUN2_SECS:-25}" TYPESAFE_API_KEY="$KEY" FM_WATCH_HANDLING_SUCCESSOR=1
sed 's/^/   stdout: /' "$D/watch.out"
printf '   wake-queue lines added: %s\n' "$(( $(wc -l < "$D/state/.wake-queue" 2>/dev/null || echo 0) - $(wc -l < "$D/queue.1") ))"
printf '   triage log:\n'; sed 's/^/     /' "$D/state/.watch-triage.log"
grep -Fq "$KEY" -r "$D/state" "$D/watch.out" "$D/watch.err" 2>/dev/null && printf '   KEY LEAKED INTO STATE OR OUTPUT\n'
tmux kill-server 2>/dev/null
[ -n "${KEEP:-}" ] && printf 'kept %s\n' "$D" || rm -rf "$D"
echo
