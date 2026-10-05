#!/usr/bin/env bash
# fm-finding-sort.sh - advisory sort of a task's ask-user review findings with
# typesafe.ai's System One model (Jev), opt-in.
#
# Usage:
#   fm-finding-sort.sh <task-id>
#
# Run by firstmate from .agents/skills/ask-user-authority/SKILL.md, which owns
#   what a printed sort means for the decision. The worker that reported the
#   gate never runs it.
#
# Opt-in gate, both halves required: TYPESAFE_API_KEY is available under the
#   same environment-then-$FM_HOME/.env contract as bin/fm-dispatch-resolve.sh,
#   and the task's project (the last path component of `project=` in
#   state/<task-id>.meta) is a line of config/jev-code-projects, because a
#   finding names the project's files and may quote its code. bin/fm-jev-lib.sh
#   owns the key handling, that opt-in, the request, and the answer validation,
#   and is the only Jev caller here.
#
# What it does when on: code decides every fact first. It takes the task's
#   newest `ask-user findings=<ids> file=<path>` line from state/<task-id>.status
#   and requires the file to be a regular nm-*-findings.txt directly inside
#   data/<task-id>/ of at most FINDING_SORT_MAX_BYTES bytes, and a
#   `## Captain's intent` in data/<task-id>/brief.md of at most
#   FINDING_SORT_MAX_BYTES characters. Nothing is cut to fit: anything over the
#   bound is left by hand.
#   Only then does ONE request through fm_jev_choices ask, per named id,
#   one Choice question over the intent and the findings file: inside-task,
#   grows-task, style-only, or destructive.
#
# Output: one line per finding id on stdout, either
#     <id>: settle (<inside-task|style-only>, confidence <c>)
#   only when that choice's confidence reaches the shared
#   FM_JEV_CONFIDENCE_FLOOR, or
#     <id>: by hand (<why>)
#   for every other answer, and one summary line on stderr.
#
# Authority: advice only. Every outcome exits 0 - no key, no opt-in, no gate
#   line, an unusable file, a timeout, a malformed answer, low confidence - and
#   nothing here answers a gate, steers a worker, or writes any record; a
#   failure means every finding is by hand, as without the feature. Exit 2 only
#   for a usage error.
set -u

