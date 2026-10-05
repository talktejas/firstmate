#!/usr/bin/env bash
# fm-house-rules-check.sh - advisory house-rules check of a task's own change
# with typesafe.ai's System One model (Jev), opt-in.
#
# Usage:
#   fm-house-rules-check.sh [--base <ref>]   (run inside the task worktree)
#   fm-house-rules-check.sh --enabled        (exit 0 when a run would ask Jev)
#
# Opt-in gate: TYPESAFE_API_KEY under the same environment-then-$FM_HOME/.env
#   contract as bin/fm-dispatch-resolve.sh; bin/fm-jev-lib.sh owns the key
#   handling, the request, and the answer validation, and is the only Jev
#   caller here. With the key absent this prints one "off" line on stderr and
#   exits 0 with no network call, and bin/fm-dod-lib.sh's fm_dod_block leaves
#   the line that asks a worker to run it out of the brief altogether.
#
# What it does when on: code decides every fact first. It diffs the worktree
#   against the merge base with <ref> (default: the default branch, origin's
#   copy when there is one), keeps only added or modified text files, drops
#   prose, lockfiles, generated and vendored paths, and secret-shaped files,
#   cuts each remaining diff hunk into blocks of at most HOUSE_RULES_BLOCK_LINES
#   lines, and drops a block that adds nothing. Only then is each block asked
#   each rule as ONE yes/no Choice question through fm_jev_choice. A block is
#   flagged only for a `yes` whose confidence and `yes` probability both reach
#   the shared FM_JEV_CONFIDENCE_FLOOR.
#
# Rules: config/house-rules.json when it exists, else the two built-in rules
#   below. docs/configuration.md "House-rules check" owns the file's schema; an
#   empty `rules` array turns the check off while the key stays in place.
#
# Output: one line per flag on stdout, pointing at the first added line of the
#   flagged block:
#     <file>:<line>: <rule-id> (confidence <c>): <the rule's question>
#   and one summary line on stderr.
#
# Authority: advice only. Every outcome exits 0 - no key, no base, a malformed
#   rules file, a timeout, a malformed answer, low confidence - so nothing here
#   can block, approve, merge, or discard a change; a failure means no flag.
#   Asking stops after HOUSE_RULES_MAX_ERRORS failed calls, HOUSE_RULES_MAX_CALLS
#   calls, or HOUSE_RULES_DEADLINE_SECS seconds, and the summary says how many
#   questions went unasked. Exit 2 only for a usage error.
set -u

