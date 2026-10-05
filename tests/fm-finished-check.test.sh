#!/usr/bin/env bash
# tests/fm-finished-check.test.sh - the worker stop hook's "is it really
# finished?" check (bin/fm-finished-check.sh), off unless TYPESAFE_API_KEY is
# present.
#
# Two layers, neither of which touches the network:
#   - the decision, with the script sourced and fm_jev_choice stubbed at the
#     library boundary, so every fact gate is asserted by which questions were
#     asked at all and by the one line the worker is then sent back with;
#   - the real executable with the real library and a fake curl, proving the
#     hook output and that the key reaches no child environment or argv.
# The Stop hook command that runs it is tests/fm-busy-adapter-wiring.test.sh.
# Every case runs against a fixture home, so no real key can load.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-finished-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-finished-check)
KEY='test-key-9c1d-never-on-argv'
ID=fc-task
HOME_ON="$TMP_ROOT/home"
HOME_OFF="$TMP_ROOT/home-off"
STATE="$HOME_ON/state"
WT="$TMP_ROOT/wt"
ASKED="$TMP_ROOT/asked"
SENT="$TMP_ROOT/sent"

mkdir -p "$STATE" "$HOME_OFF/state"
printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$HOME_ON/.env"
git init -q "$WT"
GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' git -C "$WT" -c user.name=t -c user.email=t@example.invalid \
  commit -q --allow-empty -m base --date '2020-01-01T00:00:00Z'
"$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID" >/dev/null || fail "could not arm the busy record"

# reset [<status-line> [fresh|stale]]: a clean worktree, a busy record that
# opened the turn at a fixed time, and an optional status line on either side.
reset() {
  : > "$ASKED"
  : > "$SENT"
  rm -f "$STATE/$ID.status" "$WT/dirty"
  touch -t 202601010000 "$STATE/$ID.busy-state"
  [ $# -eq 0 ] && return 0
  printf '%s\n' "$1" > "$STATE/$ID.status"
  if [ "${2:-fresh}" = fresh ]; then
    touch -t 202601010001 "$STATE/$ID.status"
  else
    touch -t 202512310000 "$STATE/$ID.status"
  fi
}

stop_json() {  # <closing-message> [<extra-jq-object>]
  jq -cn --arg m "$1" --argjson extra "${2:-{\}}" '{stop_hook_active: false, last_assistant_message: $m} + $extra'
}

# check <home> <hook-json>: source the script, stub the library boundary, run.
# STUB_YES lists the questions answered yes; STUB_CONF is every answer's
# confidence; STUB_MODE=error makes the first call fail.
check() {
  (
    # shellcheck source=bin/fm-finished-check.sh
    . "$CHECK"
    fm_jev_choice() {
      local choice=no yes
      printf '%s\n' "$1" >> "$ASKED"
      cat "$3" >> "$SENT"
      if [ "${STUB_MODE:-ok}" = error ]; then
        FM_JEV_STATUS=error
        return 1
      fi
      case " ${STUB_YES:-} " in *" $1 "*) choice=yes ;; esac
      yes=${STUB_CONF:-0.9}
      [ "$choice" = yes ] || yes=$(jq -n --argjson c "$yes" '1 - $c')
      # shellcheck disable=SC2034 # read by the sourced script
      FM_JEV_ANSWER=$(jq -cn --arg choice "$choice" --argjson c "${STUB_CONF:-0.9}" --argjson yes "$yes" \
        '{choice: $choice, confidence: $c, probabilities: {yes: $yes, no: (1 - $yes)}}')
      # shellcheck disable=SC2034
      FM_JEV_STATUS=ok
      return 0
    }
    fm_finished_check "$1" "$1/state" "$ID" "$WT"
  ) <<<"$2"
}

asked() { tr '\n' ' ' < "$ASKED" | sed 's/ $//'; }

# --- layer 1: the decision ---------------------------------------------------

reset
out=$(STUB_YES='asks_question partial_or_blocked claims_finished' check "$HOME_OFF" "$(stop_json 'All done?')")
assert_equals '' "$out" "no key must end the turn as before"
assert_equals '' "$(asked)" "no key must ask nothing"
pass "absent key: nothing asked, turn ends"

reset
out=$(check "$HOME_ON" "$(stop_json 'On branch fm/x.')")
assert_equals '' "$out" "all-no answers must end the turn"
assert_equals 'asks_question partial_or_blocked' "$(asked)" "an unreported clean stop asks only the two message questions"
pass "unreported stop with nothing changed: two questions, no send-back"

reset
out=$(STUB_YES='asks_question partial_or_blocked' check "$HOME_ON" "$(stop_json 'Should I use A or B?')")
assert_equals block "$(jq -r .decision <<<"$out")" "a question nobody was told about must send the worker back"
assert_contains "$out" 'needs-decision:' "the line must say what is missing"
assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "the send-back is one line"
assert_equals 'asks_question' "$(asked)" "the first mismatch wins"
pass "unreported question: sent back with one line"