# Sourced before anything can start a child: it takes the key out of the
# exported environment. The path is derived with builtins for the same reason.
_fm_sort_dir=${BASH_SOURCE[0]%/*}
[ "$_fm_sort_dir" != "${BASH_SOURCE[0]}" ] || _fm_sort_dir=.
# shellcheck source=bin/fm-jev-lib.sh
. "$_fm_sort_dir/fm-jev-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$_fm_sort_dir/fm-dod-lib.sh"

FINDING_SORT_MAX_BYTES=20000
# shellcheck disable=SC2016 # Backticks are literal Markdown for the model.
FINDING_SORT_INSTRUCTIONS='`intent` is what was asked for. `findings` lists code review findings on the work done for it. Sort only the finding whose id is `%s`, by what fixing it would mean. Do not judge whether the finding is correct. Choose `grows-task` whenever no other choice clearly fits or you are unsure.'
# shellcheck disable=SC2016
FINDING_SORT_CRITERIA='{
  "inside-task": "Fixing it corrects the work `intent` asked for - a defect, an omission, a missing or wrong test, or inaccurate documentation of that work - and adds no new guarantee, behaviour, or component beyond it.",
  "grows-task": "Fixing it would add something `intent` did not ask for - a new guarantee, threat model, subsystem, abstraction, compatibility layer, monitoring, or general framework - or needs a product or architecture choice `intent` leaves open.",
  "style-only": "It is only about naming, formatting, wording, comments, or code layout, and fixing it changes no behaviour.",
  "destructive": "Fixing it deletes or overwrites data or history, cannot be undone, or changes credentials, permissions, authentication, or another security-sensitive choice."
}'

finding_sort_usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

finding_sort_main() {
  local id='' fm_root line ids file dir project intent tmp i settled=0 why
  local all=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) finding_sort_usage; return 0 ;;
      -*) echo "error: unknown argument $1 (see --help)" >&2; return 2 ;;
      *)
        [ -z "$id" ] || { echo "error: more than one task id given (see --help)" >&2; return 2; }
        id=$1; shift ;;
    esac
  done
  case "$id" in
    ''|*[!A-Za-z0-9._-]*|.*) echo "error: a task id is required (see --help)" >&2; return 2 ;;
  esac
  fm_root=$(cd "$_fm_sort_dir/.." && pwd)
  FM_HOME=${FM_HOME:-$fm_root}

  line=$(grep -E 'ask-user findings=[^ ]+ file=.' "$FM_HOME/state/$id.status" 2>/dev/null | tail -n 1)
  if [ -z "$line" ]; then
    echo "finding-sort: nothing to sort (no ask-user findings line in $FM_HOME/state/$id.status)" >&2
    return 0
  fi
  ids=${line#*ask-user findings=}
  file=${ids#* file=}
  ids=${ids%% file=*}
  IFS=, read -r -a all <<<"$ids"
  # Every exit below this point leaves each named finding by hand.
  by_hand() {  # <why>
    local f
    for f in "${all[@]}"; do printf '%s: by hand (%s)\n' "$f" "$1"; done
    echo "finding-sort: 0 of ${#all[@]} finding(s) sorted as settle; $1" >&2
    return 0
  }

  if ! fm_jev_key_load "$FM_HOME"; then
    by_hand "off, TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env"; return
  fi
  project=$(sed -n 's/^project=//p' "$FM_HOME/state/$id.meta" 2>/dev/null | head -n 1)
  project=${project##*/}
  if ! fm_jev_code_allowed "$project"; then
    by_hand "off, project \"$project\" is not a line of ${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/jev-code-projects"; return
  fi
  command -v jq >/dev/null 2>&1 || { by_hand "jq not installed"; return; }

  dir=$FM_HOME/data/$id
  case "$file" in
    "$dir"/nm-*-findings.txt) ;;
    *) by_hand "the findings file is not an nm-*-findings.txt in $dir"; return ;;
  esac
  case "${file#"$dir"/}" in
    */*) by_hand "the findings file is not directly inside $dir"; return ;;
  esac
  if [ -L "$file" ] || [ ! -f "$file" ] || [ ! -s "$file" ]; then
    by_hand "the findings file is missing, empty, or not a regular file"; return
  fi
  if [ "$(wc -c < "$file")" -gt "$FINDING_SORT_MAX_BYTES" ]; then
    by_hand "the findings file is over $FINDING_SORT_MAX_BYTES bytes"; return
  fi
  intent=$(fm_brief_task_heading_body "$dir/brief.md" "## Captain's intent")
  if [ -z "$(printf '%s' "$intent" | tr -d '[:space:]')" ]; then
    by_hand "no Captain's intent in $dir/brief.md"; return
  fi
  if [ "${#intent}" -gt "$FINDING_SORT_MAX_BYTES" ]; then
    by_hand "the Captain's intent is over $FINDING_SORT_MAX_BYTES characters"; return
  fi
  tmp=$(mktemp -d) || { by_hand "mktemp failed"; return; }
  FINDING_SORT_TMP=$tmp
  jq -n --arg intent "$intent" --rawfile findings "$file" '{intent: $intent, findings: $findings}' > "$tmp/state"
  # The instruction template is a constant that carries one %s.
  # shellcheck disable=SC2059
  for i in "${!all[@]}"; do
    jq -n --arg k "f$i" --arg t "$(printf "$FINDING_SORT_INSTRUCTIONS" "${all[$i]}")" \
      --argjson c "$FINDING_SORT_CRITERIA" '{($k): {instructions: $t, criteria: $c}}'
  done | jq -s add > "$tmp/questions"
  if ! fm_jev_choices "$tmp/questions" "$tmp/state" f0; then
    rm -rf "$tmp"
    by_hand "no answer: $FM_JEV_ERROR"; return
  fi
  rm -rf "$tmp"

  for i in "${!all[@]}"; do
    why=$(jq -r --arg k "f$i" --argjson floor "$FM_JEV_CONFIDENCE_FLOOR" '
      .answers[$k] as $a
      | if $a == null then "by hand (no usable answer)"
        elif $a.choice != "inside-task" and $a.choice != "style-only"
        then "by hand (\($a.choice), confidence \($a.confidence))"
        elif $a.confidence >= $floor
        then "settle (\($a.choice), confidence \($a.confidence))"
        else "by hand (\($a.choice) below the confidence floor, \($a.confidence))" end' <<<"$FM_JEV_ANSWERS")
    case "$why" in settle*) settled=$((settled + 1)) ;; esac
    printf '%s: %s\n' "${all[$i]}" "$why"
  done
  echo "finding-sort: $settled of ${#all[@]} finding(s) sorted as settle from ${#all[@]} question(s) in one request; advice only" >&2
  return 0
}

FINDING_SORT_TMP=
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  trap '[ -z "$FINDING_SORT_TMP" ] || rm -rf "$FINDING_SORT_TMP"' EXIT
  finding_sort_main "$@"
  exit
fi
