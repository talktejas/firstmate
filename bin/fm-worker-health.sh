#!/usr/bin/env bash
# fm-worker-health.sh - a task's deterministic current state, plus an advisory
# second line from typesafe.ai's System One model (Jev) when that read comes
# from a fallback source, opt-in.
#
# Usage:
#   fm-worker-health.sh <task-id>
#
# Run by firstmate from .agents/skills/stuck-crewmate-recovery/SKILL.md, which
#   owns what a printed health line means for the recovery. A worker never
#   runs it.
#
# Opt-in gate: TYPESAFE_API_KEY is available under the same
#   environment-then-$FM_HOME/.env contract as bin/fm-dispatch-resolve.sh.
#   bin/fm-jev-lib.sh owns the key handling, the request, and the answer
#   validation, and is the only Jev caller here. No project code, file list, or
#   diff is sent, so config/jev-code-projects is not consulted.
#
# What it does: code decides every fact first. It runs bin/fm-crew-state.sh
#   <task-id> and prints that one line unchanged, always. The model is asked
#   only when that line's source is `pane` or `status-log` - the two fallbacks
#   crew-state uses when no validation run speaks for the task - and the task
#   is a local ship or scout: a busy harness can be looping and an idle one can
#   be finished, waiting, or wedged, which is the judgement left over. A
#   `run-step` read, a gone or unreachable endpoint, a remote endpoint, and a
#   secondmate (whose idle endpoint is healthy) are never asked about.
#   ONE request through fm_jev_choice then asks one Choice question: working,
#   stuck, waiting, or finished.
#
# What is sent, and nothing else: the crew-state line, the task's kind, the
#   newest HEALTH_STATUS_LINES lines of state/<task-id>.status (a line over
#   HEALTH_LINE_MAX characters keeps its head and its end), whole minutes since
#   the status log, the turn-end marker, and the progress marker last changed,
#   and the count and oldest age of unacknowledged steering inbox messages.
#   Never the pane, never anything typed in the worker's shell, never the text
#   of an inbox message, the brief, or any file of the project.
#
# Output: the crew-state line on stdout, then, only for an answer whose
#   confidence reaches the shared FM_JEV_CONFIDENCE_FLOOR,
#     health: <working|stuck|waiting|finished> (confidence <c>, advice only)
#   and one summary line on stderr. Without the key stdout is the crew-state
#   line alone.
#
# Authority: advice only. Every outcome exits 0 - no key, a source code already
#   decided, a timeout, a malformed answer, low confidence - and nothing here
#   steers, interrupts, relaunches, or writes any record. Exit 2 only for a
#   usage error.
set -u

