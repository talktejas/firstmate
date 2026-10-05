#!/usr/bin/env bash
# Live drive of the routine-wake triage: a real fm-watch.sh process, a real tmux
# pane whose agent has exited (an idle shell), the real bin/fm-pr-state.sh
# reading a real GitHub pull request, and the real Jev model. Only the firstmate
# home is isolated (a temp dir) and the tmux server is private (TMUX_TMPDIR).
# Usage: drive-live.sh <bin-dir> <case> <pr-url> <key:yes|no> <status-line>...
set -u
BIN=$1 CASE=$2 PR=$3 USEKEY=$4; shift 4
REPO=$(cd "$BIN/.." && pwd)
REAL_HOME_ENV=/home/tds/p/firstmate/.env
D=$(mktemp -d "/tmp/jev-live-$CASE.XXXXXX")
mkdir -p "$D/state" "$D/config" "$D/tmux" "$D/root"
export TMUX_TMPDIR="$D/tmux"; unset TMUX TMUX_PANE
task=jt-live
tmux new-session -d -s jevlive -n "fm-$task" -x 120 -y 30 'env PS1="exited$ " bash --norc --noprofile'
sleep 1
printf 'window=jevlive:fm-%s\nkind=ship\npr=%s\n' "$task" "$PR" > "$D/state/$task.meta"
printf '%s\n' "$@" > "$D/state/$task.status"
FM_STATE_OVERRIDE="$D/state" bash -c '. "$1/fm-wake-lib.sh"; fm_wake_status_mark_current "$2" "$3"' _ "$BIN" "$D/state" "$D/state/$task.status"
touch -d '@'$(( $(date +%s) - 14520 )) "$D/state/$task.status"
key=
if [ "$USEKEY" = yes ]; then key=$(sed -n 's/^TYPESAFE_API_KEY=//p' "$REAL_HOME_ENV" | head -1 | tr -d "\"'"); fi
echo "### case=$CASE bin=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '?') key=$USEKEY"
echo "### meta:"; cat "$D/state/$task.meta"
echo "### status:"; cat "$D/state/$task.status"
echo "### agent state read by the product: $(bash -c '. "$1/fm-backend.sh"; fm_backend_agent_state tmux "$2"' _ "$BIN" "jevlive:fm-$task" 2>&1)"
echo "### real pull-request read (fm-pr-state.sh):"; "$BIN/fm-pr-state.sh" "$PR" | sed 's/^/    /'
env ${key:+TYPESAFE_API_KEY="$key"} FM_HOME="$D" FM_ROOT_OVERRIDE="$D/root" FM_STATE_OVERRIDE="$D/state" FM_CONFIG_OVERRIDE="$D/config" \
  FM_WEDGE_ALARM_EXEC=/bin/true FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_PAUSE_RESURFACE_SECS=600 FM_WATCH_HANDLING_SUCCESSOR=1 "$BIN/fm-watch.sh" > "$D/watch.out" 2> "$D/watch.err" &
pid=$!
i=0; outcome='still running after 45s'
while [ $i -lt 45 ]; do
  if ! kill -0 $pid 2>/dev/null; then outcome='watcher exited (a wake was delivered)'; break; fi
  if grep -q 'absorbed jev-routine' "$D/state/.watch-triage.log" 2>/dev/null; then
    sleep 8
    if kill -0 $pid 2>/dev/null; then outcome='watcher still supervising 8s after the absorb (no wake delivered)'; else outcome='watcher exited after an absorb'; fi
    break
  fi
  sleep 1; i=$((i+1))
done
kill $pid 2>/dev/null; wait $pid 2>/dev/null
echo "### outcome: $outcome"
echo "### watcher stdout (what the supervisor is woken with):"; sed 's/^/    /' "$D/watch.out"; [ -s "$D/watch.out" ] || echo "    (empty)"
echo "### wake queue:"; if [ -s "$D/state/.wake-queue" ]; then sed 's/^/    /' "$D/state/.wake-queue"; else echo "    (empty)"; fi
echo "### state/.watch-triage.log:"; sed 's/^/    /' "$D/state/.watch-triage.log" 2>/dev/null || echo "    (none)"
[ -s "$D/watch.err" ] && { echo "### stderr:"; sed 's/^/    /' "$D/watch.err"; }
if [ -n "$key" ] && grep -rqF "$key" "$D" 2>/dev/null; then echo "### KEY LEAKED INTO HOME"; else echo "### key not present in any home file"; fi
tmux kill-server 2>/dev/null
rm -rf "$D"
