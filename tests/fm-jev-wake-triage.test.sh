#!/usr/bin/env bash
# tests/fm-jev-wake-triage.test.sh - the routine-wake triage in bin/fm-watch.sh
# (off unless TYPESAFE_API_KEY is present) and the shared Jev caller it uses
# (bin/fm-jev-lib.sh).
#
# Three layers, none of which touches the network:
#   - the library's own interface, driven with a fake curl on PATH;
#   - the triage decision at each eligible watcher site, with the watcher sourced
#     and fm_jev_choice stubbed at the library boundary, so every eligible class,
#     every never-eligible class, and every fallback is asserted by whether the
#     model was asked at all and by what the watcher then queued;
#   - a real watcher subprocess with the real library and a fake curl, proving
#     the main-loop wiring absorbs or delivers and that the key reaches curl on a
#     file descriptor and no child environment, argv, or log.
# bin/fm-dispatch-resolve.sh's unchanged behavior on the same library is
# tests/fm-dispatch-resolve.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-wake-triage)
KEY='test-key-4b7a-never-on-argv'
PR_URL='https://github.com/o/r/pull/8'

# Fake curl shared by the library and subprocess layers: records argv (minus the
# -o target), the stdin body, the header read from fd 3, and whether the key was
# visible in its environment, then answers with FAKE_CURL_RESPONSE.
install_fake_curl() {  # <fakebin>
  cat > "$1/curl" <<'SH'
#!/usr/bin/env bash
set -u
log=${FAKE_CURL_LOG:?}
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf 'curl:secret-present\n' >> "$log/child-env"
else
  printf 'curl:clean\n' >> "$log/child-env"
fi
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "$log/argv"; shift ;;
  esac
done
n=$(cat "$log/calls" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$log/calls"
cat > "$log/body.$n"
cat /dev/fd/3 > "$log/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$log/header"
[ "${FAKE_CURL_FAIL:-0}" = 0 ] || exit "$FAKE_CURL_FAIL"
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
  chmod +x "$1/curl"
}

write_answer() {  # <path> <choice> <confidence> [<routine-probability>]
  local routine=${4:-}
  if [ -z "$routine" ]; then
    if [ "$2" = routine ]; then routine=$3; else routine=$(jq -n --argjson c "$3" '1 - $c'); fi
  fi
  jq -n --arg choice "$2" --argjson confidence "$3" --argjson routine "$routine" '
    {model: "jev-test", usage: {input_tokens: 200, output_tokens: 20},
     answers: {wake: {type: "choice", choice: $choice, confidence: $confidence,
       probabilities: {needs_firstmate: (1 - $routine), routine: $routine}}}}' > "$1"
}

# --- layer 1: the library interface -----------------------------------------

LIB_DIR="$TMP_ROOT/lib"
LIB_BIN="$LIB_DIR/fakebin"
mkdir -p "$LIB_BIN" "$LIB_DIR/log" "$LIB_DIR/home"
install_fake_curl "$LIB_BIN"
printf '%s' '{"subject":"a"}' > "$LIB_DIR/state.json"
printf '%s' '{"yes":"It holds.","no":"It does not."}' > "$LIB_DIR/criteria.json"
printf '%s' '{"model":"jev-test","answers":{"q":{"choice":"yes","confidence":0.8,"probabilities":{"yes":0.8,"no":0.2}}}}' \
  > "$LIB_DIR/response.json"

lib_call() {  # [env assignments...] -> prints status, choice, confidence, probabilities, error
  # shellcheck disable=SC2016 # The inner shell expands its own positional parameters.
  env PATH="$LIB_BIN:$PATH" FAKE_CURL_LOG="$LIB_DIR/log" FAKE_CURL_RESPONSE="$LIB_DIR/response.json" "$@" \
    bash -c '
      . "$1/bin/fm-jev-lib.sh"
      fm_jev_key_load "$2" || true
      fm_jev_choice q "Does it hold?" "$3" "$4"
      printf "%s|%s|%s|%s|%s|%s\n" "$?" "$FM_JEV_STATUS" "$FM_JEV_CHOICE" "$FM_JEV_CONFIDENCE" \
        "$FM_JEV_PROBABILITIES" "$FM_JEV_ERROR"
    ' _ "$ROOT" "$LIB_DIR/home" "$LIB_DIR/state.json" "$LIB_DIR/criteria.json"
}

out=$(lib_call TYPESAFE_API_KEY="$KEY")
assert_equals '0|ok|yes|0.8|yes=0.8 no=0.2|' "$out" "a well-formed answer returns the choice, its confidence, and every probability"
assert_equals '["no","yes"]' "$(jq -c '.questions.q.criteria | keys' "$LIB_DIR/log/body.1")" "the fixed choices ride as the question criteria"
assert_equals 'a' "$(jq -r '.state.subject' "$LIB_DIR/log/body.1")" "the state rides unchanged"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LIB_DIR/log/header")" "the key reaches curl on the fd header"
assert_not_contains "$(cat "$LIB_DIR/log/argv")" "$KEY" "the key never appears on curl argv"
assert_equals 'curl:clean' "$(cat "$LIB_DIR/log/child-env")" "the key is absent from curl's environment"
rm -rf "$LIB_DIR/log"; mkdir -p "$LIB_DIR/log"
PLANTED="ghp_$(printf 'a%.0s' $(seq 1 36))"
jq -n --arg token "$PLANTED" '{subject: "a", notes: ["kept one\nGH_TOKEN=\($token)\nkept two",
  "db_password = \"hunter2-hunter2\"", "before\n-----BEGIN RSA PRIVATE KEY-----\nKEYBODYLINE\n-----END RSA PRIVATE KEY-----\nafter",
  "cut\n-----BEGIN PRIVATE KEY-----\nOPENKEYLINE\nnever closed",
  "TAILKEYLINE1\nTAILKEYLINE2\n-----END EC PRIVATE KEY-----\nafter the tail"]}' > "$LIB_DIR/state.json"