# Sourced before anything can start a child: it takes the key out of the
# exported environment. The path is derived with builtins for the same reason.
_fm_health_dir=${BASH_SOURCE[0]%/*}
[ "$_fm_health_dir" != "${BASH_SOURCE[0]}" ] || _fm_health_dir=.
# shellcheck source=bin/fm-jev-lib.sh
. "$_fm_health_dir/fm-jev-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$_fm_health_dir/fm-supervision-lib.sh"

HEALTH_STATUS_LINES=6
HEALTH_LINE_MAX=400
# shellcheck disable=SC2016 # Backticks are literal Markdown for the model.
HEALTH_INSTRUCTIONS='`worker` describes one software worker agent a supervisor is checking on. `current_state` is what a deterministic read found. `source: pane` means its tool is busy running something right now, or could not be read. `source: status-log` means its tool is idle right now - it is running nothing and will do nothing more until someone prompts it - and the rest of that line is its own last report. `status_events` are its own reports, oldest first, each starting with the UTC time it was written. The `minutes_since_*` fields say how long ago it last reported, last ended a turn, and last showed activity; null means never. `unread_instructions` counts supervisor messages it has not acknowledged. Decide what the worker is doing now. A busy tool on a long-running step is normal work. An idle tool whose last report says it was still working has stopped without saying why. A worker that asked for a decision or an answer is waiting, not stuck. Choose `working` whenever you are unsure.'
# shellcheck disable=SC2016
HEALTH_CRITERIA='{
  "working": "Its tool is busy, and nothing in its reports says it is waiting, blocked, or done.",
  "stuck": "It needs someone to look at it: its newest report says it is blocked on an obstacle or failed; or its tool is idle while its newest report says it was still working; or it has left a supervisor instruction unacknowledged for a long time.",
  "waiting": "Its newest report says it paused for, or needs, something outside itself - a decision, an answer, an approval, a review, a merge, a running check, a rate limit, a scheduled window - and nothing shows it has moved on since.",
  "finished": "Its newest report says the work is done or ready, and nothing shows it has started again since."
}'

health_usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

# The deterministic read this script extends.
health_crew_state() {  # <task-id>
  "$_fm_health_dir/fm-crew-state.sh" "$1"
}

# Whole minutes since <path> last changed, or null when it does not exist.
health_minutes_since() {  # <path>
  local m
  m=$(fm_sup_stat_mtime "$1") || m=''
  case "$m" in
    ''|*[!0-9]*) printf 'null' ;;
    *) printf '%s' $(( ($(date +%s) - m) / 60 )) ;;
  esac
}

health_main() {
  local id='' fm_root state line source kind f unread=0 oldest=null age evidence
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) health_usage; return 0 ;;
      -*) echo "error: unknown argument $1 (see --help)" >&2; return 2 ;;
      *)
        [ -z "$id" ] || { echo "error: more than one task id given (see --help)" >&2; return 2; }
        id=$1; shift ;;
    esac
  done
  case "$id" in
    ''|*[!A-Za-z0-9._-]*|.*) echo "error: a task id is required (see --help)" >&2; return 2 ;;
  esac
  fm_root=$(cd "$_fm_health_dir/.." && pwd)
  FM_HOME=${FM_HOME:-$fm_root}
  export FM_HOME
  state=${FM_STATE_OVERRIDE:-$FM_HOME/state}

  line=$(health_crew_state "$id" | head -n 1)
  [ -z "$line" ] || printf '%s\n' "$line"
  # Every exit below this point leaves the crew-state line as the whole answer.
  no_advice() {  # <why>
    echo "worker-health: no advice; $1" >&2
    return 0
  }

  source=$(printf '%s' "$line" | sed -n 's/^state: [a-z]* · source: \([a-z-]*\).*/\1/p')
  case "$source" in
    pane|status-log) ;;
    *) no_advice "code decided (source: ${source:-unreadable})"; return ;;
  esac
  kind=$(sed -n 's/^kind=//p' "$state/$id.meta" 2>/dev/null | head -n 1)
  kind=${kind:-ship}
  case "$kind" in
    ship|scout) ;;
    *) no_advice "code decided (kind=$kind is never asked about)"; return ;;
  esac
  if grep -q '^remote_host=.' "$state/$id.meta" 2>/dev/null; then
    no_advice "code decided (a remote endpoint is never asked about)"; return
  fi
  if ! fm_jev_key_load "$FM_HOME"; then
    no_advice "off, TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env"; return
  fi
  command -v jq >/dev/null 2>&1 || { no_advice "jq not installed"; return; }

  for f in "$state/$id.inbox"/*.msg; do
    [ -f "$f" ] || continue
    unread=$((unread + 1))
    age=$(health_minutes_since "$f")
    if [ "$age" != null ] && { [ "$oldest" = null ] || [ "$age" -gt "$oldest" ]; }; then oldest=$age; fi
  done
  evidence=$(tail -n "$HEALTH_STATUS_LINES" "$state/$id.status" 2>/dev/null \
    | jq -Rn --arg current "$line" --arg kind "$kind" --argjson max "$HEALTH_LINE_MAX" \
      --argjson status "$(health_minutes_since "$state/$id.status")" \
      --argjson turn "$(health_minutes_since "$state/$id.turn-ended")" \
      --argjson progress "$(health_minutes_since "$state/$id.progress")" \
      --argjson unread "$unread" --argjson oldest "$oldest" '
      {worker: {
        kind: $kind,
        current_state: $current,
        now: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
        status_events: [inputs | if length > $max
          then .[0:120] + " [...] " + .[(length - ($max - 127)):] else . end],
        minutes_since_last_status_event: $status,
        minutes_since_turn_ended: $turn,
        minutes_since_activity: $progress,
        unread_instructions: $unread,
        oldest_unread_instruction_minutes: $oldest
      }}' 2>/dev/null) || { no_advice "the evidence could not be built"; return; }

  if ! fm_jev_choice health "$HEALTH_INSTRUCTIONS" \
    <(printf '%s' "$evidence") <(printf '%s' "$HEALTH_CRITERIA"); then
    no_advice "no answer: $FM_JEV_ERROR"; return
  fi
  if ! jq -e --argjson floor "$FM_JEV_CONFIDENCE_FLOOR" '.confidence >= $floor' \
    >/dev/null 2>&1 <<<"$FM_JEV_ANSWER"; then
    no_advice "$FM_JEV_CHOICE is below the confidence floor ($FM_JEV_CONFIDENCE < $FM_JEV_CONFIDENCE_FLOOR)"; return
  fi
  printf 'health: %s (confidence %s, advice only)\n' "$FM_JEV_CHOICE" "$FM_JEV_CONFIDENCE"
  echo "worker-health: $FM_JEV_CHOICE from one question in one request ($FM_JEV_PROBABILITIES, ${FM_JEV_LATENCY_MS} ms); advice only" >&2
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  health_main "$@"
  exit
fi
