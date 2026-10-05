#!/usr/bin/env bash
# tests/fm-jev-wake-triage.test.sh - the opt-in routine-wake triage in
# bin/fm-watch.sh (config/jev-wake-triage) and the shared Jev caller it uses
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
  : > "$UCONFIG/jev-wake-triage"
  printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$U/.env"
  TYPESAFE_API_KEY_PRIVATE=
  AGENT_STATE=alive
  JEV_STUB='routine 0.93'
  unset FAKE_PR_OUT FAKE_PR_RC
  PAUSE_RESURFACE_SECS=100
  JEV_TRIAGE_MAX_STREAK=6
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
mk_task park '' 'working: implementing' 'paused: PR is open and green, awaiting the merge word'
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
mk_task park '' 'paused: waiting on the upstream release'
surface_nonterminal_stale test:fm-park h1
assert_equals 1 "$(calls)" "a live parked worker's first stale sight asks Jev"
assert_equals 0 "$(queued)" "a routine first stale sight queues nothing"
assert_present "$USTATE/.paused-resurfaced-test_fm-park" "a routine first sight records the declaration's throttle"
surface_nonterminal_stale test:fm-park h2
assert_equals 1 "$(calls)" "a new pane hash under the same declaration is not asked again"
assert_equals 0 "$(queued)" "a new pane hash under the same declaration stays absorbed"
pass "eligible: a live parked worker's first stale sight is absorbed and bounded per declaration"

reset
mk_task park '' 'paused: waiting on the upstream release'
age_status park 500
wedge_defer_wait test:fm-park park "$USTATE/.stale-since-test_fm-park" 'non-terminal stale' 300 declared
assert_equals 1 "$(calls)" "a due declared-wait deferral asks Jev"
assert_equals 0 "$(queued)" "a routine declared-wait deferral queues nothing"
reset
mk_task park '' 'captain-held [key=route]: tracked by task-decision-route'
age_status park 500
wedge_defer_wait test:fm-park park "$USTATE/.stale-since-test_fm-park" 'non-terminal stale' 300 held
assert_equals 0 "$(calls)" "a captain-held recheck never asks Jev"
assert_equals 1 "$(queued)" "a captain-held recheck is delivered"
reset
mk_task park '' 'captain-held [key=route]: tracked by task-decision-route'
age_status park 500
handle_paused_stale test:fm-park park h1
assert_equals 0 "$(calls)" "a captain-held stale never asks Jev"
assert_equals 1 "$(queued)" "a captain-held stale is delivered"
pass "eligible: a declared-wait deferral is absorbed; a captain-held wait is never offered"

# -- eligible: the two signal classes ---------------------------------------
reset
mk_task park '' 'working: implementing'
fm_wake_status_mark_current "$USTATE" "$USTATE/park.status"
printf 'paused: rate limited until the hourly reset\n' >> "$USTATE/park.status"
jev_triage_signal_routine "$USTATE/park.status" || fail "a signal whose only new line is paused: was not absorbed"
assert_equals 'paused-status-signal' "$(jq -r '.wake.class' "$U/jev-state.json")" "a new paused: line is the paused-status-signal class"
assert_equals 'signal: park.status' "$(jq -r '.wake.reason' "$U/jev-state.json")" "the signal reason names files, not home paths"
reset
mk_task park '' 'paused: rate limited until the hourly reset'
: > "$USTATE/park.turn-ended"
jev_triage_signal_routine "$USTATE/park.turn-ended" || fail "a bare turn-end from a paused worker was not absorbed"
assert_equals 'paused-turn-end' "$(jq -r '.wake.class' "$U/jev-state.json")" "a bare turn-end is the paused-turn-end class"
pass "eligible: a paused: status signal and a bare turn-end from a paused worker are absorbed"

# -- eligible: a contributions observation timeout --------------------------
reset
jev_triage_contributions_routine "contributions: observation unavailable for $PR_URL: gh pr view timed out after 30s" \
  || fail "a contributions observation timeout was not absorbed"