out=$(lib_call TYPESAFE_API_KEY="$KEY")
assert_equals '0|ok|yes|0.8|yes=0.8 no=0.2|' "$out" "a state holding credential lines is still asked"
sent=$(cat "$LIB_DIR/log/body.1")
assert_not_contains "$sent" "$PLANTED" "a line holding a recognised credential is not sent"
assert_not_contains "$sent" 'hunter2' "a line holding a secret literal is not sent"
assert_not_contains "$sent" 'KEYBODYLINE' "no line of a private key block is sent"
assert_not_contains "$sent" 'PRIVATE KEY' "the private key block's own markers are not sent"
assert_not_contains "$sent" 'OPENKEYLINE' "a private key block that never closes is withheld to the end of its text"
assert_equals "kept one
[line withheld: looks like a credential]
kept two" "$(jq -r '.state.notes[0]' <<<"$sent")" "only the credential line is replaced, by the fixed placeholder"
assert_equals "before
[line withheld: looks like a credential]
after" "$(jq -r '.state.notes[2]' <<<"$sent")" "a private key block is replaced whole and the text after it is kept"
assert_equals "cut
[line withheld: looks like a credential]" "$(jq -r '.state.notes[3]' <<<"$sent")" "nothing after an unclosed private key block is sent"
assert_not_contains "$sent" 'TAILKEYLINE' "the tail of a private key block cut off from its first line is not sent"
assert_equals "[line withheld: looks like a credential]
after the tail" "$(jq -r '.state.notes[4]' <<<"$sent")" "everything through an unopened block's END line is replaced whole and the text after it is kept"
printf '%s' '{"subject":"a"}' > "$LIB_DIR/state.json"
rm -rf "$LIB_DIR/log"; mkdir -p "$LIB_DIR/log"
out=$(lib_call)
assert_equals '1|off||||' "$out" "no key is off"
assert_absent "$LIB_DIR/log/calls" "off makes no network call"
out=$(lib_call TYPESAFE_API_KEY="$KEY" FAKE_CURL_FAIL=28)
assert_contains "$out" '1|error||||http 000 after' "a transport timeout is an error"
printf '%s' '{"answers":{"q":{"choice":"yes","confidence":0.8,"probabilities":{"yes":0.8}}}}' > "$LIB_DIR/response.json"
out=$(lib_call TYPESAFE_API_KEY="$KEY")
assert_equals '1|error||||response is not a q Choice answer' "$out" "probabilities that omit an offered choice are malformed"
pass "library: one Choice question in; choice, probabilities, and ok/off/error out; key on the fd header only"

# --- layer 2: the triage decision, Jev stubbed at the library boundary ------