reset
out=$(STUB_YES='partial_or_blocked' check "$HOME_ON" "$(stop_json 'I could not finish the migration.')")
assert_contains "$out" 'blocked:' "partial work with no state must name the blocked report"
pass "unreported partial work: sent back"

reset
out=$(STUB_YES='claims_finished' check "$HOME_ON" "$(stop_json 'Finished.')")
assert_equals '' "$out" "a finished claim with no changed file is not a mismatch"
assert_equals 'asks_question partial_or_blocked' "$(asked)" "claims_finished is not asked when nothing changed"
: > "$WT/dirty"
out=$(STUB_YES='claims_finished' check "$HOME_ON" "$(stop_json 'Finished.')")
assert_contains "$out" 'done:' "a finished claim over changed files with no state must be sent back"
pass "claims_finished needs the files-changed fact"

reset 'done: [2026-01-01T00:01:00Z] shipped'
out=$(STUB_YES='partial_or_blocked' check "$HOME_ON" "$(stop_json 'Done, though two tests are still skipped.')")
assert_contains "$out" 'you reported done:' "a done report over a partial message must be sent back"
reset 'done: [2026-01-01T00:01:00Z] shipped'
out=$(check "$HOME_ON" "$(stop_json 'Done.')")
assert_equals '' "$out" "a consistent done report ends the turn"
assert_equals 'partial_or_blocked' "$(asked)" "a done report asks only whether the message contradicts it"
pass "reported done: only a contradicting message sends back"

reset 'done: [2025-12-31T00:00:00Z] an earlier turn' stale
STUB_YES='asks_question' check "$HOME_ON" "$(stop_json 'Which one?')" >/dev/null
assert_equals 'asks_question' "$(asked)" "a status line from before this turn is not a report"
pass "a stale status line counts as unreported"

for line in 'needs-decision [key=a]: [2026-01-01T00:01:00Z] A or B' 'blocked: [2026-01-01T00:01:00Z] x' \
  'paused: [2026-01-01T00:01:00Z] ci' 'failed: [2026-01-01T00:01:00Z] x'; do
  reset "$line"
  out=$(STUB_YES='asks_question partial_or_blocked' check "$HOME_ON" "$(stop_json 'Which one?')")
  assert_equals "|" "$out|$(asked)" "a reported waiting state must ask nothing: $line"
done
pass "reported needs-decision, blocked, paused, failed: nothing asked"

reset
for extra in '{"stop_hook_active":true}' '{"background_tasks":[{"id":"b1"}]}' '{"last_assistant_message":""}'; do
  out=$(STUB_YES='asks_question' check "$HOME_ON" "$(stop_json 'Which one?' "$extra")")
  assert_equals "|" "$out|$(asked)" "must ask nothing: $extra"
done
pass "a stop after a send-back, running background tasks, or no message: nothing asked"

reset
"$ROOT/bin/fm-busy-event.sh" apply "$STATE" "$ID" idle --current-gen --source fm-recovery --event test >/dev/null
out=$(STUB_YES='asks_question' check "$HOME_ON" "$(stop_json 'Which one?')")
assert_equals "|" "$out|$(asked)" "a turn with no readable start must ask nothing"
"$ROOT/bin/fm-busy-event.sh" apply "$STATE" "$ID" busy --current-gen --source fm-recovery --event test >/dev/null
pass "no open turn in the busy record: nothing asked"

reset
out=$(STUB_MODE=error STUB_YES='asks_question' check "$HOME_ON" "$(stop_json 'Which one?')")
assert_equals "|asks_question" "$out|$(asked)" "a failed call must end the turn at once"
reset
out=$(STUB_CONF=0.5 STUB_YES='asks_question partial_or_blocked' check "$HOME_ON" "$(stop_json 'Which one?')")
assert_equals '' "$out" "a yes below the floor is not a mismatch"
pass "Jev down or unsure: the turn ends"

reset
long="$(printf 'Summary line of the work so far. %.0s' $(seq 200))
Which of the two options do you want?"
out=$(STUB_YES='asks_question' check "$HOME_ON" "$(stop_json "$long")")
sent=$(jq -rs '.[0].closing_message' "$SENT")
assert_contains "$sent" 'Which of the two options do you want?' "the end of a long closing message must be sent"
[ "${#sent}" -le 4000 ] || fail "the sent closing message must be 4000 characters or fewer, got ${#sent}"
assert_contains "$out" 'needs-decision:' "a question in the last line of a long message must send the worker back"
pass "long closing message: its end is what is sent"

