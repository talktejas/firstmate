#!/usr/bin/env bash
# tests/fm-escalation-screen.test.sh - the advisory escalation screen
# (bin/fm-escalation-screen.sh, off unless TYPESAFE_API_KEY is present).
#
# Two layers, neither of which touches the network, each pinned to a fixture
# home so no real key can load:
#   - the screen's decisions, with the script sourced and fm_jev_choice stubbed
#     at the library boundary, so what code decides alone is asserted by
#     whether the model was asked at all;
#   - the real executable with the real library and a fake curl, proving the
#     request shape and that the key reaches curl on a file descriptor and no
#     child environment, argv, or output.
# The library's own interface is tests/fm-jev-wake-triage.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-escalation-screen.sh"
TMP_ROOT=$(fm_test_tmproot fm-escalation-screen)
KEY='test-key-7c2e-never-on-argv'
ON="$TMP_ROOT/home-on"
OFF="$TMP_ROOT/home-off"
CALLS="$TMP_ROOT/jev-calls"
mkdir -p "$ON" "$OFF"
printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$ON/.env"

# --- layer 1: the screen's decisions, Jev stubbed at the library boundary ----

# Runs escalation_screen_main with fm_jev_choice replaced by a stub answering
# STUB_CHOICE at STUB_CONFIDENCE and recording each call. STUB_FAIL makes the
# call an error.
run_stubbed() {  # <home> [args...]
  local home=$1
  shift
  rm -f "$CALLS" "$TMP_ROOT/state.json" "$TMP_ROOT/criteria.json"
  # shellcheck disable=SC2016 # The inner shell expands its own variables.
  FM_HOME="$home" CALLS="$CALLS" OUT="$TMP_ROOT" bash -c '
      # shellcheck source=/dev/null
      . "$1"
      shift
      fm_jev_choice() {
        printf "%s\n" "$1" >> "$CALLS"
        cp "$3" "$OUT/state.json"
        cp "$4" "$OUT/criteria.json"
        FM_JEV_ERROR=""
        if [ -n "${STUB_FAIL:-}" ]; then
          FM_JEV_STATUS=error FM_JEV_ERROR="stub is down"
          return 1
        fi
        FM_JEV_STATUS=ok FM_JEV_CHOICE=$STUB_CHOICE FM_JEV_CONFIDENCE=$STUB_CONFIDENCE
        return 0
      }
      escalation_screen_main "$@"
    ' _ "$TOOL" "$@" 2>/dev/null
}
calls() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }
Q='Should the invoice number restart each financial year or run on forever?'

out=$(STUB_CHOICE=cheap-to-reverse STUB_CONFIDENCE=0.9 run_stubbed "$OFF" "$Q"); code=$?
expect_code 0 "$code" "no key exits 0"
assert_contains "$out" 'screen: by hand (off, TYPESAFE_API_KEY absent' "no key is by hand and says off"
assert_equals 0 "$(calls)" "no key: the model is not asked"
pass "off without the key: no call, by hand"

out=$(STUB_CHOICE=setting-with-default STUB_CONFIDENCE=0.6 run_stubbed "$ON" "$Q"); code=$?
expect_code 0 "$code" "a screened question exits 0"
assert_equals 'screen: yours (setting-with-default, confidence 0.6)' "$out" "a setting exactly at the floor is yours"
assert_equals 1 "$(calls)" "one question is one request"
assert_equals "{\"question\":\"$Q\"}" "$(jq -c . "$TMP_ROOT/state.json")" "the state is the question's words only"
assert_equals '["cheap-to-reverse","costly-to-undo","setting-with-default","trade","unclear"]' "$(jq -c 'keys' "$TMP_ROOT/criteria.json")" \
  "the question offers exactly the five fixed kinds"
out=$(STUB_CHOICE=cheap-to-reverse STUB_CONFIDENCE=0.95 run_stubbed "$ON" "$Q")
assert_equals 'screen: yours (cheap-to-reverse, confidence 0.95)' "$out" "a confident cheap-to-reverse is yours"
out=$(STUB_CHOICE=setting-with-default STUB_CONFIDENCE=0.59 run_stubbed "$ON" "$Q")
assert_equals 'screen: by hand (setting-with-default below the confidence floor, 0.59)' "$out" "below the floor is by hand"
out=$(STUB_CHOICE=trade STUB_CONFIDENCE=0.3 run_stubbed "$ON" "$Q")
assert_equals "screen: captain's (trade, confidence 0.3)" "$out" "a trade answer is the captain's at any confidence"
out=$(STUB_CHOICE=costly-to-undo STUB_CONFIDENCE=0.9 run_stubbed "$ON" "$Q")
assert_equals "screen: captain's (costly-to-undo, confidence 0.9)" "$out" "a costly-to-undo answer is the captain's"
out=$(STUB_CHOICE=unclear STUB_CONFIDENCE=0.99 run_stubbed "$ON" "$Q")
assert_equals 'screen: by hand (unclear, confidence 0.99)' "$out" "unclear is by hand however confident"
out=$(STUB_FAIL=1 run_stubbed "$ON" "$Q"); code=$?
expect_code 0 "$code" "a failing model exits 0"
assert_equals 'screen: by hand (no answer: stub is down)' "$out" "a failing model is by hand"
out=$(printf '%s\n' "$Q" | STUB_CHOICE=cheap-to-reverse STUB_CONFIDENCE=0.9 run_stubbed "$ON" -)
assert_equals 'screen: yours (cheap-to-reverse, confidence 0.9)' "$out" "the question is read from stdin"
pass "only a confident setting or cheap-to-reverse is yours; trade and costly-to-undo are the captain's"