U="$TMP_ROOT/unit"
USTATE="$U/state"
UCONFIG="$U/config"
mkdir -p "$USTATE" "$UCONFIG" "$U/bin"
cat > "$U/bin/fm-pr-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FAKE_PR_CALLS:?}"
[ -z "${FAKE_PR_OUT:-}" ] || printf '%s\n' "$FAKE_PR_OUT"
exit "${FAKE_PR_RC:-0}"
SH
chmod +x "$U/bin/fm-pr-state.sh"
export FM_STATE_OVERRIDE="$USTATE" FM_CONFIG_OVERRIDE="$UCONFIG" FM_HOME="$U"
export FM_PR_STATE_BIN="$U/bin/fm-pr-state.sh" FAKE_PR_CALLS="$U/pr-calls"
# Production modules are independently linted canonical roots.
# shellcheck source=/dev/null
. "$WATCH"
# The sourced watcher reads the globals this layer sets on its behalf.
# shellcheck disable=SC2034
{

JEV_CALLS="$U/jev-calls"
WAKES="$U/wakes"
JEV_STUB='routine 0.93'
AGENT_STATE=alive

# shellcheck disable=SC2329 # Runtime overrides called by the sourced watcher.
wake() { printf '%s\n' "$1" >> "$WAKES"; return 0; }
# shellcheck disable=SC2329
fm_backend_agent_state() { printf '%s' "$AGENT_STATE"; }
# The library boundary: record the question, then answer as the case asks.
# JEV_STUB is "<choice> <confidence> [<routine-probability>]", "error", or "off".
# shellcheck disable=SC2329
fm_jev_choice() {  # <question-key> <instructions> <state-json-file> <criteria-json-file>
  local choice conf routine
  printf '%s\n' "$1" >> "$JEV_CALLS"
  cat "$3" > "$U/jev-state.json"
  cat "$4" > "$U/jev-criteria.json"
  FM_JEV_STATUS='' FM_JEV_ERROR='' FM_JEV_LATENCY_MS=7 FM_JEV_ANSWER=''
  FM_JEV_CHOICE='' FM_JEV_CONFIDENCE='' FM_JEV_PROBABILITIES=''
  case "$JEV_STUB" in
    off) FM_JEV_STATUS=off; return 1 ;;
    error) FM_JEV_STATUS=error; FM_JEV_ERROR='http 000 after 5001 ms: '; return 1 ;;
  esac
  read -r choice conf routine <<EOF
$JEV_STUB
EOF
  if [ -z "$routine" ]; then
    if [ "$choice" = routine ]; then routine=$conf; else routine=$(jq -n --argjson c "$conf" '1 - $c'); fi
  fi
  FM_JEV_STATUS=ok FM_JEV_CHOICE=$choice FM_JEV_CONFIDENCE=$conf
  FM_JEV_PROBABILITIES="needs_firstmate=x routine=$routine"
  FM_JEV_ANSWER=$(jq -nc --arg choice "$choice" --argjson confidence "$conf" --argjson routine "$routine" \
    '{model: "jev-stub", usage: null, choice: $choice, confidence: $confidence,
      probabilities: {needs_firstmate: (1 - $routine), routine: $routine}}')
  return 0
}

reset() {
  rm -rf "$USTATE" "$UCONFIG"
  mkdir -p "$USTATE" "$UCONFIG"
  : > "$JEV_CALLS"; : > "$WAKES"; : > "$FAKE_PR_CALLS"
  printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$U/.env"
  TYPESAFE_API_KEY_PRIVATE=
  AGENT_STATE=alive
  JEV_STUB='routine 0.93'
  unset FAKE_PR_OUT FAKE_PR_RC
  PAUSE_RESURFACE_SECS=100
}
mk_task() {  # <id> <meta-extra-or-empty> <status-line>...
  local id=$1 extra=$2
  shift 2
  fm_write_meta "$USTATE/$id.meta" "window=test:fm-$id" "kind=ship" ${extra:+"$extra"}
  printf '%s\n' "$@" > "$USTATE/$id.status"
}
calls() { wc -l < "$JEV_CALLS" | tr -d '[:space:]'; }
queued() { if [ -f "$USTATE/.wake-queue" ]; then wc -l < "$USTATE/.wake-queue" | tr -d '[:space:]'; else printf 0; fi; }
woken() { wc -l < "$WAKES" | tr -d '[:space:]'; }
tlog() { cat "$USTATE/.watch-triage.log" 2>/dev/null || true; }
age_status() {  # <id> <seconds>
  fm_touch_epoch "$(( $(date +%s) - $2 ))" "$USTATE/$1.status"
}
# The outcome every never-eligible and fallback case must have: delivered.
expect_never_asked() {  # <rc> <label>
  [ "$1" -ne 0 ] || fail "$2: the wake was absorbed"
  assert_equals 0 "$(calls)" "$2: Jev must not be asked"
}

# -- eligible: a declared-pause stale recheck, at each of its three sites ------
reset
mk_task park "pr=$PR_URL" 'working: implementing' 'paused: PR is open and green, awaiting the merge word'
age_status park 500
handle_paused_stale test:fm-park park h1
assert_equals 1 "$(calls)" "a due pause recheck asks Jev once"
assert_equals 0 "$(queued)" "a routine pause recheck queues nothing"
assert_equals 0 "$(woken)" "a routine pause recheck does not wake"
assert_present "$USTATE/.paused-resurfaced-test_fm-park" "a routine pause recheck still advances the recheck cadence"
assert_contains "$(tlog)" 'absorbed jev-routine declared-pause-recheck (confidence=0.93' "the absorb is logged to the triage log"
assert_equals 'declared-pause-recheck' "$(jq -r '.wake.class' "$U/jev-state.json")" "the wake class rides in the state"
assert_contains "$(jq -r '.wake.reason' "$U/jev-state.json")" 'awaiting external - declared pause' "the wake's own reason is the evidence"
assert_equals 'paused: PR is open and green, awaiting the merge word' \
  "$(jq -r '.wake.evidence[0].recent_status_events[-1]' "$U/jev-state.json")" "the task's recent status events are the evidence"
