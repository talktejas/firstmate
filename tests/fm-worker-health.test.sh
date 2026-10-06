#!/usr/bin/env bash
# tests/fm-worker-health.test.sh - the advisory worker health line
# (bin/fm-worker-health.sh, off unless TYPESAFE_API_KEY is present).
#
# Two layers, neither of which touches the network, each pinned to a fixture
# home so no real key can load:
#   - the decisions, with the script sourced, the deterministic read
#     (bin/fm-crew-state.sh, covered by tests/fm-crew-state.test.sh) replaced by
#     a fixed line, and fm_jev_choice stubbed at the library boundary, so what
#     code decides alone is asserted by whether the model was asked at all;
#   - the real library with a fake curl, proving the request shape and that the
#     key reaches curl on a file descriptor and no child environment, argv, or
#     output, and the real executable end to end on a task code decides.
# The library's own interface is tests/fm-jev-wake-triage.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-worker-health.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-health)
KEY='test-key-7c2e-never-on-argv'
ON="$TMP_ROOT/home-on"
OFF="$TMP_ROOT/home-off"
T=task-1
CALLS="$TMP_ROOT/jev-calls"
ERR="$TMP_ROOT/stderr"
PANE='state: unknown · source: pane · harness idle (claude-hook)'
LOGGED='state: working · source: status-log · tests running'
unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE TYPESAFE_API_KEY

mkhome() {  # <home> <key:1|0>
  mkdir -p "$1/state/$T.inbox/handled" "$1/config"
  [ "$2" -eq 0 ] || printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$1/.env"
  printf 'kind=ship\nproject=/somewhere/projects/some-proj\n' > "$1/state/$T.meta"
  {
    for i in 1 2 3; do printf 'working: [2026-10-06T00:00:0%sZ] old event %s\n' "$i" "$i"; done
    printf 'working: [2026-10-06T00:01:00Z] setup done\n'
    printf 'working: [2026-10-06T00:02:00Z] HEAD-OF-LONG-LINE %s END-OF-LONG-LINE\n' "$(printf 'x%.0s' $(seq 1 600))"
    printf 'working: [2026-10-06T00:03:00Z] bug reproduced\n'
    printf 'working: [2026-10-06T00:04:00Z] fix implemented\n'
    printf 'working: [2026-10-06T00:05:00Z] tests running\n'
  } > "$1/state/$T.status"
  : > "$1/state/$T.turn-ended"
  printf 'SECRET-STEER-TEXT\n' > "$1/state/$T.inbox/001.msg"
  printf 'SECRET-HANDLED-TEXT\n' > "$1/state/$T.inbox/handled/000.msg"
}
mkhome "$ON" 1
mkhome "$OFF" 0

# --- layer 1: the decisions, Jev stubbed at the library boundary -------------

# Runs health_main with the deterministic read answering CREW_LINE and
# fm_jev_choice replaced by a stub answering STUB_CHOICE at STUB_CONF and
# recording each call. STUB_FAIL makes the call an error.
run_stubbed() {  # <home> <crew-line> [args...]
  local home=$1 crew=$2
  shift 2
  rm -f "$CALLS" "$TMP_ROOT/state.json" "$TMP_ROOT/criteria.json"
  # shellcheck disable=SC2016 # The inner shell expands its own variables.
  FM_HOME="$home" CREW_LINE="$crew" CALLS="$CALLS" OUT="$TMP_ROOT" bash -c '
      # shellcheck source=/dev/null
      . "$1"
      shift
      health_crew_state() { printf "%s\n" "$CREW_LINE"; }
      fm_jev_choice() {
        printf "%s\n" "$1" >> "$CALLS"
        cat "$3" > "$OUT/state.json"
        cat "$4" > "$OUT/criteria.json"
        FM_JEV_ERROR="" FM_JEV_LATENCY_MS=7
        if [ -n "${STUB_FAIL:-}" ]; then
          FM_JEV_STATUS=error FM_JEV_ERROR="stub is down"
          return 1
        fi
        FM_JEV_STATUS=ok FM_JEV_CHOICE=${STUB_CHOICE:-stuck} FM_JEV_CONFIDENCE=${STUB_CONF:-0.9}
        FM_JEV_PROBABILITIES="$FM_JEV_CHOICE=$FM_JEV_CONFIDENCE"
        FM_JEV_ANSWER="{\"choice\":\"$FM_JEV_CHOICE\",\"confidence\":$FM_JEV_CONFIDENCE}"
        return 0
      }
      health_main "$@"
    ' _ "$TOOL" "$@" 2> "$ERR"
}
calls() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }
unasked() {  # <output> <crew-line> <label> <stderr-fragment>
  assert_equals "$2" "$1" "$3: stdout is the crew-state line alone"
  assert_equals 0 "$(calls)" "$3: the model is not asked"
  assert_contains "$(cat "$ERR")" "$4" "$3: stderr says why"
}