transcript="$TMP_ROOT/transcript.jsonl"
write_transcript() {  # <command>...  (this turn's shell commands, in order)
  jq -cn '
    {type: "user", message: {content: "older"}},
    {type: "assistant", message: {content: [{type: "tool_use", name: "Bash", input: {command: "bin/fm-lint.sh"}}]}},
    {type: "user", message: {content: "commit it"}},
    ($ARGS.positional[] | {type: "assistant", message: {content: [{type: "tool_use", name: "Bash", input: {command: .}}]}}),
    {type: "user", message: {content: [{type: "tool_result", content: "ok"}]}}' --args "$@" > "$transcript"
}
reset 'done: [2026-01-01T00:01:00Z] shipped'
write_transcript 'git commit -m x'
out=$(STUB_YES='claims_checks_passed' check "$HOME_ON" "$(stop_json 'All tests pass.' "{\"transcript_path\":\"$transcript\"}")")
assert_contains "$out" 'no test or check command ran this turn' "a checks claim with no check command must be sent back"
assert_equals '["closing_message"]' "$(jq -cs 'map(keys[]) | unique' "$SENT")" \
  "only the closing message is sent, never a shell command"
reset 'done: [2026-01-01T00:01:00Z] shipped'
write_transcript 'bin/fm-lint.sh'
STUB_YES='claims_checks_passed' check "$HOME_ON" "$(stop_json 'All tests pass.' "{\"transcript_path\":\"$transcript\"}")" >/dev/null
assert_equals 'partial_or_blocked' "$(asked)" "a check command this turn withholds the checks question"
many=()
for _ in $(seq 60); do many+=('git status'); done
reset 'done: [2026-01-01T00:01:00Z] shipped'
write_transcript 'bin/fm-test-run.sh' "${many[@]}"
STUB_YES='claims_checks_passed' check "$HOME_ON" "$(stop_json 'All tests pass.' "{\"transcript_path\":\"$transcript\"}")" >/dev/null
assert_equals 'partial_or_blocked' "$(asked)" "a check command followed by many others still withholds the checks question"
reset 'done: [2026-01-01T00:01:00Z] shipped'
write_transcript "cd /srv/app && $(printf 'git status && %.0s' $(seq 40))npm test"
STUB_YES='claims_checks_passed' check "$HOME_ON" "$(stop_json 'All tests pass.' "{\"transcript_path\":\"$transcript\"}")" >/dev/null
assert_equals 'partial_or_blocked' "$(asked)" "a check late in a long command still withholds the checks question"
for cmd in 'cargo clippy' 'go vet ./...' 'mypy src' 'pyright' 'phpstan analyse' 'npx eslint .' 'ruff format --diff' \
  'npm run typecheck' 'dart analyze' 'npm audit' 'terraform validate'; do
  reset 'done: [2026-01-01T00:01:00Z] shipped'
  write_transcript "$cmd"
  STUB_YES='claims_checks_passed' check "$HOME_ON" "$(stop_json 'All checks are clean.' "{\"transcript_path\":\"$transcript\"}")" >/dev/null
  assert_equals 'partial_or_blocked' "$(asked)" "'$cmd' is a check command and withholds the checks question"
done
pass "claims_checks_passed needs the no-check-command fact"

# --- layer 2: the executable, real library, fake curl -------------------------

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  echo secret-present >> "$FAKE_CURL_LOG"
fi
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf 'argv:%s\n' "$1" >> "$FAKE_CURL_LOG"; shift ;;
  esac
done
key=$(jq -r '.questions | keys[0]')
jq -cn --arg k "$key" '{model: "jev-test", answers: {($k): {choice: "yes", confidence: 0.9, probabilities: {yes: 0.9, no: 0.1}}}}' > "$out"
printf 200
SH
chmod +x "$FAKEBIN/curl"

reset
out=$(PATH="$FAKEBIN:$PATH" FAKE_CURL_LOG="$TMP_ROOT/curl.log" "$CHECK" "$HOME_ON" "$STATE" "$ID" "$WT" \
  <<<"$(stop_json 'Should I use A or B?')")
expect_code 0 $? "the hook script always exits 0"
assert_equals block "$(jq -r .decision <<<"$out")" "the executable must print one Claude Stop decision"
assert_no_grep "$KEY" "$TMP_ROOT/curl.log" "the key must not reach curl's argv"
assert_no_grep secret-present "$TMP_ROOT/curl.log" "the key must not reach curl's environment"
out=$(PATH="$FAKEBIN:$PATH" FAKE_CURL_LOG="$TMP_ROOT/curl.log" "$CHECK" "$HOME_OFF" "$HOME_OFF/state" "$ID" "$WT" \
  <<<"$(stop_json 'Should I use A or B?')")
assert_equals '' "$out" "the executable prints nothing without a key"
pass "executable: block decision with a key, silent without, key never in a child"

echo "all fm-finished-check tests passed"