assert_equals 'contributions-observation-timeout' "$(jq -r '.wake.class' "$U/jev-state.json")" "the timeout is its own class"
reset
rc=0
jev_triage_contributions_routine "contributions: observation unavailable for $PR_URL: gh pr view failed: HTTP 401" || rc=$?
expect_never_asked "$rc" "a contributions failure that is not a timeout"
reset
rc=0
jev_triage_contributions_routine "contributions: observation unavailable for $PR_URL: gh pr view timed out after 30s
contributions: 1 unreadable durable record(s)" || rc=$?
expect_never_asked "$rc" "a contributions check that also reports another diagnostic"
pass "eligible: only a contributions check made solely of forge-read timeouts is offered"

# -- never eligible: status events that belong to firstmate -------------------
for event in 'needs-decision [key=scope]: pick an option' 'blocked: cannot reach the host' \
  'failed: the build broke' "done: PR $PR_URL checks green" 'working: resumed' \
  'captain-held [key=route]: tracked by task-decision-route'; do
  reset
  mk_task park '' 'paused: waiting on the upstream release'
  fm_wake_status_mark_current "$USTATE" "$USTATE/park.status"
  printf '%s\n' "$event" >> "$USTATE/park.status"
  rc=0
  jev_triage_signal_routine "$USTATE/park.status" || rc=$?
  expect_never_asked "$rc" "a new '${event%%:*}' status event"
  reset
  mk_task park '' 'paused: waiting on the upstream release' "$event"
  : > "$USTATE/park.turn-ended"
  rc=0
  jev_triage_signal_routine "$USTATE/park.turn-ended" || rc=$?
  expect_never_asked "$rc" "a turn-end after a '${event%%:*}' status event"
  rc=0
  jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
  expect_never_asked "$rc" "a stale wake after a '${event%%:*}' status event"
done
reset
mk_task park '' 'needs-decision [key=scope]: pick an option' 'paused: waiting on the upstream release'
rc=0
jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
expect_never_asked "$rc" "a task with an open keyed decision"
reset
mk_task park '' 'needs-decision [key=scope]: pick an option' 'resolved [key=scope]: option a' 'paused: waiting on the upstream release'
jev_triage_pause_routine park "stale: test:fm-park" || fail "a closed decision before the pause must not block eligibility"
pass "never eligible: needs-decision, blocked, failed, done, working, captain-held, or an open keyed decision"

# -- never eligible: endpoint, kind, posture, and shape gates -----------------
for state in dead missing ambiguous unreadable unverified; do
  reset
  mk_task park '' 'paused: waiting on the upstream release'
  AGENT_STATE=$state
  rc=0
  jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
  expect_never_asked "$rc" "an endpoint whose agent reads $state"
done
reset
mk_task park '' 'paused: waiting on the upstream release'
fm_write_meta "$USTATE/park.meta" "window=test:fm-park" "kind=secondmate"
rc=0
jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
expect_never_asked "$rc" "a secondmate"
reset
mk_task park '' 'paused: waiting on the upstream release'
: > "$USTATE/.afk"
rc=0
jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
expect_never_asked "$rc" "the away daemon owning triage"
reset
mk_task park '' 'paused: waiting on the upstream release'
: > "$USTATE/.afk-contract"
rc=0
jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
expect_never_asked "$rc" "the away-posture record existing"
reset
mk_task park '' 'paused: waiting for the window until 2020-01-01T00:00Z'
rc=0
jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
expect_never_asked "$rc" "a declared clearing time that has passed"
reset
mk_task park '' 'paused: waiting on the upstream release'
mk_task other '' 'paused: waiting on the upstream release'
: > "$USTATE/park.turn-ended"; : > "$USTATE/other.turn-ended"
rc=0
jev_triage_signal_routine "$USTATE/park.turn-ended" "$USTATE/other.turn-ended" || rc=$?
expect_never_asked "$rc" "a signal batch spanning two tasks"
pass "never eligible: a dead, missing, or unproven endpoint, a secondmate, the away posture, a passed clearing time, a multi-task batch"

