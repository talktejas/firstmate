#!/usr/bin/env bash
# fm-escalation-screen.sh - advisory screen of one question before it is put to
# the captain, with typesafe.ai's System One model (Jev), opt-in.
#
# Usage:
#   fm-escalation-screen.sh <question text>...
#   fm-escalation-screen.sh -            (question from stdin)
#
# Run by firstmate from AGENTS.md section 9, on the text of a question it is
#   about to ask: a worker's decision summary or one of its own. No worker runs
#   it. docs/configuration.md "Escalation screen" owns what a printed line means.
#
# Opt-in gate: TYPESAFE_API_KEY is available under the same
#   environment-then-$FM_HOME/.env contract as bin/fm-dispatch-resolve.sh.
#   bin/fm-jev-lib.sh owns the key handling, the credential-line filter, the
#   request, and the answer validation, and is the only Jev caller here. The
#   question's own words are the only thing sent; pass no code or diff in them.
#
# What it does when on: code decides every fact first, without a request.
#   - A review-gate line (`ask-user findings=`) is by hand: bin/fm-finding-sort.sh
#     and the ask-user-authority skill own it.
#   - A question over ESCALATION_SCREEN_MAX_CHARS characters is by hand, whole;
#     nothing is cut to fit.
#   - A question naming a merge, an approval, a destructive or irreversible act,
#     or a security-sensitive one (ESCALATION_SCREEN_CAPTAIN_WORDS) is the
#     captain's.
#   Only then does ONE fm_jev_choice request ask which kind of question it is:
#   trade, costly-to-undo, setting-with-default, cheap-to-reverse, or unclear.
#
# Output: exactly one line on stdout,
#     screen: yours (<setting-with-default|cheap-to-reverse>, confidence <c>)
#   only when that choice's confidence reaches the shared
#   FM_JEV_CONFIDENCE_FLOOR,
#     screen: captain's (<why>)
#   for the code rule above and for a trade or costly-to-undo answer at any
#   confidence, or
#     screen: by hand (<why>)
#   for everything else.
#
# Authority: advice only. Every outcome exits 0 - no key, a timeout, a
#   malformed answer, low confidence - and nothing here asks, answers, holds,
#   steers, or writes any record; `by hand` means firstmate judges the question
#   exactly as without the feature. Exit 2 only for a usage error.
set -u