assert_equals '["needs_firstmate","routine"]' "$(jq -c 'keys' "$U/jev-criteria.json")" "Jev picks from the fixed two-choice list"
handle_paused_stale test:fm-park park h2
assert_equals 1 "$(calls)" "the same declaration is not asked again inside the recheck cadence"
pass "eligible: a due declared-pause recheck is absorbed on a routine answer and keeps its cadence"

reset
mk_task park "pr=$PR_URL" 'paused: waiting on the upstream release'
surface_nonterminal_stale test:fm-park h1
assert_equals 1 "$(calls)" "a live parked worker's first stale sight asks Jev"
assert_equals 0 "$(queued)" "a routine first stale sight queues nothing"
assert_present "$USTATE/.paused-resurfaced-test_fm-park" "a routine first sight records the declaration's throttle"
surface_nonterminal_stale test:fm-park h2
assert_equals 1 "$(calls)" "a new pane hash under the same declaration is not asked again"
assert_equals 0 "$(queued)" "a new pane hash under the same declaration stays absorbed"
pass "eligible: a live parked worker's first stale sight is absorbed and bounded per declaration"

reset
mk_task park "pr=$PR_URL" 'paused: waiting on the upstream release'
age_status park 500
wedge_defer_wait test:fm-park "$USTATE/.stale-since-test_fm-park" 'non-terminal stale' 300 "$(wedge_wait_evidence park)" park
assert_equals 1 "$(calls)" "a due declared-wait deferral asks Jev"
assert_equals 0 "$(queued)" "a routine declared-wait deferral queues nothing"
reset
mk_task park "pr=$PR_URL" 'captain-held [key=route]: tracked by task-decision-route'
age_status park 500
wedge_defer_wait test:fm-park "$USTATE/.stale-since-test_fm-park" 'non-terminal stale' 300 "$(wedge_wait_evidence park)" park
assert_equals 0 "$(calls)" "a captain-held recheck never asks Jev"
assert_equals 1 "$(queued)" "a captain-held recheck is delivered"
reset
mk_task park "pr=$PR_URL" 'captain-held [key=route]: tracked by task-decision-route'
age_status park 500
handle_paused_stale test:fm-park park h1
assert_equals 0 "$(calls)" "a captain-held stale never asks Jev"
assert_equals 1 "$(queued)" "a captain-held stale is delivered"
pass "eligible: a declared-wait deferral is absorbed; a captain-held wait is never offered"

# -- never eligible: a paused task with no recorded pull request -------------
reset
mk_task park '' 'paused: waiting on the upstream release'
surface_nonterminal_stale test:fm-park h1
assert_equals 0 "$(calls)" "the first stale sight of a paused task with no pull request never asks Jev"
assert_equals 1 "$(queued)" "the first stale sight of a paused task with no pull request is delivered"
reset
mk_task park '' 'paused: waiting on the upstream release'
age_status park 500
handle_paused_stale test:fm-park park h1
assert_equals 0 "$(calls)" "a due recheck of a paused task with no pull request never asks Jev"
assert_equals 1 "$(queued)" "a due recheck of a paused task with no pull request is delivered"
fm_touch_epoch "$(( $(date +%s) - 500 ))" "$USTATE/.paused-resurfaced-test_fm-park"
handle_paused_stale test:fm-park park h2
assert_equals 0 "$(calls)" "the next due recheck of a paused task with no pull request never asks Jev"
assert_equals 2 "$(queued)" "every due recheck of a paused task with no pull request is delivered"
reset
mk_task park '' 'paused: waiting on the upstream release'
age_status park 500
wedge_defer_wait test:fm-park "$USTATE/.stale-since-test_fm-park" 'non-terminal stale' 300 "$(wedge_wait_evidence park)" park
assert_equals 0 "$(calls)" "a due deferral of a paused task with no pull request never asks Jev"
assert_equals 1 "$(queued)" "a due deferral of a paused task with no pull request is delivered"
pass "never eligible: a paused task with no recorded pull request, at each of the three pause sites"