# -- the deterministic pull-request read settles what it can -----------------
reset
mk_task park "pr=$PR_URL" 'paused: PR is open and green, awaiting the merge word'
jev_triage_pause_routine park "stale: test:fm-park" || fail "an open pull request with nothing blocking was not offered"
assert_equals "$PR_URL" "$(cat "$FAKE_PR_CALLS")" "the recorded pull request is read before Jev is asked"
assert_contains "$(jq -r '.wake.evidence[0].pull_request' "$U/jev-state.json")" 'open' "the open pull request rides in the evidence"
for pr_out in 'STATE: merged at 2026-10-05T10:00:00Z' 'STATE: closed' 'REQUIRED CHECK: test (FAILURE)' \
  'MERGEABILITY: conflicting' 'REVIEW DECISION: CHANGES_REQUESTED'; do
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
mk_task park '' 'paused: waiting on the upstream release'
rm -f "$UCONFIG/jev-wake-triage"
rc=0
jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
expect_never_asked "$rc" "the opt-in flag absent"
reset
mk_task park '' 'paused: waiting on the upstream release'
rm -f "$U/.env"
rc=0
jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
expect_never_asked "$rc" "the key absent"
for stub in error off 'routine 0.59' 'needs_firstmate 0.95' 'routine 0.7 0.4' 'maybe 0.99'; do
  reset
  mk_task park '' 'paused: waiting on the upstream release'
  age_status park 500
  JEV_STUB=$stub
  handle_paused_stale test:fm-park park h1
  assert_equals 1 "$(calls)" "fallback '$stub': Jev was asked once"
  assert_equals 1 "$(queued)" "fallback '$stub': the recheck is queued as before"
  assert_equals 1 "$(woken)" "fallback '$stub': the recheck wakes as before"
  assert_contains "$(tlog)" 'jev triage delivered declared-pause-recheck' "fallback '$stub': the delivery reason is logged"
  assert_absent "$USTATE/.jev-triage-streak-park" "fallback '$stub': a delivery leaves no absorb streak"
done
pass "fallback: flag or key absent, an error, low confidence, or any other choice delivers the wake as before"

# -- the consecutive-absorb bound ----------------------------------------
reset
JEV_TRIAGE_MAX_STREAK=2
mk_task park '' 'paused: waiting on the upstream release'
jev_triage_pause_routine park "stale: test:fm-park" || fail "first absorb refused"
jev_triage_pause_routine park "stale: test:fm-park" || fail "second absorb refused"
rc=0
jev_triage_pause_routine park "stale: test:fm-park" || rc=$?
[ "$rc" -ne 0 ] || fail "the wake after the absorb bound was absorbed"
assert_equals 2 "$(calls)" "the wake after the bound is delivered without asking"
assert_contains "$(tlog)" 'bound reached' "the bound delivery is logged"
jev_triage_pause_routine park "stale: test:fm-park" || fail "the count did not restart after the bound delivery"
pass "bound: after FM_JEV_TRIAGE_MAX_STREAK routine answers in a row the next wake is delivered unasked"

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

dir=$(make_parked absorb)
: > "$dir/config/jev-wake-triage"
watch_parked "$dir" TYPESAFE_API_KEY="$KEY"
pid=$!
wait_for_log "$dir" "$pid" 'absorbed jev-routine paused-status-signal' \
  || { reap "$pid"; fail "the paused: signal was not absorbed: $(cat "$dir/watch.out") $(cat "$dir/state/.watch-triage.log" 2>/dev/null)"; }