# Sourced before anything can start a child: it takes the key out of the
# exported environment. The path is derived with builtins for the same reason.
_fm_house_dir=${BASH_SOURCE[0]%/*}
[ "$_fm_house_dir" != "${BASH_SOURCE[0]}" ] || _fm_house_dir=.
# shellcheck source=bin/fm-jev-lib.sh
. "$_fm_house_dir/fm-jev-lib.sh"

HOUSE_RULES_BLOCK_LINES=80
HOUSE_RULES_MAX_CALLS=60
HOUSE_RULES_MAX_ERRORS=3
HOUSE_RULES_DEADLINE_SECS=120
HOUSE_RULES_DEFAULT='{"rules":[
  {"id":"hardcoded-choice",
   "question":"Do the added lines hard-code a behaviour choice that should be a setting?",
   "yes":"The added lines fix, as a literal in the code, a choice about how the product behaves that different customers or installations could reasonably want set differently - a business rule, a threshold, a rate, a default mode, a feature being on or off - with no setting, option, or parameter that could change it.",
   "no":"The added lines read the choice from a setting, option, or parameter, or declare a setting'"'"'s default, or the value is not a behaviour choice at all: a technical constant, a name, a format, test data, plumbing, or anything else."},
  {"id":"own-compat-layer",
   "question":"Do the added lines add a redirect or compatibility layer for one of this project'"'"'s own old decisions?",
   "yes":"The added lines keep an old name, address, format, or behaviour of this project itself working beside the new one: a redirect from an old route or URL, an alias for a renamed thing, a fallback that still reads the old shape, a shim, or a deprecated path kept alive.",
   "no":"The added lines only implement current behaviour, or adapt to an outside system, library, or standard this project does not control, or it is not clear that anything old is being kept alive."}
]}'
# shellcheck disable=SC2016 # Backticks are literal Markdown for the model.
HOUSE_RULES_INSTRUCTIONS='`change.block` is one changed block of a unified diff of the file `change.file`: lines starting with + were added, lines starting with - were removed, and the rest is unchanged context. Judge only what the added lines introduce. %s Choose `no` whenever the added lines do not clearly do this or you are unsure.'

house_rules_usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

# Print the validated rules as one compact JSON array; 1 with a reason on
# stderr when config/house-rules.json exists and is not a usable rules file.
house_rules_load() {
  local file=$HOUSE_RULES_CONFIG/house-rules.json
  if [ -e "$file" ] || [ -L "$file" ]; then
    jq -c '
      if type != "object" or (.rules | type) != "array" then error("rules must be an array")
      elif any(.rules[]; type != "object"
          or ((.id | type) != "string") or (.id | test("^[a-z0-9]+(-[a-z0-9]+)*$") | not)
          or ((.question | type) != "string") or (.question | length) == 0
          or ((.yes | type) != "string") or (.yes | length) == 0
          or ((.no | type) != "string") or (.no | length) == 0)
        then error("each rule needs a lowercase-dash id and non-empty question, yes, and no")
      elif ([.rules[].id] | length) != ([.rules[].id] | unique | length) then error("rule ids must be unique")
      else .rules end' "$file" 2>/dev/null && return 0
    echo "house-rules-check: not run ($file is not a valid rules file; docs/configuration.md \"House-rules check\" owns the schema)" >&2
    return 1
  fi
  jq -c .rules <<<"$HOUSE_RULES_DEFAULT"
}

# Paths code never offers: prose, generated or vendored text, and files whose
# name says they hold secrets. A quoted path is one git had to escape.
house_rules_path_skipped() {  # <path>
  case "$1" in
    ''|'"'*) return 0 ;;
    *.md|*.markdown|*.txt|*.rst|*.adoc) return 0 ;;
    *.lock|*lock.json|*lock.yaml|*.sum|*.min.*|*.map|*.snap|*.svg) return 0 ;;
    vendor/*|*/vendor/*|node_modules/*|*/node_modules/*|dist/*|*/dist/*) return 0 ;;
    .env|.env.*|*/.env|*/.env.*|*.pem|*.key|*.p12|*.pfx|*secret*|*credential*) return 0 ;;
  esac
  return 1
}

# Cut the diff on stdin into block files <dir>/<n> and print "<n>\t<line>\t<file>"
# for each block that adds a non-blank line; <line> is its first added line.
house_rules_blocks() {  # <dir> <max-lines>
  awk -v dir="$1" -v max="$2" '
    function flush() {
      if (count > 0) {
        close(out)
        if (first > 0) printf "%d\t%d\t%s\n", n, first, file
      }
      count = 0; first = 0
    }
    function start() { n++; out = dir "/" n }
    /^diff --git / { flush(); inhunk = 0; file = ""; next }
    !inhunk && /^\+\+\+ / { file = ($0 == "+++ /dev/null") ? "" : substr($0, 7); next }
    /^@@ / && file != "" {
      flush(); inhunk = 1
      at = $0; sub(/^@@ -[0-9,]+ \+/, "", at); sub(/[, ].*$/, "", at); line = at + 0
      start(); next
    }
    !inhunk { next }
    /^\\/ { next }
    {
      if (count >= max) { flush(); start() }
      print substr($0, 1, 400) > out
      count++
      if ($0 ~ /^\+/) {
        if (first == 0 && $0 ~ /^\+.*[^[:space:]]/) first = line
        line++
      } else if ($0 !~ /^-/) line++
    }
    END { flush() }'
}