# -- never eligible: status events that belong to firstmate -------------------
for event in 'needs-decision [key=scope]: pick an option' 'blocked: cannot reach the host' \
  'failed: the build broke' "done: PR $PR_URL checks green" 'working: resumed' \
  'captain-held [key=route]: tracked by task-decision-route'; do
  reset
  mk_task park "pr=$PR_URL" 'paused: waiting on the upstream release' "$event"
  rc=0
  jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
  expect_never_asked "$rc" "a stale wake after a '${event%%:*}' status event"
done
reset
mk_task park "pr=$PR_URL" 'needs-decision [key=scope]: pick an option' 'paused: waiting on the upstream release'
rc=0
jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
expect_never_asked "$rc" "a task with an open keyed decision"
reset
mk_task park "pr=$PR_URL" 'needs-decision [key=scope]: pick an option' 'resolved [key=scope]: option a' 'paused: waiting on the upstream release'
jev_triage_pause_routine park "stale: test:fm-park" || fail "a closed decision before the pause must not block eligibility"
pass "never eligible: needs-decision, blocked, failed, done, working, captain-held, or an open keyed decision"

# -- never eligible: endpoint, kind, posture, and shape gates -----------------
for state in missing ambiguous unreadable unverified; do
  reset
  mk_task park "pr=$PR_URL" 'paused: waiting on the upstream release'
  AGENT_STATE=$state
  rc=0
  jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
  expect_never_asked "$rc" "an endpoint whose agent reads $state"
done
reset
mk_task park "pr=$PR_URL" 'paused: waiting on the upstream release'
fm_write_meta "$USTATE/park.meta" "window=test:fm-park" "kind=secondmate" "pr=$PR_URL"
rc=0
jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
expect_never_asked "$rc" "a secondmate"
reset
mk_task park "pr=$PR_URL" 'paused: waiting on the upstream release'
: > "$USTATE/.afk"
rc=0
jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
expect_never_asked "$rc" "the away daemon owning triage"
reset
mk_task park "pr=$PR_URL" 'paused: waiting on the upstream release'
: > "$USTATE/.afk-contract"
rc=0
jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
expect_never_asked "$rc" "the away-posture record existing"
reset
mk_task park "pr=$PR_URL" 'paused: waiting for the window until 2020-01-01T00:00Z'
rc=0
jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
expect_never_asked "$rc" "a declared clearing time that has passed"
pass "never eligible: a missing or unproven endpoint, a secondmate, the away posture, a passed clearing time"

# -- eligible: a worker whose agent has exited beside its open pull request ----
# pause_state_class routes an ordinary crew to the pause recheck only once its
# agent is confidently dead, so this is the recheck's ordinary case.
reset
mk_task park "pr=$PR_URL" "done: PR $PR_URL" "paused: pull request $PR_URL open, waiting for the captain's merge word"
AGENT_STATE=dead
export FAKE_PR_OUT='CHECKS: none reported yet'
age_status park 500
handle_paused_stale test:fm-park park h1
assert_equals 1 "$(calls)" "a due pause recheck of a worker whose agent has exited asks Jev once"
assert_equals 0 "$(queued)" "a routine pause recheck of a worker whose agent has exited queues nothing"
assert_equals 0 "$(woken)" "a routine pause recheck of a worker whose agent has exited does not wake"
assert_equals 'exited' "$(jq -r '.wake.evidence[0].worker_agent' "$U/jev-state.json")" "Jev is told the worker's agent has exited"
reset
mk_task park "pr=$PR_URL" 'paused: PR is open and green, awaiting the merge word'
jev_triage_pause_routine park "stale: test:fm-park" || fail "a running worker with an open pull request was not offered"
assert_equals 'running' "$(jq -r '.wake.evidence[0].worker_agent' "$U/jev-state.json")" "Jev is told the worker's agent is running"
pass "eligible: an exited agent beside an open pull request in a repository with no checks is offered, and Jev is told which"

# -- the deterministic pull-request read settles what it can -----------------
reset
mk_task park "pr=$PR_URL" 'paused: PR is open and green, awaiting the merge word'
jev_triage_pause_routine park "stale: test:fm-park" || fail "an open pull request with nothing blocking was not offered"
assert_equals "$PR_URL" "$(cat "$FAKE_PR_CALLS")" "the recorded pull request is read before Jev is asked"
assert_equals 'open; no blocker reported' "$(jq -r '.wake.evidence[0].pull_request' "$U/jev-state.json")" "the evidence says no more than the pull-request read established"
for pr_out in 'MERGEABILITY: unknown' 'CHECKS: none reported yet' \
  'CHECKS: no required check has reported; readiness unconfirmed' \
  $'MERGEABILITY: unknown\nCHECKS: none reported yet'; do
  reset
  mk_task park "pr=$PR_URL" 'paused: PR is open and green, awaiting the merge word'
  export FAKE_PR_OUT=$pr_out
  jev_triage_pause_routine park "stale: test:fm-park" || fail "a pull request reading '$pr_out' was not offered"
  assert_equals 'open; no blocker reported' "$(jq -r '.wake.evidence[0].pull_request' "$U/jev-state.json")" "a pull request reading '$pr_out' is not described as mergeable or passing"
