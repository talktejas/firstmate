# shellcheck shell=bash
# shellcheck disable=SC2034 # The FM_JEV_* outputs are read by the sourcing callers.
# Shared typesafe.ai System One (Jev) fixed-choice caller.
# Usage: . bin/fm-jev-lib.sh   (source it before the caller runs any child)
#
# This file is the single owner of the Jev request, response validation, and
# key handling. Callers ask fixed-choice questions over a JSON state in one
# request and get back, per question, the chosen option, a probability per
# option, and a status; every decision
# made from that answer (a confidence floor, an approval gate, an absorb) stays
# in the caller's own code. bin/fm-dispatch-resolve.sh, the watcher's
# routine-wake triage (bin/fm-watch.sh), bin/fm-house-rules-check.sh, the
# worker stop hook's finished check (bin/fm-finished-check.sh), and the review
# finding sort (bin/fm-finding-sort.sh) are the callers.
#
# Key handling: sourcing this file copies an environment-provided
# TYPESAFE_API_KEY into one non-exported shell variable and unsets the exported
# one, so no child process started afterwards inherits it. fm_jev_key_load then
# falls back to a TYPESAFE_API_KEY= line in <home>/.env through fmx_env_get
# (bin/fm-env-lib.sh); the environment wins. The key reaches curl as a header
# read from a file descriptor, never on argv, and nothing logs or writes it.
#
# fm_jev_key_load <home>
#   0 when a key is available, 1 when it is absent from both sources.
#
# fm_jev_code_allowed <project>
#   0 only when <project> is a line of $FM_HOME/config/jev-code-projects (one
#   project name per line; blank lines and lines starting with # are ignored).
#   The key alone lets a caller send routing text and status lines; a caller
#   that would send a project's code, file list, or pull request text asks this
#   first. An absent or empty file allows no project.
#
# fm_jev_choice <question-key> <instructions> <state-json-file> <criteria-json-file>
#   One POST to $FM_JEV_BASE/v1/systemone. <state-json-file> holds the JSON
#   value sent as `state`; <criteria-json-file> holds one JSON object mapping
#   each allowed choice to its criterion text. Returns 0 only when a
#   well-formed answer came back, and always sets:
#     FM_JEV_STATUS         ok | off | error
#     FM_JEV_ERROR          why, when status is error
#     FM_JEV_LATENCY_MS     request wall time, or null when no request was made
#     FM_JEV_ANSWER         {model, usage, choice, confidence, probabilities} JSON (ok only)
#     FM_JEV_CHOICE         the chosen option (ok only)
#     FM_JEV_CONFIDENCE     its confidence, 0..1 (ok only)
#     FM_JEV_PROBABILITIES  "<choice>=<p> ..." for every allowed choice (ok only)
#   An answer is well formed when its probabilities cover exactly the allowed
#   choices, each lies in 0..1, and they sum to 1 within 0.01. `off` means no
#   key and no network call. Every failure (missing curl or jq, a timeout, a
#   non-200 reply, a malformed answer) is `error`, so a caller's fallback is
#   one branch.
#
# fm_jev_choices <questions-json-file> <state-json-file> <required-question-key>
#   The same single POST carrying several Choice questions over one state.
#   <questions-json-file> holds one JSON object mapping each question key to
#   {instructions, criteria}. Sets FM_JEV_STATUS, FM_JEV_ERROR, and
#   FM_JEV_LATENCY_MS as above, plus:
#     FM_JEV_ANSWERS        {model, usage, answers: {<key>: {choice, confidence, probabilities} | null}} JSON (ok only)
#   The required question must come back well formed under the rule above, or
#   the call is `error`; any other question whose answer is missing or
#   malformed has a null answer.

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

_FM_JEV_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_JEV_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_JEV_LIB_DIR=.
# shellcheck source=bin/fm-env-lib.sh
. "$_FM_JEV_LIB_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$_FM_JEV_LIB_DIR/fm-timing-lib.sh"

FM_JEV_MODEL=jev-latest
FM_JEV_BASE=https://api.typesafe.ai
FM_JEV_TIMEOUT=5
# The floor every current caller applies to a Choice answer's confidence.
FM_JEV_CONFIDENCE_FLOOR=0.6

FM_JEV_STATUS=
FM_JEV_ERROR=
FM_JEV_LATENCY_MS=null
FM_JEV_ANSWER=
FM_JEV_ANSWERS=
FM_JEV_CHOICE=
FM_JEV_CONFIDENCE=
FM_JEV_PROBABILITIES=

fm_jev_key_load() {  # <home>
  [ -n "$TYPESAFE_API_KEY_PRIVATE" ] \
    || TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$1/.env")
  [ -n "$TYPESAFE_API_KEY_PRIVATE" ]
}

fm_jev_code_allowed() {  # <project>
  [ -n "$1" ] && [ "${1#\#}" = "$1" ] \
    && grep -qxF -- "$1" "${FM_HOME:-.}/config/jev-code-projects" 2>/dev/null
}

_fm_jev_fail() {  # <reason>
  FM_JEV_STATUS=error
  FM_JEV_ERROR=$1
  return 1
}

