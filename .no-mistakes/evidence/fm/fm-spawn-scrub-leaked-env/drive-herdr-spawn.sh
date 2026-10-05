#!/usr/bin/env bash
# Live driver: real herdr lab server + real bin/fm-spawn.sh under a polluted
# launcher environment. Usage: drive-herdr-spawn.sh <checkout-root> <label>
set -u
ROOT=$1; LABEL=$2
NAMES='FM_CREW_STATE_META_OVERRIDE FM_CREW_STATE_STATUS_OVERRIDE FM_SESSION_START_STAGE_FILE FM_HOME_SUMMARY_IF_IDLE FM_HOME_SUMMARY_WORKER_BEST_EFFORT CLAUDE_CODE_CHILD_SESSION'
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-scrub-live.XXXXXX")
SESSION="fm-lab-scrub-$LABEL-$$"
export HERDR_SESSION="$SESSION"
WTS=
cleanup_all() {
  for w in $WTS; do treehouse return --force "$w" >/dev/null 2>&1; done
  herdr_safe_stop_and_delete "$SESSION"
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || { echo "lab prepare failed"; exit 1; }
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || exit 1

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
for id in cm1 cm2; do
  mkdir -p "$HOME_DIR/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nlive scrub check\n\n## Firstmate spec\nnone\n' > "$HOME_DIR/data/$id/brief.md"
done
PROJ="$TMP_ROOT/proj"; mkdir -p "$PROJ"; git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"; git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

# The "agent": records the environment it was actually started with.
cat > "$TMP_ROOT/agent.sh" <<EOF
#!/bin/sh
env > "$TMP_ROOT/agent-\$1.env"
EOF
chmod +x "$TMP_ROOT/agent.sh"

polluted() {
  FM_CREW_STATE_META_OVERRIDE=/tmp/fm-fleet-tasks.x/b2b.meta FM_CREW_STATE_STATUS_OVERRIDE=/tmp/fm-fleet-tasks.x/b2b.status \
  FM_SESSION_START_STAGE_FILE=/tmp/fm-session-start-stage.x FM_HOME_SUMMARY_IF_IDLE=0 \
  FM_HOME_SUMMARY_WORKER_BEST_EFFORT=1 CLAUDE_CODE_CHILD_SESSION=1 FM_SCRUB_SENTINEL=kept "$@"
}
report() {  # <title> <env-text>
  local n hit=
  for n in $NAMES; do
    printf '%s\n' "$2" | grep -q "^$n=" && hit="$hit $n"
  done
  printf '%s\n' "$2" | grep -q '^FM_SCRUB_SENTINEL=kept' && s=present || s=absent
  printf '  %-58s leaked:%s | unrelated sentinel: %s\n' "$1" "${hit:- none}" "$s"
}
server_env() {
  local pid
  pid=$(pgrep -f "herdr.* server .*--session $SESSION|herdr server --session $SESSION" | head -1)
  [ -n "$pid" ] && tr '\0' '\n' < "/proc/$pid/environ"
}
spawn() {  # <id>
  FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$1" "$PROJ" "$TMP_ROOT/agent.sh $1" --mode no-mistakes --yolo off --backend herdr \
    >"$TMP_ROOT/$1.out" 2>"$TMP_ROOT/$1.err" || { echo "spawn $1 failed"; cat "$TMP_ROOT/$1.out" "$TMP_ROOT/$1.err"; return 1; }
  WTS="$WTS $(grep '^worktree=' "$HOME_DIR/state/$1.meta" | cut -d= -f2-)"
  for _ in $(seq 1 40); do [ -s "$TMP_ROOT/agent-$1.env" ] && return 0; sleep 0.25; done
  echo "agent $1 never ran"; return 1
}

echo "== [$LABEL] $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo base-archive) | herdr $(herdr --version | awk '{print $2}') | session $SESSION"
echo "-- A: fm-spawn run from a polluted command scope starts the Herdr server and launches an agent"
polluted spawn cm1 || exit 1
SENV=$(server_env)
[ -n "$SENV" ] || { echo "could not read the lab server's environment"; exit 1; }
report "long-lived Herdr server process (/proc/<pid>/environ)" "$SENV"
report "launched agent process" "$(cat "$TMP_ROOT/agent-cm1.env")"

echo "-- B: the server is ALREADY polluted (started by hand that way); fm-spawn runs from a clean scope"
fm_herdr_lab_stop "$SESSION" >/dev/null 2>&1; sleep 0.5
( polluted env HERDR_SESSION="$SESSION" herdr server --session "$SESSION" >/dev/null 2>&1 & )
for _ in $(seq 1 40); do
  [ "$(herdr status --json --session "$SESSION" 2>/dev/null | jq -r '.server.running // false')" = true ] && break; sleep 0.25
done
report "long-lived Herdr server process (deliberately polluted)" "$(server_env)"
( for n in $NAMES FM_SCRUB_SENTINEL; do unset "$n"; done; spawn cm2 ) || exit 1
WTS="$WTS $(grep '^worktree=' "$HOME_DIR/state/cm2.meta" | cut -d= -f2-)"
report "launched agent process" "$(cat "$TMP_ROOT/agent-cm2.env")"

echo "-- C: fm-crew-state.sh reads the live task cm2 (real pane, real records in this home)"
printf 'working: implementation continues\n' >> "$HOME_DIR/state/cm2.status"
mkdir -p "$TMP_ROOT/capture"; cp "$HOME_DIR/state/cm2.meta" "$TMP_ROOT/capture/cm2.meta"
printf 'working: captured generation\n' > "$TMP_ROOT/capture/cm2.status"
crew() {  # <title> [NAME=value...]
  local title=$1; shift
  echo "  $title"
  ( for n in $NAMES; do unset "$n"; done; for a in "$@"; do export "${a?}"; done
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" timeout 90 "$ROOT/bin/fm-crew-state.sh" cm2 2>"$TMP_ROOT/crew.err" | sed 's/^/     stdout: /'
    sed "s|$TMP_ROOT|<tmp>|g; s/^/     stderr: /" "$TMP_ROOT/crew.err" )
}
crew "clean environment"
crew "inherited pair naming another task's vanished snapshot (the reported shape)" \
  FM_CREW_STATE_META_OVERRIDE=/tmp/fm-fleet-tasks.gone/b2b.meta FM_CREW_STATE_STATUS_OVERRIDE=/tmp/fm-fleet-tasks.gone/b2b.status
crew "adversarial: only the metadata half, pointing at this task's capture" FM_CREW_STATE_META_OVERRIDE="$TMP_ROOT/capture/cm2.meta"
crew "fleet snapshot's own captured pair for this task (must still be honored)" \
  FM_CREW_STATE_META_OVERRIDE="$TMP_ROOT/capture/cm2.meta" FM_CREW_STATE_STATUS_OVERRIDE="$TMP_ROOT/capture/cm2.status"