# Sourced before anything can start a child: it takes the key out of the
# exported environment. The path is derived with builtins for the same reason.
_fm_screen_dir=${BASH_SOURCE[0]%/*}
[ "$_fm_screen_dir" != "${BASH_SOURCE[0]}" ] || _fm_screen_dir=.
# shellcheck source=bin/fm-jev-lib.sh
. "$_fm_screen_dir/fm-jev-lib.sh"

ESCALATION_SCREEN_MAX_CHARS=4000
# ponytail: a fixed word list, matched as whole words without regard to case.
# It only ever sends a question to the captain, so a miss costs nothing the
# model's own costly-to-undo choice does not cover; add a word when one slips.
ESCALATION_SCREEN_CAPTAIN_WORDS='merge|merges|merging|merged|approve|approval|delete|deletes|deleting|drop|discard|destroy|wipe|overwrite|force|force-push|irreversible|undone|credential|credentials|password|secret|permission|permissions|security'
# shellcheck disable=SC2016 # Backticks are literal Markdown for the model.
ESCALATION_SCREEN_INSTRUCTIONS='`question` is a question about a piece of software work that is about to be put to the owner of the business the software serves. Sort it by what a wrong answer would cost. Do not answer it. Choose `unclear` whenever no other choice clearly fits or you are unsure.'
ESCALATION_SCREEN_CRITERIA='{
  "trade": "It asks how the owner'"'"'s business or trade actually works, or a wrong answer would misprice a deal, pay or charge the wrong party, or misstate money, stock, tax, or a legal record.",
  "costly-to-undo": "A wrong answer is expensive to reverse: a name, identifier, or format that cannot change once shipped or shared, a choice that makes the work noticeably bigger, anything that deletes or overwrites data or history, a security-sensitive choice, or a merge, release, or approval.",
  "setting-with-default": "It asks which of several behaviours to use where different customers, countries, or installations could reasonably want different ones, so it can ship as a setting with a sensible default.",
  "cheap-to-reverse": "It is an implementation detail, wording, layout, or internal choice that can be changed later at little cost and that commits the business to nothing.",
  "unclear": "None of the others clearly fits, or the question does not say enough to tell."
}'

escalation_screen_usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

escalation_screen_main() {
  local question fm_root tmp
  case "${1-}" in
    -h|--help) escalation_screen_usage; return 0 ;;
    '') echo "error: a question is required (see --help)" >&2; return 2 ;;
  esac
  if [ "$1" = - ] && [ $# -eq 1 ]; then question=$(cat); else question="$*"; fi
  if [ -z "${question//[[:space:]]/}" ]; then
    echo "error: a question is required (see --help)" >&2; return 2
  fi
  fm_root=$(cd "$_fm_screen_dir/.." && pwd)
  FM_HOME=${FM_HOME:-$fm_root}

  case "$question" in
    *'ask-user findings='*)
      echo "screen: by hand (a review gate: bin/fm-finding-sort.sh and ask-user-authority own it)"; return 0 ;;
  esac
  if [ "${#question}" -gt "$ESCALATION_SCREEN_MAX_CHARS" ]; then
    echo "screen: by hand (the question is over $ESCALATION_SCREEN_MAX_CHARS characters)"; return 0
  fi
  if printf '%s\n' "$question" | grep -Eiqw -- "$ESCALATION_SCREEN_CAPTAIN_WORDS"; then
    echo "screen: captain's (names a merge, an approval, or a destructive, irreversible, or security-sensitive act; not asked)"
    return 0
  fi
  if ! fm_jev_key_load "$FM_HOME"; then
    echo "screen: by hand (off, TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env)"; return 0
  fi
  command -v jq >/dev/null 2>&1 || { echo "screen: by hand (jq not installed)"; return 0; }
  tmp=$(mktemp -d) || { echo "screen: by hand (mktemp failed)"; return 0; }
  ESCALATION_SCREEN_TMP=$tmp
  jq -n --arg question "$question" '{question: $question}' > "$tmp/state"
  printf '%s' "$ESCALATION_SCREEN_CRITERIA" > "$tmp/criteria"
  if ! fm_jev_choice kind "$ESCALATION_SCREEN_INSTRUCTIONS" "$tmp/state" "$tmp/criteria"; then
    rm -rf "$tmp"
    echo "screen: by hand (no answer: $FM_JEV_ERROR)"; return 0
  fi
  rm -rf "$tmp"

  case "$FM_JEV_CHOICE" in
    trade|costly-to-undo)
      echo "screen: captain's ($FM_JEV_CHOICE, confidence $FM_JEV_CONFIDENCE)" ;;
    setting-with-default|cheap-to-reverse)
      if jq -en --argjson c "$FM_JEV_CONFIDENCE" --argjson floor "$FM_JEV_CONFIDENCE_FLOOR" '$c >= $floor' >/dev/null; then
        echo "screen: yours ($FM_JEV_CHOICE, confidence $FM_JEV_CONFIDENCE)"
      else
        echo "screen: by hand ($FM_JEV_CHOICE below the confidence floor, $FM_JEV_CONFIDENCE)"
      fi ;;
    *) echo "screen: by hand ($FM_JEV_CHOICE, confidence $FM_JEV_CONFIDENCE)" ;;
  esac
  return 0
}

ESCALATION_SCREEN_TMP=
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  trap '[ -z "$ESCALATION_SCREEN_TMP" ] || rm -rf "$ESCALATION_SCREEN_TMP"' EXIT
  escalation_screen_main "$@"
  exit
fi