# One POST carrying every question in <questions-json>, an object mapping each
# question key to {instructions, criteria}. Sets FM_JEV_STATUS, FM_JEV_ERROR,
# FM_JEV_LATENCY_MS, and FM_JEV_ANSWERS; the two public callers below own the rest.
_fm_jev_ask() {  # <questions-json> <state-json-file> <required-question-key>
  local questions=$1 state_file=$2 required=$3
  local request resp http t0 t1 fields verdict rc=0
  FM_JEV_STATUS='' FM_JEV_ERROR='' FM_JEV_LATENCY_MS=null FM_JEV_ANSWERS=''
  if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
    FM_JEV_STATUS=off
    return 1
  fi
  command -v curl >/dev/null 2>&1 || { _fm_jev_fail "curl not installed"; return 1; }
  command -v jq >/dev/null 2>&1 || { _fm_jev_fail "jq not installed"; return 1; }
  request=$(jq -n --arg model "$FM_JEV_MODEL" --argjson questions "$questions" --arg required "$required" \
    --slurpfile state "$state_file" '
    if ($state | length) != 1 or ($questions | type) != "object" or ($questions | has($required) | not)
       or any($questions[]; (.instructions | type) != "string" or (.criteria | type) != "object")
    then error("bad input") else
    {
      model: $model,
      state: $state[0],
      questions: ($questions | map_values({type: "choice", instructions, criteria}))
    } end' 2>/dev/null) || { _fm_jev_fail "request could not be built"; return 1; }
  resp=$(mktemp) || { _fm_jev_fail "mktemp failed"; return 1; }
  t0=$(fm_timing_now_ms)
  http=$(printf '%s' "$request" | curl -sS --max-time "$FM_JEV_TIMEOUT" -o "$resp" -w '%{http_code}' \
    -X POST "$FM_JEV_BASE/v1/systemone" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
    --data-binary @- 2>/dev/null) || http=000
  t1=$(fm_timing_now_ms)
  FM_JEV_LATENCY_MS=$(( t1 - t0 ))
  if [ "$http" != 200 ]; then
    _fm_jev_fail "http $http after ${FM_JEV_LATENCY_MS} ms: $(head -c 200 "$resp" 2>/dev/null | tr '\n' ' ')"
    rm -f "$resp"
    return 1
  fi
  # Prints "ok" and the answers, each one that is not well formed as null, or
  # "bad" when the required question has no well-formed answer.
  fields=$(printf '%s' "$request" | jq -r --arg required "$required" --slurpfile resp "$resp" '
    def good($q; $a):
      ($a | type) == "object" and
      ($a.choice | type) == "string" and
      ($a.confidence | type) == "number" and
      $a.confidence >= 0 and $a.confidence <= 1 and
      ($a.probabilities | type) == "object" and
      (($a.probabilities | keys | sort) == ($q.criteria | keys | sort)) and
      all($a.probabilities[]; type == "number" and . >= 0 and . <= 1) and
      (($a.probabilities | [.[]] | add) as $total | $total >= 0.99 and $total <= 1.01);
    .questions as $qs |
    ($resp | if length == 1 and (.[0] | type) == "object" then .[0] else {} end) as $r |
    ($r.answers | if type == "object" then . else {} end) as $as |
    ($qs | with_entries(.key as $k | .value = (if good(.value; $as[$k]) then ($as[$k] | {choice, confidence, probabilities}) else null end))) as $answers |
    (($r | has("usage") | not) or
      (($r.usage | type) == "object" and
       ($r.usage.input_tokens | type) == "number" and
       ($r.usage.output_tokens | type) == "number")) as $usage_ok |
    if $answers[$required] == null or ($usage_ok | not) then "bad"
    else "ok", ({model: $r.model, usage: ($r.usage // null), answers: $answers} | tojson)
    end' 2>/dev/null) || rc=1
  rm -f "$resp"
  [ "$rc" -eq 0 ] || { _fm_jev_fail "response could not be read"; return 1; }
  {
    IFS= read -r verdict
    IFS= read -r fields
  } <<EOF
$fields
EOF
  [ "$verdict" = ok ] || { _fm_jev_fail "response is not a $required Choice answer"; return 1; }
  FM_JEV_ANSWERS=$fields
  FM_JEV_STATUS=ok
  return 0
}

fm_jev_choices() {  # <questions-json-file> <state-json-file> <required-question-key>
  local questions
  questions=$(jq -c . "$1" 2>/dev/null) || { _fm_jev_fail "request could not be built"; return 1; }
  _fm_jev_ask "$questions" "$2" "$3"
}

fm_jev_choice() {  # <question-key> <instructions> <state-json-file> <criteria-json-file>
  local key=$1 questions fields
  FM_JEV_ANSWER='' FM_JEV_CHOICE='' FM_JEV_CONFIDENCE='' FM_JEV_PROBABILITIES=''
  questions=$(jq -c --arg key "$key" --arg instructions "$2" \
    '{($key): {instructions: $instructions, criteria: .}}' "$4" 2>/dev/null) \
    || { FM_JEV_LATENCY_MS=null; _fm_jev_fail "request could not be built"; return 1; }
  _fm_jev_ask "$questions" "$3" "$key" || return 1
  fields=$(jq -r --arg key "$key" '
    .answers[$key] as $a |
    ({model, usage} + $a | tojson),
    ($a.choice | gsub("[\t\r\n]"; " ")),
    ($a.confidence | tostring),
    ([$a.probabilities | to_entries[] | "\(.key)=\(.value)"] | join(" "))' <<<"$FM_JEV_ANSWERS")
  {
    IFS= read -r FM_JEV_ANSWER
    IFS= read -r FM_JEV_CHOICE
    IFS= read -r FM_JEV_CONFIDENCE
    IFS= read -r FM_JEV_PROBABILITIES
  } <<EOF
$fields
EOF
  return 0
}