done
for pr_out in 'STATE: merged at 2026-10-05T10:00:00Z' 'STATE: closed' 'REQUIRED CHECK: test (FAILURE)' \
  'REQUIRED CHECK: test (PENDING)' 'MERGEABILITY: conflicting' 'REVIEW DECISION: CHANGES_REQUESTED' \
  'DRAFT: pull request is not ready for review' $'MERGEABILITY: conflicting\nCHECKS: none reported yet'; do
  reset
  mk_task park "pr=$PR_URL" 'paused: PR is open and green, awaiting the merge word'
  export FAKE_PR_OUT=$pr_out
  rc=0
  jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
  expect_never_asked "$rc" "a pull request reading '$pr_out'"
done
reset
mk_task park "pr=$PR_URL" 'paused: PR is open and green, awaiting the merge word'
export FAKE_PR_RC=2
rc=0
jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
expect_never_asked "$rc" "a pull request whose state could not be read"
reset
mk_task park "pr=$PR_URL" 'paused: PR is open and green, awaiting the merge word'
export FAKE_PR_OUT='STATE: merged at 2026-10-05T10:00:00Z'
age_status park 500
handle_paused_stale test:fm-park park h1
assert_equals 0 "$(calls)" "a merged pull request's recheck never asks Jev"
assert_equals 1 "$(queued)" "a pause recheck whose pull request is no longer open is delivered on its cadence"
assert_contains "$(cat "$WAKES")" 'stale: test:fm-park (paused' "the delivered recheck is the ordinary pause recheck"
pass "deterministic first: a pull request that is merged, closed, blocked, or unreadable is delivered without asking"

# -- off, and every fallback: delivered exactly as before --------------------
reset
mk_task park "pr=$PR_URL" 'paused: waiting on the upstream release'
rm -f "$U/.env"
rc=0
jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
expect_never_asked "$rc" "the key absent"
for stub in error off 'routine 0.59' 'needs_firstmate 0.95' 'routine 0.7 0.4' 'maybe 0.99'; do
  reset
  mk_task park "pr=$PR_URL" 'paused: waiting on the upstream release'
  age_status park 500
  JEV_STUB=$stub
  handle_paused_stale test:fm-park park h1
  assert_equals 1 "$(calls)" "fallback '$stub': Jev was asked once"
  assert_equals 1 "$(queued)" "fallback '$stub': the recheck is queued as before"
  assert_equals 1 "$(woken)" "fallback '$stub': the recheck wakes as before"
  assert_contains "$(tlog)" 'jev triage delivered declared-pause-recheck' "fallback '$stub': the delivery reason is logged"
  assert_absent "$USTATE/.jev-triage-streak-park" "fallback '$stub': a delivery leaves no absorb streak"
done
pass "fallback: the key absent, an error, low confidence, or any other choice delivers the wake as before"

# -- the consecutive-absorb bound ----------------------------------------
reset
mk_task park "pr=$PR_URL" 'paused: waiting on the upstream release'
for n in 1 2 3 4 5 6; do
  jev_triage_pause_routine park "stale: test:fm-park" || fail "absorb $n refused"
done
rc=0
jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
[ "$rc" -ne 0 ] || fail "the wake after the absorb bound was absorbed"
assert_equals 6 "$(calls)" "the wake after the bound is delivered without asking"
assert_contains "$(tlog)" 'bound reached' "the bound delivery is logged"
jev_triage_pause_routine park "stale: test:fm-park" || fail "the count did not restart after the bound delivery"
pass "bound: after six routine answers in a row the next wake is delivered unasked"

}

# --- layer 3: a real watcher, the real library, a fake curl -----------------

unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_HOME FM_PR_STATE_BIN FAKE_PR_OUT FAKE_PR_RC

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# A parked worker: a live agent on a static pane, one already-seen working:
# line, then a newly appended paused: line, with a recorded open pull request.
make_parked() {  # <name> -> dir
  local dir state
  dir=$(make_case "$1"); state="$dir/state"
  mkdir -p "$dir/config" "$dir/log"
  install_fake_curl "$dir/fakebin"
  cat > "$dir/fakebin/fm-pr-state.sh" <<'SH'
#!/usr/bin/env bash
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf 'pr-state:secret-present\n' >> "${FAKE_CURL_LOG:?}/child-env"
else
  printf 'pr-state:clean\n' >> "${FAKE_CURL_LOG:?}/child-env"
fi
exit 0
SH
  chmod +x "$dir/fakebin/fm-pr-state.sh"
  printf 'idle at the prompt' > "$dir/pane.txt"
  fm_write_meta "$state/park.meta" "window=test:fm-park" "kind=ship" "pr=$PR_URL"
  printf 'working: implementing\n' > "$state/park.status"
  prime_status_seen "$state" "$state/park.status"
  printf 'paused: PR is open and green, awaiting the merge word\n' >> "$state/park.status"
  write_answer "$dir/response.json" routine 0.93
  printf '%s\n' "$dir"
}