house_rules_main() {
  local base='' enabled=0 fm_root rules count tmp default ref mb
  local id line file r asked=0 errors=0 flags=0 unasked=0 blocks=0 stop=''
  local rule_ids=() rule_questions=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -ge 2 ] || { echo "error: --base needs a value" >&2; return 2; }; base=$2; shift 2 ;;
      --enabled) enabled=1; shift ;;
      -h|--help) house_rules_usage; return 0 ;;
      *) echo "error: unknown argument $1 (see --help)" >&2; return 2 ;;
    esac
  done
  fm_root=${FM_ROOT_OVERRIDE:-$(cd "$_fm_house_dir/.." && pwd)}
  FM_HOME=${FM_HOME:-$fm_root}
  HOUSE_RULES_CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}

  if ! fm_jev_key_load "$FM_HOME"; then
    [ "$enabled" -eq 1 ] || echo "house-rules-check: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env)" >&2
    return "$enabled"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    [ "$enabled" -eq 1 ] || echo "house-rules-check: not run (jq not installed)" >&2
    return "$enabled"
  fi
  if [ "$enabled" -eq 1 ]; then
    rules=$(house_rules_load 2>/dev/null) || return 1
    [ "$(jq -r length <<<"$rules")" -gt 0 ]
    return
  fi
  rules=$(house_rules_load) || return 0
  count=$(jq -r length <<<"$rules")
  if [ "$count" -eq 0 ]; then
    echo "house-rules-check: off (no rules configured)" >&2
    return 0
  fi

  if [ -z "$base" ]; then
    default=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || default=''
    for ref in "$default" origin/main origin/master main master; do
      [ -n "$ref" ] || continue
      git rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || continue
      base=$ref
      break
    done
  fi
  mb=$(git merge-base HEAD "$base" 2>/dev/null) || mb=''
  if [ -z "$mb" ]; then
    echo "house-rules-check: not run (no merge base with ${base:-a default branch}; pass --base <ref>)" >&2
    return 0
  fi

  tmp=$(mktemp -d) || { echo "house-rules-check: not run (mktemp failed)" >&2; return 0; }
  HOUSE_RULES_TMP=$tmp
  while IFS=$'\t' read -r id line; do
    rule_ids+=("$id")
    rule_questions+=("$line")
  done < <(jq -r '.[] | [.id, (.question | gsub("[\t\r\n]"; " "))] | @tsv' <<<"$rules")
  for (( r = 0; r < count; r++ )); do
    jq --argjson r "$r" '.[$r] | {yes, no}' <<<"$rules" > "$tmp/criteria.$r"
  done
  mkdir "$tmp/blocks"
  git -c core.quotePath=false diff --no-color --no-ext-diff --diff-filter=AMR -U3 --src-prefix=a/ --dst-prefix=b/ "$mb" -- 2>/dev/null \
    | house_rules_blocks "$tmp/blocks" "$HOUSE_RULES_BLOCK_LINES" > "$tmp/index"

  SECONDS=0
  while IFS=$'\t' read -r id line file; do
    house_rules_path_skipped "$file" && continue
    blocks=$((blocks + 1))
    jq -n --arg file "$file" --rawfile block "$tmp/blocks/$id" \
      '{change: {file: $file, block: $block}}' > "$tmp/state" 2>/dev/null || continue
    for (( r = 0; r < count; r++ )); do
      if [ -z "$stop" ]; then
        if [ "$errors" -ge "$HOUSE_RULES_MAX_ERRORS" ]; then stop="$errors calls failed, last: $FM_JEV_ERROR"
        elif [ "$asked" -ge "$HOUSE_RULES_MAX_CALLS" ]; then stop="the $HOUSE_RULES_MAX_CALLS-call bound was reached"
        elif [ "$SECONDS" -ge "$HOUSE_RULES_DEADLINE_SECS" ]; then stop="the ${HOUSE_RULES_DEADLINE_SECS}s bound was reached"
        fi
      fi
      if [ -n "$stop" ]; then
        unasked=$((unasked + 1))
        continue
      fi
      asked=$((asked + 1))
      # The instruction template is a constant that carries one %s.
      # shellcheck disable=SC2059
      if ! fm_jev_choice house_rule "$(printf "$HOUSE_RULES_INSTRUCTIONS" "${rule_questions[$r]}")" \
        "$tmp/state" "$tmp/criteria.$r"; then
        errors=$((errors + 1))
        continue
      fi
      jq -e --argjson floor "$FM_JEV_CONFIDENCE_FLOOR" \
        '.choice == "yes" and .confidence >= $floor and .probabilities.yes >= $floor' \
        >/dev/null 2>&1 <<<"$FM_JEV_ANSWER" || continue
      flags=$((flags + 1))
      printf '%s:%s: %s (confidence %s): %s\n' "$file" "$line" "${rule_ids[$r]}" "$FM_JEV_CONFIDENCE" "${rule_questions[$r]}"
    done
  done < "$tmp/index"
  rm -rf "$tmp"

  echo "house-rules-check: $flags advisory flag(s) from $asked question(s) over $blocks changed block(s) and $count rule(s) since $base${stop:+; stopped because $stop, $unasked question(s) not asked}" >&2
  return 0
}

HOUSE_RULES_TMP=
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  trap '[ -z "$HOUSE_RULES_TMP" ] || rm -rf "$HOUSE_RULES_TMP"' EXIT
  house_rules_main "$@"
  exit
fi