for q in 'Shall I merge the export branch now?' 'OK to DELETE the old members table?' \
  'Do you approve the release?' 'Which password policy should the portal use?' 'Should I force-push the rebased branch?' \
  'Has the captain approved shipping this?' 'Should the old rows be deleted?' 'Should the stale branch be dropped?' \
  'Should I remove the legacy table?' 'Rotate the API token now?' 'Was the cache wiped or overwritten?' \
  'Should I revert the rename?' 'Is a reset of the counter wanted?' 'Which signing key should the build use?'; do
  out=$(STUB_CHOICE=cheap-to-reverse STUB_CONFIDENCE=1 run_stubbed "$ON" "$q")
  assert_contains "$out" "screen: captain's (names a merge" "\"$q\" is the captain's by code"
  assert_equals 0 "$(calls)" "\"$q\": the model is not asked"
done
out=$(STUB_CHOICE=cheap-to-reverse STUB_CONFIDENCE=1 run_stubbed "$ON" 'Which dropdown order suits the emergency contact form?')
assert_equals 1 "$(calls)" "a word that only contains a listed word is still asked about"
out=$(STUB_CHOICE=cheap-to-reverse STUB_CONFIDENCE=1 run_stubbed "$ON" 'ask-user findings=a-bug file=/x/nm-r1-findings.txt')
assert_contains "$out" 'screen: by hand (a review gate' "a review gate line is left to its own owner"
assert_equals 0 "$(calls)" "a review gate: the model is not asked"
out=$(STUB_CHOICE=cheap-to-reverse STUB_CONFIDENCE=1 run_stubbed "$ON" "$(head -c 4001 /dev/zero | tr '\0' x)")
assert_equals 'screen: by hand (the question is over 4000 characters)' "$out" "an over-long question is by hand, uncut"
assert_equals 0 "$(calls)" "an over-long question: the model is not asked"
run_stubbed "$ON" >/dev/null; expect_code 2 $? "no question is a usage error"
run_stubbed "$ON" '   ' >/dev/null; expect_code 2 $? "a blank question is a usage error"
pass "code decides a merge, approval, destructive or security question, a review gate, and an over-long question without asking"

# --- layer 2: the real executable, the real library, a fake curl -------------

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
printf '%s' '{"model":"jev-test","answers":{"kind":{"choice":"setting-with-default","confidence":0.8,"probabilities":{"trade":0.05,"costly-to-undo":0.05,"setting-with-default":0.8,"cheap-to-reverse":0.05,"unclear":0.05}}}}' \
  > "$TMP_ROOT/response.json"
real() {  # <response-file> <question>
  env PATH="$FAKEBIN:$PATH" FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$1" \
    TYPESAFE_API_KEY="$KEY" FM_HOME="$OFF" "$TOOL" "$2" 2>&1
}

out=$(real "$TMP_ROOT/response.json" "$Q"); code=$?
expect_code 0 "$code" "the executable exits 0"
assert_equals 'screen: yours (setting-with-default, confidence 0.8)' "$out" "a well-formed confident answer prints the one line"
assert_equals 1 "$(cat "$LOG/calls")" "the executable makes one request through the library"
assert_equals '["kind"]' "$(jq -c '.questions | keys' "$LOG/body.1")" "one question"
assert_equals 'choice' "$(jq -r '.questions.kind.type' "$LOG/body.1")" "the question is a fixed Choice"
assert_equals "$Q" "$(jq -r '.state.question' "$LOG/body.1")" "the question's words are the state"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "the key reaches curl on the fd header"
assert_not_contains "$(cat "$LOG/argv")" "$KEY" "the key never appears on curl argv"
assert_equals 'clean' "$(sort -u "$LOG/child-env")" "the key is absent from every child environment"
assert_not_contains "$out" "$KEY" "the key never appears in the output"
assert_equals '.env' "$(ls -A "$ON")" "the screen writes nothing into a home"
pass "executable: one fixed five-way question through the shared caller; key on the fd header only"

printf '%s' '{"model":"jev-test","answers":{"kind":{"choice":"cheap-to-reverse","confidence":0.9,"probabilities":{"cheap-to-reverse":2}}}}' > "$TMP_ROOT/bad.json"
out=$(real "$TMP_ROOT/bad.json" "$Q"); code=$?
expect_code 0 "$code" "a malformed answer exits 0"
assert_contains "$out" 'screen: by hand (no answer:' "a malformed answer is by hand"

PLANTED="ghp_$(printf 'a%.0s' $(seq 1 36))"
rm -rf "$LOG"; mkdir -p "$LOG"
real "$TMP_ROOT/response.json" "Which label suits the export button?
GH_TOKEN=$PLANTED" >/dev/null
assert_contains "$(jq -r .state.question "$LOG/body.1")" 'Which label suits the export button?' "the rest of the question is still sent"
assert_no_grep "$PLANTED" "$LOG/body.1" "a question line holding a credential is not in the request"
pass "executable: a malformed answer is by hand, and a credential line is withheld from the request"

printf '# all fm-escalation-screen tests passed\n'
