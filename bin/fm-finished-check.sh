#!/usr/bin/env bash
# fm-finished-check.sh - the worker stop hook's "is it really finished?" check.
# Usage: fm-finished-check.sh <home> <state-dir> <task-id> <worktree>   (Stop hook JSON on stdin)
#
# bin/fm-spawn.sh runs this first in a Claude worker's Stop hook. It prints
# either nothing (the turn ends exactly as it does without the check) or one
# Claude Stop decision, {"decision":"block","reason":"<one line>"}, which sends
# the worker back with what is missing. It always exits 0.
#
# Off unless TYPESAFE_API_KEY is available (environment, then <home>/.env;
# bin/fm-jev-lib.sh owns the key handling and the one Jev request). Code decides
# the facts first, and every send-back needs BOTH a code fact and a Jev `yes` at
# or above the shared confidence floor, so the model alone never holds a worker:
#
#   code fact                                          Jev question (yes/no)
#   a done: line was appended this turn                partial_or_blocked
#   no check-like command ran this turn                claims_checks_passed
#   no state was reported this turn                    asks_question
#   no state was reported this turn                    partial_or_blocked
#   no state was reported and files changed this turn  claims_finished
#
# Questions are asked in that order and the first mismatch wins. Nothing is
# asked, and the turn ends, when the key is absent; the stop already follows a
# send-back (stop_hook_active); background tasks are still running; there is no
# closing message; the turn's start is unreadable; or the worker reported
# needs-decision, blocked, paused, or failed this turn. A Jev timeout, error, or
# malformed answer ends the turn at once; a `no` or a low-confidence answer
# means no mismatch for that question.
#
# "This turn" is everything since the busy-state record opened the turn
# (bin/fm-busy-lib.sh). Each call sends the closing message cut to 4000
# characters and nothing else: no shell command, brief, file content, or diff.
# The operator-facing contract is docs/configuration.md "Finished check".

_FM_FC_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_FC_DIR" != "${BASH_SOURCE[0]}" ] || _FM_FC_DIR=.
# Sourced before anything can start a child, so no child inherits the key.
# shellcheck source=bin/fm-jev-lib.sh
. "$_FM_FC_DIR/fm-jev-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$_FM_FC_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_FC_DIR/fm-classify-lib.sh"

# ponytail: a word list stands in for "a check ran"; it only ever withholds the
# checks question, so a miss costs a missed catch, never a wrong send-back.
FM_FC_CHECK_CMD_RE='test|spec|lint|check|build|compile|tsc|make|verify|no-mistakes|(^|[^a-z])ci([^a-z]|$)'

FM_FC_INSTRUCTIONS='closing_message is the last message a software worker wrote before stopping its turn. Answer only from its words. Choose no whenever you are unsure.'

_fm_fc_criteria() {  # <question-key> -> its yes/no criteria JSON
  case "$1" in
    partial_or_blocked) printf '%s' '{"yes":"The message says some of the requested work is not done, was skipped or left for later, or that the worker is blocked or could not proceed.","no":"The message does not say work remains or that the worker is blocked, or it is unclear."}' ;;
    claims_checks_passed) printf '%s' '{"yes":"The message states that tests, lint, a build, or other checks passed or were run successfully.","no":"The message makes no such claim, or it is unclear."}' ;;
    asks_question) printf '%s' '{"yes":"The message asks someone to choose, confirm, approve, or answer something before the worker continues.","no":"The message asks nothing that the worker is waiting on, or it is unclear."}' ;;
    claims_finished) printf '%s' '{"yes":"The message claims the assigned work is finished, complete, or ready.","no":"The message does not claim the work is finished, or it is unclear."}' ;;
  esac
}

# 0 yes at or above the floor; 1 no or low confidence; 2 no usable answer.
_fm_fc_yes() {  # <question-key> <state-json>
  fm_jev_choice "$1" "$FM_FC_INSTRUCTIONS" <(printf '%s' "$2") <(_fm_fc_criteria "$1") || return 2
  jq -e --argjson floor "$FM_JEV_CONFIDENCE_FLOOR" \
    '.choice == "yes" and .confidence >= $floor and .probabilities.yes >= $floor' \
    >/dev/null 2>&1 <<<"$FM_JEV_ANSWER"
}