out=$(run_stubbed "$OFF" "$PANE" "$T"); code=$?
expect_code 0 "$code" "no key exits 0"
unasked "$out" "$PANE" "no key" 'off, TYPESAFE_API_KEY absent'
pass "without the key the output is the deterministic read, byte for byte"

for line in \
  'state: working · source: run-step · review running' \
  'state: parked · source: run-step · awaiting_approval' \
  'state: done · source: run-step · passed' \
  'state: failed · source: run-step · failed at test' \
  'state: unknown · source: none · backend target gone: fm:1.0' \
  'state: unknown · source: none · backend unreachable (tmux endpoint state: unknown)' \
  'state: unknown · source: remote-endpoint · alive on host (an idle secondmate is healthy)'; do
  out=$(run_stubbed "$ON" "$line" "$T")
  unasked "$out" "$line" "${line%% · detail*}" 'code decided'
done
printf 'kind=secondmate\n' > "$ON/state/$T.meta"
out=$(run_stubbed "$ON" "$PANE" "$T")
unasked "$out" "$PANE" "a secondmate" 'kind=secondmate is never asked about'
printf 'kind=ship\nremote_host=box\n' > "$ON/state/$T.meta"
out=$(run_stubbed "$ON" "$LOGGED" "$T")
unasked "$out" "$LOGGED" "a remote endpoint" 'a remote endpoint is never asked about'
printf 'kind=ship\n' > "$ON/state/$T.meta"
pass "a validation run, a gone, unreachable, or remote endpoint, and a secondmate are decided by code alone"

for choice in working stuck waiting finished; do
  out=$(STUB_CHOICE=$choice STUB_CONF=0.6 run_stubbed "$ON" "$PANE" "$T"); code=$?
  expect_code 0 "$code" "$choice exits 0"
  assert_equals "$PANE
health: $choice (confidence 0.6, advice only)" "$out" "$choice at the floor prints the crew-state line and one health line"
  assert_equals 1 "$(calls)" "$choice: one question"
done
out=$(run_stubbed "$ON" "$LOGGED" "$T")
assert_contains "$out" 'health: stuck (confidence 0.9, advice only)' "a status-log read is asked about too"
printf 'kind=scout\n' > "$ON/state/$T.meta"
out=$(run_stubbed "$ON" "$PANE" "$T")
assert_contains "$out" 'health: stuck' "a scout is asked about"
assert_equals scout "$(jq -r .worker.kind "$TMP_ROOT/state.json")" "the kind rides in the evidence"
printf 'kind=ship\n' > "$ON/state/$T.meta"
out=$(STUB_CONF=0.59 run_stubbed "$ON" "$PANE" "$T"); code=$?
expect_code 0 "$code" "low confidence exits 0"
assert_equals "$PANE" "$out" "an answer below the floor prints no health line"
assert_contains "$(cat "$ERR")" 'below the confidence floor' "low confidence says so"
out=$(STUB_FAIL=1 run_stubbed "$ON" "$PANE" "$T"); code=$?
expect_code 0 "$code" "a failed call exits 0"
assert_equals "$PANE" "$out" "a failed call prints no health line"
assert_contains "$(cat "$ERR")" 'no answer: stub is down' "a failed call says why"
pass "a fallback read gets one advisory line only at or above the shared floor"

run_stubbed "$ON" "$PANE" "$T" >/dev/null
sent=$(cat "$TMP_ROOT/state.json")
assert_equals '["finished","stuck","waiting","working"]' "$(jq -c 'keys' "$TMP_ROOT/criteria.json")" "the four fixed choices"
assert_equals "$PANE" "$(jq -r .worker.current_state <<<"$sent")" "the crew-state line rides in the evidence"
assert_equals 6 "$(jq '.worker.status_events | length' <<<"$sent")" "only the newest six status lines are sent"
assert_not_contains "$sent" 'old event 2' "an older status line is not sent"
assert_contains "$(jq -r '.worker.status_events[5]' <<<"$sent")" 'tests running' "the newest status line is last"
long=$(jq -r '.worker.status_events[2]' <<<"$sent")
assert_equals 400 "${#long}" "a long status line is cut to the bound"
assert_contains "$long" 'HEAD-OF-LONG-LINE' "a long status line keeps its head"
assert_contains "$long" 'END-OF-LONG-LINE' "a long status line keeps its end"
assert_equals '1|0|0|null' "$(jq -r '.worker | "\(.unread_instructions)|\(.oldest_unread_instruction_minutes)|\(.minutes_since_turn_ended)|\(.minutes_since_activity)"' <<<"$sent")" \
  "unacknowledged instructions are counted, ages are whole minutes, and a missing marker is null"