watch_parked() {  # <dir> [env assignments...]
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_PR_STATE_BIN="$dir/fakebin/fm-pr-state.sh" \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the merge word' \
    FM_FAKE_TMUX_WINDOW=test:fm-park FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_FAKE_TMUX_CURRENT_COMMAND=claude \
    FAKE_CURL_LOG="$dir/log" FAKE_CURL_RESPONSE="$dir/response.json" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$dir/watch.out" &
}

wait_for_log() {  # <dir> <pid> <needle>: 1 if the watcher exits first
  local i=0
  while [ "$i" -lt 150 ]; do
    grep -Fq "$3" "$1/state/.watch-triage.log" 2>/dev/null && return 0
    kill -0 "$2" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

fail_parked() {  # <dir> <pid> <message>
  reap "$2"
  fail "$3: $(cat "$1/watch.out") $(cat "$1/state/.watch-triage.log" 2>/dev/null)"
}

dir=$(make_parked absorb)
watch_parked "$dir" TYPESAFE_API_KEY="$KEY"
pid=$!
wait_for_exit "$pid" 150 || fail_parked "$dir" "$pid" "a new paused: status signal was not delivered"
assert_grep 'signal:' "$dir/watch.out" "a new paused: status signal is delivered as a signal wake"
assert_grep 'park.status' "$dir/state/.wake-queue" "a new paused: status signal is queued"
assert_absent "$dir/log/calls" "a new paused: status signal is delivered without asking Jev"
cp "$dir/state/.wake-queue" "$dir/queue.delivered"
watch_parked "$dir" TYPESAFE_API_KEY="$KEY" FM_WATCH_HANDLING_SUCCESSOR=1
pid=$!
wait_for_log "$dir" "$pid" 'absorbed jev-routine declared-pause-recheck' \
  || fail_parked "$dir" "$pid" "the stale sight of a task with an open pull request was not absorbed"
kill -0 "$pid" 2>/dev/null || fail "the watcher exited after absorbing a routine wake"
reap "$pid"
[ ! -s "$dir/watch.out" ] || fail "an absorbed wake printed a reason: $(cat "$dir/watch.out")"
cmp -s "$dir/queue.delivered" "$dir/state/.wake-queue" || fail "an absorbed wake was queued: $(cat "$dir/state/.wake-queue")"
assert_equals "Authorization: Bearer $KEY" "$(cat "$dir/log/header")" "the watcher's key reaches curl on the fd header"
assert_not_contains "$(cat "$dir/log/argv")" "$KEY" "the watcher's key never appears on curl argv"
assert_no_grep 'secret-present' "$dir/log/child-env" "the key reached a watcher child's environment"
assert_grep 'pr-state:clean' "$dir/log/child-env" "the pull-request read ran as a watcher child"
assert_no_grep "$KEY" "$dir/state/.watch-triage.log" "the key reached the triage log"
assert_equals 'declared-pause-recheck' "$(jq -r '.state.wake.class' "$dir/log/body.1")" "the first question is the recheck class"
assert_equals '["wake"]' "$(jq -c '.questions | keys' "$dir/log/body.1")" "one fixed-choice question is asked"
assert_equals '["needs_firstmate","routine"]' "$(jq -c '.questions.wake.criteria | keys' "$dir/log/body.1")" "the choices are the fixed list"
pass "watcher: a new paused: status signal is delivered unasked; the later recheck of its open pull request is absorbed, logged, and unqueued; the key stays on the fd header"

dir=$(make_parked planted)
printf 'paused: PR is open and green, awaiting the merge word\npaused: pushed with GH_TOKEN=%s, awaiting the merge word\n' "$PLANTED" >> "$dir/state/park.status"
watch_parked "$dir" TYPESAFE_API_KEY="$KEY"
pid=$!
wait_for_exit "$pid" 150 || fail_parked "$dir" "$pid" "a status line holding a credential was not delivered"
watch_parked "$dir" TYPESAFE_API_KEY="$KEY" FM_WATCH_HANDLING_SUCCESSOR=1
pid=$!
wait_for_log "$dir" "$pid" 'absorbed jev-routine declared-pause-recheck' \
  || fail_parked "$dir" "$pid" "the recheck of a status line holding a credential was not asked"
reap "$pid"
assert_no_grep "$PLANTED" "$dir/log/body.1" "a status line holding a credential is not in the watcher's request"
assert_grep 'line withheld: looks like a credential' "$dir/log/body.1" "the watcher's status line is replaced by the placeholder"
pass "watcher: a status line holding a credential is withheld from the request"

# A parked worker whose paused: signal an earlier watcher run already reported;
# the later run is the successor that supervises while that wake is handled.
make_reported() {  # <name> -> dir
  local dir pid
  dir=$(make_parked "$1")
  watch_parked "$dir"
  pid=$!
  wait_for_exit "$pid" 150 || fail_parked "$dir" "$pid" "$1: the paused: status signal was not delivered"
  printf '%s\n' "$dir"
}

dir=$(make_reported turn-end)
: > "$dir/state/park.turn-ended"
watch_parked "$dir" TYPESAFE_API_KEY="$KEY" FM_WATCH_HANDLING_SUCCESSOR=1
pid=$!
wait_for_exit "$pid" 150 || fail_parked "$dir" "$pid" "a bare turn-end from a paused worker was not delivered"
assert_grep 'signal:' "$dir/watch.out" "a bare turn-end from a paused worker is delivered as a signal wake"
assert_grep 'park.turn-ended' "$dir/state/.wake-queue" "a bare turn-end from a paused worker is queued"
assert_absent "$dir/log/calls" "a bare turn-end is delivered without asking Jev"
pass "watcher: a bare turn-end from an already paused worker with an open pull request is delivered unasked"

dir=$(make_parked no-pr)
fm_write_meta "$dir/state/park.meta" "window=test:fm-park" "kind=ship"
prime_status_seen "$dir/state" "$dir/state/park.status"
watch_parked "$dir" TYPESAFE_API_KEY="$KEY" FM_HEARTBEAT=1
pid=$!
wait_for_exit "$pid" 150 || fail_parked "$dir" "$pid" "a paused task with no pull request was not delivered under absorbed heartbeats"
assert_grep 'absorbed heartbeat' "$dir/state/.watch-triage.log" "a heartbeat was absorbed before the stale sight"
assert_grep 'stale:' "$dir/watch.out" "a paused task with no pull request is delivered after an absorbed heartbeat"
assert_grep 'stale: test:fm-park' "$dir/state/.wake-queue" "a paused task with no pull request is queued after an absorbed heartbeat"
assert_absent "$dir/log/calls" "an absorbed heartbeat makes nothing eligible for Jev"
pass "watcher: with real heartbeats absorbed, a paused task with no pull request is still delivered unasked"

dir=$(make_reported needs)
write_answer "$dir/response.json" needs_firstmate 0.9
watch_parked "$dir" TYPESAFE_API_KEY="$KEY" FM_WATCH_HANDLING_SUCCESSOR=1
pid=$!
wait_for_exit "$pid" 150 || fail_parked "$dir" "$pid" "a needs_firstmate answer did not deliver the wake"
assert_grep 'stale:' "$dir/watch.out" "a needs_firstmate answer delivers the stale wake"
assert_grep 'stale: test:fm-park' "$dir/state/.wake-queue" "a needs_firstmate answer queues the stale wake"
assert_present "$dir/log/calls" "a needs_firstmate answer came from one Jev call"
pass "watcher: a needs_firstmate answer delivers the wake as before"

dir=$(make_reported timeout)
watch_parked "$dir" TYPESAFE_API_KEY="$KEY" FM_WATCH_HANDLING_SUCCESSOR=1 FAKE_CURL_FAIL=28
pid=$!
wait_for_exit "$pid" 150 || fail_parked "$dir" "$pid" "a timed-out Jev call did not deliver the wake"
assert_grep 'stale:' "$dir/watch.out" "a timed-out Jev call delivers the stale wake"
assert_grep 'jev triage delivered declared-pause-recheck (error: http 000' "$dir/state/.watch-triage.log" "the timeout is logged as the delivery reason"
pass "watcher: a timed-out Jev call delivers the wake as before"

dir=$(make_reported no-key)
watch_parked "$dir" FM_WATCH_HANDLING_SUCCESSOR=1
pid=$!
wait_for_exit "$pid" 150 || fail_parked "$dir" "$pid" "the wake was not delivered with the key absent"
assert_grep 'stale:' "$dir/watch.out" "with the key absent the stale wake is delivered"
assert_absent "$dir/log/calls" "with the key absent no Jev call is made"
pass "watcher: off unless the key is present"

printf '# all fm-jev-wake-triage tests passed\n'