fm_finished_check() {  # <home> <state-dir> <task-id> <worktree>
  local home=$1 state=$2 id=$3 wt=$4
  local input msg rec ts transcript commands verb='' done_reported=0 unreported=0 changed=0
  local msg_state check key fact line rc
  fm_jev_key_load "$home" || return 0
  command -v jq >/dev/null 2>&1 || return 0
  input=$(cat)
  jq -e '.stop_hook_active != true and ((.background_tasks // []) | length) == 0' \
    >/dev/null 2>&1 <<<"$input" || return 0
  msg=$(jq -r '(.last_assistant_message // "") | tostring | .[0:4000]' 2>/dev/null <<<"$input")
  [ -n "$msg" ] || return 0

  rec=$(fm_busy_record_path "$state" "$id")
  case "$(fm_busy_record_read "$state" "$id" 2>/dev/null)" in busy\ *) : ;; *) return 0 ;; esac
  ts=$(sed -n 's/.* ts=\([0-9][0-9]*\).*/\1/p' "$rec" 2>/dev/null)
  [ -n "$ts" ] || return 0

  if [ "$state/$id.status" -nt "$rec" ]; then
    status_line_verb "$(tail -n 1 "$state/$id.status" 2>/dev/null)" verb
  fi
  case "$verb" in
    needs-decision | blocked | paused | failed) return 0 ;;
    done) done_reported=1 ;;
    *) unreported=1 ;;
  esac
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null | head -n 1)" ] \
    || [ -n "$(git -C "$wt" log -1 --since="$ts" --format=%h 2>/dev/null)" ]; then
    changed=1
  fi
  # The shell commands since the turn's last typed prompt, kept on this
  # machine; empty when the transcript is unreadable, which withholds the
  # checks question.
  transcript=$(jq -r '.transcript_path // ""' 2>/dev/null <<<"$input")
  commands=$(jq -cs '
    (map(.type == "user" and ((.message.content | type) == "string"
        or any(.message.content[]?; .type == "text"))) | rindex(true) // 0) as $start
    | [.[$start:][] | select(.type == "assistant") | .message.content[]?
       | select(.type == "tool_use" and .name == "Bash") | (.input.command // "")]' "$transcript" 2>/dev/null) || commands=

  msg_state=$(jq -cn --arg m "$msg" '{closing_message: $m}')
  for check in done_partial claims_checks_passed asks_question partial_or_blocked claims_finished; do
    fact=0 line='' key=$check
    case "$check:$done_reported:$unreported" in
      done_partial:1:*)
        fact=1 key=partial_or_blocked
        line='you reported done:, but your closing message says work is partial or blocked; finish it, or append the true state (blocked: or needs-decision:) to the status file.'
        ;;
      claims_checks_passed:*)
        if [ -n "$commands" ] && ! jq -r '.[]' <<<"$commands" | grep -Eiq "$FM_FC_CHECK_CMD_RE"; then
          fact=1
          line='your closing message says checks passed, but no test or check command ran this turn; run them, or say which earlier run you rely on.'
        fi
        ;;
      asks_question:*:1)
        fact=1
        line='your closing message asks a question, but nobody was told; append needs-decision: with the question to the status file, or decide and continue.'
        ;;
      partial_or_blocked:*:1)
        fact=1
        line='your closing message says work is partial or blocked, but you reported no state; continue, or append blocked: (or paused: for a wait that clears on its own) with the reason to the status file.'
        ;;
      claims_finished:*:1)
        fact=$changed
        line='your closing message says the work is finished, but you reported no state; if the definition of done is met append the done: line to the status file, otherwise say what remains.'
        ;;
    esac
    [ "$fact" -eq 1 ] || continue
    _fm_fc_yes "$key" "$msg_state"
    rc=$?
    [ "$rc" -ne 2 ] || return 0
    [ "$rc" -eq 0 ] || continue
    jq -cn --arg reason "Firstmate finished check: $line" '{decision: "block", reason: $reason}'
    return 0
  done
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -eq 4 ] || { echo "usage: fm-finished-check.sh <home> <state-dir> <task-id> <worktree>" >&2; exit 0; }
  fm_finished_check "$@"
  exit 0
fi