assert_not_contains "$sent" 'SECRET-STEER-TEXT' "the text of an inbox message is not sent"
assert_not_contains "$sent" 'SECRET-HANDLED-TEXT' "an acknowledged inbox message is not counted or sent"
assert_not_contains "$sent" 'some-proj' "the project is not sent"
run_stubbed "$ON" "$PANE" >/dev/null; expect_code 2 $? "no task id is a usage error"
run_stubbed "$ON" "$PANE" ../x >/dev/null; expect_code 2 $? "a path-shaped task id is a usage error"
pass "the evidence is the read, the newest status lines, ages, and an instruction count, and nothing else"

# --- layer 2: the real library, a fake curl ----------------------------------

FAKEBIN="$TMP_ROOT/fakebin"
LOG="$TMP_ROOT/curl-log"
mkdir -p "$FAKEBIN" "$LOG"
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
log=${FAKE_CURL_LOG:?}
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf 'secret-present\n' >> "$log/child-env"
else
  printf 'clean\n' >> "$log/child-env"
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
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '200'
SH
chmod +x "$FAKEBIN/curl"
printf '%s' '{"model":"jev-test","answers":{"health":{"choice":"waiting","confidence":0.8,"probabilities":{"working":0.1,"stuck":0.05,"waiting":0.8,"finished":0.05}}}}' \
  > "$TMP_ROOT/response.json"
PLANTED="ghp_$(printf 'a%.0s' $(seq 1 36))"
printf 'blocked: [2026-10-06T00:06:00Z] push refused with GH_TOKEN=%s\n' "$PLANTED" >> "$OFF/state/$T.status"
cp "$OFF/state/$T.status" "$TMP_ROOT/status.before"

real_lib() {  # [env assignments...] -> health_main on $OFF with only the deterministic read fixed
  # shellcheck disable=SC2016 # The inner shell expands its own variables.
  env PATH="$FAKEBIN:$PATH" FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$TMP_ROOT/response.json" \
    FM_HOME="$OFF" CREW_LINE="$PANE" "$@" bash -c '
      # shellcheck source=/dev/null
      . "$1"
      health_crew_state() { printf "%s\n" "$CREW_LINE"; }
      health_main "$2"
    ' _ "$TOOL" "$T" 2>&1
}
out=$(real_lib TYPESAFE_API_KEY="$KEY"); code=$?
expect_code 0 "$code" "a real-library run exits 0"
assert_equals 1 "$(cat "$LOG/calls")" "one request through the library"
assert_contains "$out" 'health: waiting (confidence 0.8, advice only)' "a well-formed confident answer is printed"
assert_equals '["health"]' "$(jq -c '.questions | keys' "$LOG/body.1")" "one question"
assert_equals 'choice' "$(jq -r '.questions.health.type' "$LOG/body.1")" "the question is a fixed Choice"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "the key reaches curl on the fd header"
assert_not_contains "$(cat "$LOG/argv")" "$KEY" "the key never appears on curl argv"
assert_equals 'clean' "$(sort -u "$LOG/child-env")" "the key is absent from every child environment"
assert_not_contains "$out" "$KEY" "the key never appears in the output"
assert_no_grep "$PLANTED" "$LOG/body.1" "a status line holding a credential is not in the request"
assert_contains "$(jq -r '.state.worker.status_events[5]' "$LOG/body.1")" 'line withheld: looks like a credential' "the credential line is replaced by the placeholder"
assert_equals "$(cat "$TMP_ROOT/status.before")" "$(cat "$OFF/state/$T.status")" "nothing is written to the task's status record"
printf '%s' '{"model":"jev-test","answers":{"health":{"choice":"dead","confidence":0.9,"probabilities":{"dead":1}}}}' > "$TMP_ROOT/response.json"
out=$(real_lib TYPESAFE_API_KEY="$KEY")
assert_not_contains "$out" 'advice only)' "an answer outside the four choices prints no health line"
rm -rf "$LOG"; mkdir -p "$LOG"
out=$(real_lib 2>&1)
assert_not_contains "$out" 'advice only)' "the real library without a key prints no health line"
assert_absent "$LOG/calls" "the real library without a key makes no request"
pass "real library: one fixed four-way question through the shared caller; key on the fd header only"

rm -rf "$LOG"; mkdir -p "$LOG"
out=$(env PATH="$FAKEBIN:$PATH" FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$TMP_ROOT/response.json" \
  TYPESAFE_API_KEY="$KEY" FM_HOME="$ON" "$TOOL" no-such-task 2>/dev/null); code=$?
expect_code 0 "$code" "the executable exits 0"
assert_equals 'state: unknown · source: none · no metadata for no-such-task' "$out" "the executable prints the real deterministic read"
assert_absent "$LOG/calls" "the executable asks nothing about a task code decides"
pass "executable: the real deterministic read is printed and decides a task with no record"

printf '# all fm-worker-health tests passed\n'
