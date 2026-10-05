# shellcheck shell=bash
# shellcheck disable=SC2034 # The FM_JEV_* outputs are read by the sourcing callers.
# Shared typesafe.ai System One (Jev) fixed-choice caller.
# Usage: . bin/fm-jev-lib.sh   (source it before the caller runs any child)
#
# This file is the single owner of the Jev request, response validation, and
# key handling. Callers ask ONE Choice question over a JSON state and get back
# the chosen option, a probability per option, and a status; every decision
# made from that answer (a confidence floor, an approval gate, an absorb) stays
# in the caller's own code. bin/fm-dispatch-resolve.sh, the watcher's
# routine-wake triage (bin/fm-watch.sh), and bin/fm-house-rules-check.sh are
# the callers.
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
FM_JEV_CHOICE=
FM_JEV_CONFIDENCE=
FM_JEV_PROBABILITIES=

fm_jev_key_load() {  # <home>
  [ -n "$TYPESAFE_API_KEY_PRIVATE" ] \
    || TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$1/.env")
  [ -n "$TYPESAFE_API_KEY_PRIVATE" ]
}

_fm_jev_fail() {  # <reason>
  FM_JEV_STATUS=error
  FM_JEV_ERROR=$1
  return 1
}

fm_jev_choice() {  # <question-key> <instructions> <state-json-file> <criteria-json-file>
  local key=$1 instructions=$2 state_file=$3 criteria_file=$4
  local request resp http t0 t1 fields rc=0
  FM_JEV_STATUS='' FM_JEV_ERROR='' FM_JEV_LATENCY_MS=null
  FM_JEV_ANSWER='' FM_JEV_CHOICE='' FM_JEV_CONFIDENCE='' FM_JEV_PROBABILITIES=''
  if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
    FM_JEV_STATUS=off
    return 1
  fi
  command -v curl >/dev/null 2>&1 || { _fm_jev_fail "curl not installed"; return 1; }
  command -v jq >/dev/null 2>&1 || { _fm_jev_fail "jq not installed"; return 1; }
  request=$(jq -n --arg model "$FM_JEV_MODEL" --arg key "$key" --arg instructions "$instructions" \
    --slurpfile state "$state_file" --slurpfile criteria "$criteria_file" '
    if ($state | length) != 1 or ($criteria | length) != 1 or ($criteria[0] | type) != "object"
    then error("bad input") else
    {
      model: $model,
      state: $state[0],
      questions: {($key): {type: "choice", instructions: $instructions, criteria: $criteria[0]}}
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
  fields=$(printf '%s' "$request" | jq -r --arg key "$key" --slurpfile resp "$resp" '
    (.questions[$key].criteria | keys | sort) as $choices |
    ($resp | if length == 1 then .[0] else error("bad response") end) as $r |
    ($r.answers[$key]) as $a |
    if (($a.choice | type) == "string" and
        ($a.confidence | type) == "number" and
        $a.confidence >= 0 and $a.confidence <= 1 and
        ($a.probabilities | type) == "object" and
        (($a.probabilities | keys | sort) == $choices) and
        all($a.probabilities[]; type == "number" and . >= 0 and . <= 1) and
        (($a.probabilities | [.[]] | add) as $total | $total >= 0.99 and $total <= 1.01) and
        (($r | has("usage") | not) or
          (($r.usage | type) == "object" and
           ($r.usage.input_tokens | type) == "number" and
           ($r.usage.output_tokens | type) == "number")))
    then
      ({model: $r.model, usage: ($r.usage // null), choice: $a.choice,
        confidence: $a.confidence, probabilities: $a.probabilities} | tojson),
      ($a.choice | gsub("[\t\r\n]"; " ")),
      ($a.confidence | tostring),
      ([$a.probabilities | to_entries[] | "\(.key)=\(.value)"] | join(" "))
    else error("bad answer") end' 2>/dev/null) || rc=1
  rm -f "$resp"
  [ "$rc" -eq 0 ] || { _fm_jev_fail "response is not a $key Choice answer"; return 1; }
  {
    IFS= read -r FM_JEV_ANSWER
    IFS= read -r FM_JEV_CHOICE
    IFS= read -r FM_JEV_CONFIDENCE
    IFS= read -r FM_JEV_PROBABILITIES
  } <<EOF
$fields
EOF
    FM_JEV_STATUS=ok
  return 0
}