wait_for_log "$dir" "$pid" 'absorbed jev-routine declared-pause-recheck' \
  || { reap "$pid"; fail "the parked worker's stale sight was not absorbed: $(cat "$dir/watch.out") $(cat "$dir/state/.watch-triage.log" 2>/dev/null)"; }
kill -0 "$pid" 2>/dev/null || fail "the watcher exited after absorbing routine wakes"
reap "$pid"
[ ! -s "$dir/watch.out" ] || fail "an absorbed wake printed a reason: $(cat "$dir/watch.out")"
[ ! -s "$dir/state/.wake-queue" ] || fail "an absorbed wake was queued: $(cat "$dir/state/.wake-queue")"
assert_equals "Authorization: Bearer $KEY" "$(cat "$dir/log/header")" "the watcher's key reaches curl on the fd header"
assert_not_contains "$(cat "$dir/log/argv")" "$KEY" "the watcher's key never appears on curl argv"
assert_no_grep 'secret-present' "$dir/log/child-env" "the key reached a watcher child's environment"
assert_grep 'pr-state:clean' "$dir/log/child-env" "the pull-request read ran as a watcher child"
assert_no_grep "$KEY" "$dir/state/.watch-triage.log" "the key reached the triage log"
assert_equals 'paused-status-signal' "$(jq -r '.state.wake.class' "$dir/log/body.1")" "the first question is the signal class"
assert_equals '["wake"]' "$(jq -c '.questions | keys' "$dir/log/body.1")" "one fixed-choice question is asked"
assert_equals '["needs_firstmate","routine"]' "$(jq -c '.questions.wake.criteria | keys' "$dir/log/body.1")" "the choices are the fixed list"
pass "watcher: a routine paused: signal and its stale sight are absorbed, logged, and unqueued; the key stays on the fd header"

dir=$(make_parked needs)
: > "$dir/config/jev-wake-triage"
write_answer "$dir/response.json" needs_firstmate 0.9
watch_parked "$dir" TYPESAFE_API_KEY="$KEY"
pid=$!
wait_for_exit "$pid" 150 || fail "a needs_firstmate answer did not deliver the wake"
assert_grep 'signal:' "$dir/watch.out" "a needs_firstmate answer delivers the signal wake"
assert_grep 'park.status' "$dir/state/.wake-queue" "a needs_firstmate answer queues the signal wake"
pass "watcher: a needs_firstmate answer delivers the wake as before"

dir=$(make_parked timeout)
: > "$dir/config/jev-wake-triage"
watch_parked "$dir" TYPESAFE_API_KEY="$KEY" FAKE_CURL_FAIL=28
pid=$!
wait_for_exit "$pid" 150 || fail "a timed-out Jev call did not deliver the wake"
assert_grep 'signal:' "$dir/watch.out" "a timed-out Jev call delivers the signal wake"
assert_grep 'jev triage delivered paused-status-signal (error: http 000' "$dir/state/.watch-triage.log" "the timeout is logged as the delivery reason"
pass "watcher: a timed-out Jev call delivers the wake as before"

dir=$(make_parked no-flag)
watch_parked "$dir" TYPESAFE_API_KEY="$KEY"
pid=$!
wait_for_exit "$pid" 150 || fail "the wake was not delivered with the opt-in flag absent"
assert_grep 'signal:' "$dir/watch.out" "with the flag absent the signal wake is delivered"
assert_absent "$dir/log/calls" "with the flag absent no Jev call is made"
dir=$(make_parked no-key)
: > "$dir/config/jev-wake-triage"
watch_parked "$dir"
pid=$!
wait_for_exit "$pid" 150 || fail "the wake was not delivered with the key absent"
assert_grep 'signal:' "$dir/watch.out" "with the key absent the signal wake is delivered"
assert_absent "$dir/log/calls" "with the key absent no Jev call is made"
pass "watcher: off unless both the opt-in flag and the key are present"

printf '# all fm-jev-wake-triage tests passed\n'
