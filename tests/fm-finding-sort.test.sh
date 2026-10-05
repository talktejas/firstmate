#!/usr/bin/env bash
# tests/fm-finding-sort.test.sh - the advisory review-finding sort
# (bin/fm-finding-sort.sh, off unless TYPESAFE_API_KEY is present and the
# task's project is a line of config/jev-code-projects).
#
# Two layers, neither of which touches the network, each pinned to a fixture
# home so no real key can load:
#   - the sort's decisions, with the script sourced and fm_jev_choices stubbed
#     at the library boundary, so what code decides alone is asserted by
#     whether the model was asked at all;
#   - the real executable with the real library and a fake curl, proving the
#     request shape and that the key reaches curl on a file descriptor and no
#     child environment, argv, or output.
# The library's own interface is tests/fm-jev-wake-triage.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-finding-sort.sh"
TMP_ROOT=$(fm_test_tmproot fm-finding-sort)
KEY='test-key-4d1a-never-on-argv'
ON="$TMP_ROOT/home-on"
KEYONLY="$TMP_ROOT/home-key-only"
OPTED="$TMP_ROOT/home-opted-no-key"
T=task-1
CALLS="$TMP_ROOT/jev-calls"
ERR="$TMP_ROOT/stderr"

mkhome() {  # <home> <key:1|0> <opted:1|0>
  mkdir -p "$1/state" "$1/config" "$1/data/$T"
  [ "$2" -eq 0 ] || printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$1/.env"
  [ "$3" -eq 0 ] || printf '# opted in\nsome-proj\n' > "$1/config/jev-code-projects"
  printf 'project=/somewhere/projects/some-proj\n' > "$1/state/$T.meta"
  printf '# Task\n## Captain'"'"'s intent\nAdd a CSV export of members.\n## Firstmate spec\nSECRET-SPEC-TEXT\n' > "$1/data/$T/brief.md"
  printf 'id: a-bug\nseverity: high\nfile: src/export.py\nline: 4\ndescription: header row is missing\nauthority: ask-user\n\nid: b-style\ndescription: rename tmp to rows\n\nid: c-grow\ndescription: add an audit log\n\nid: d-low\ndescription: comment typo\n\nid: e-null\ndescription: unclear\n' \
    > "$1/data/$T/nm-r1-findings.txt"
  gate "$1" 'a-bug,b-style,c-grow,d-low,e-null,f-absent' "$1/data/$T/nm-r1-findings.txt"
}
gate() {  # <home> <ids> <file>
  printf 'working: [2026-10-06T00:00:00Z] setup done\nneeds-decision [key=nm-r0-review]: [2026-10-06T00:00:01Z] ask-user findings=old file=%s/data/%s/nm-r0-findings.txt\nneeds-decision [key=nm-r1-review]: [2026-10-06T00:00:02Z] ask-user findings=%s file=%s\n' \
    "$1" "$T" "$2" "$3" > "$1/state/$T.status"
}
mkhome "$ON" 1 1
mkhome "$KEYONLY" 1 0
mkhome "$OPTED" 0 1

# --- layer 1: the sort's decisions, Jev stubbed at the library boundary ------

# Runs finding_sort_main with fm_jev_choices replaced by a stub that answers by
# finding id and records each call. STUB_FAIL makes the call an error.
run_stubbed() {  # <home> [args...]
  local home=$1
  shift
  rm -f "$CALLS" "$TMP_ROOT/state.json" "$TMP_ROOT/questions.json"
  # shellcheck disable=SC2016 # The inner shell expands its own variables.
  FM_HOME="$home" CALLS="$CALLS" OUT="$TMP_ROOT" bash -c '
      # shellcheck source=/dev/null
      . "$1"
      shift
      fm_jev_choices() {
        printf "%s\n" "$3" >> "$CALLS"
        cp "$1" "$OUT/questions.json"
        cp "$2" "$OUT/state.json"
        FM_JEV_ERROR=""
        if [ -n "${STUB_FAIL:-}" ]; then
          FM_JEV_STATUS=error FM_JEV_ERROR="stub is down"
          return 1
        fi
        FM_JEV_STATUS=ok
        FM_JEV_ANSWERS=$(jq -c "
          def ans(\$c; \$k): {choice: \$c, confidence: \$k, probabilities: {(\$c): 0.5}};
          {answers: with_entries(.value = (
            if (.value.instructions | contains(\"a-bug\")) then ans(\"inside-task\"; 0.9)
            elif (.value.instructions | contains(\"b-style\")) then ans(\"style-only\"; 0.6)
            elif (.value.instructions | contains(\"c-grow\")) then ans(\"grows-task\"; 0.95)
            elif (.value.instructions | contains(\"d-low\")) then ans(\"style-only\"; 0.59)
            elif (.value.instructions | contains(\"x-destroy\")) then ans(\"destructive\"; 0.99)
            else null end))}" "$1")
        return 0
      }
      finding_sort_main "$@"
    ' _ "$TOOL" "$@" 2> "$ERR"
}
calls() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }
all_by_hand() {  # <output> <count> <label>
  assert_equals "$2" "$(printf '%s\n' "$1" | grep -c ': by hand (')" "$3: every finding is by hand"
  assert_not_contains "$1" 'settle' "$3: nothing is settled"
  assert_equals 0 "$(calls)" "$3: the model is not asked"
}

out=$(run_stubbed "$OPTED" "$T"); code=$?
expect_code 0 "$code" "no key exits 0"
all_by_hand "$out" 6 "no key"
assert_contains "$(cat "$ERR")" 'off, TYPESAFE_API_KEY absent' "no key says off"
out=$(run_stubbed "$KEYONLY" "$T"); code=$?
expect_code 0 "$code" "the key alone exits 0"
all_by_hand "$out" 6 "the key alone"
assert_contains "$(cat "$ERR")" 'project "some-proj" is not a line of' "the key alone names the missing opt-in"
pass "off without the key or without the project opt-in: no call, every finding by hand"

out=$(run_stubbed "$ON" "$T"); code=$?
expect_code 0 "$code" "a sorted gate exits 0"
assert_equals 1 "$(calls)" "the whole gate is one request"
assert_contains "$out" 'a-bug: settle (inside-task, confidence 0.9)' "a confident inside-task is settle"
assert_contains "$out" 'b-style: settle (style-only, confidence 0.6)' "a style-only exactly at the floor is settle"
assert_contains "$out" 'c-grow: by hand (grows-task, confidence 0.95)' "a confident grows-task is by hand"
assert_contains "$out" 'd-low: by hand (style-only below the confidence floor, 0.59)' "below the floor is by hand"
assert_contains "$out" 'e-null: by hand (no usable answer)' "a finding with no usable answer is by hand"
assert_contains "$out" 'f-absent: by hand (no usable answer)' "an id the file never mentions is asked about and left by hand"
assert_equals 6 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "one line per named finding, the newest gate only"
assert_equals 6 "$(jq 'length' "$TMP_ROOT/questions.json")" "one question per named id"
assert_equals '["destructive","grows-task","inside-task","style-only"]' "$(jq -c '[.[].criteria | keys] | unique | .[0]' "$TMP_ROOT/questions.json")" \
  "every question offers exactly the four fixed sorts"
assert_equals '["findings","intent"]' "$(jq -c 'keys' "$TMP_ROOT/state.json")" "the state is the intent and the findings file only"
assert_contains "$(jq -r .intent "$TMP_ROOT/state.json")" 'Add a CSV export of members.' "the intent is the brief's Captain's intent"
assert_not_contains "$(cat "$TMP_ROOT/state.json")" 'SECRET-SPEC-TEXT' "the rest of the brief is not sent"
assert_equals "$(cat "$ON/data/$T/nm-r1-findings.txt")" "$(jq -r .findings "$TMP_ROOT/state.json")" "the findings file is sent whole, uncut"
assert_contains "$(cat "$ERR")" '2 of 6 finding(s) sorted as settle from 6 question(s) in one request' "the summary counts the run"
pass "every named id is asked; only a confident inside-task or style-only is settle"

printf 'id: x-destroy\ndescription: drop the members table\n' > "$ON/data/$T/nm-r2-findings.txt"
gate "$ON" 'x-destroy' "$ON/data/$T/nm-r2-findings.txt"
out=$(run_stubbed "$ON" "$T")
assert_equals 'x-destroy: by hand (destructive, confidence 0.99)' "$out" "a destructive sort is never settle"
gate "$ON" 'a-bug' "$ON/data/$T/nm-r1-findings.txt"
out=$(STUB_FAIL=1 run_stubbed "$ON" "$T"); code=$?
expect_code 0 "$code" "a failing model exits 0"
assert_equals 'a-bug: by hand (no answer: stub is down)' "$out" "a failing model leaves the finding by hand"
pass "destructive and a failed call are by hand"

refused() {  # <label> <expected stderr>
  local out
  out=$(run_stubbed "$ON" "$T"); expect_code 0 $? "$1 exits 0"
  all_by_hand "$out" 1 "$1"
  assert_contains "$(cat "$ERR")" "$2" "$1 says why"
}
printf 'id: a-bug\n' > "$TMP_ROOT/nm-out-findings.txt"
gate "$ON" 'a-bug' "$TMP_ROOT/nm-out-findings.txt"
refused "a file outside the task's data directory" 'is not an nm-*-findings.txt in'
mkdir -p "$ON/data/$T/nm-sub"
cp "$TMP_ROOT/nm-out-findings.txt" "$ON/data/$T/nm-sub/nm-s-findings.txt"
gate "$ON" 'a-bug' "$ON/data/$T/nm-sub/nm-s-findings.txt"
refused "a file in a subdirectory" 'is not directly inside'
ln -s "$TMP_ROOT/nm-out-findings.txt" "$ON/data/$T/nm-link-findings.txt"
gate "$ON" 'a-bug' "$ON/data/$T/nm-link-findings.txt"
refused "a symlinked file" 'not a regular file'
gate "$ON" 'a-bug' "$ON/data/$T/nm-gone-findings.txt"
refused "a missing file" 'missing, empty, or not a regular file'
{ printf 'id: a-bug\n'; head -c 20001 /dev/zero | tr '\0' x; } > "$ON/data/$T/nm-big-findings.txt"
gate "$ON" 'a-bug' "$ON/data/$T/nm-big-findings.txt"
refused "an over-long file" 'is over 20000 bytes'
gate "$ON" 'a-bug' "$ON/data/$T/nm-r1-findings.txt"
printf '# Task\nno split\n' > "$ON/data/$T/brief.md"
refused "a brief with no Captain's intent" "no Captain's intent"
: > "$ON/state/$T.status"
out=$(run_stubbed "$ON" "$T"); code=$?
expect_code 0 "$code" "a task with no gate line exits 0"
assert_equals '' "$out" "a task with no gate line prints nothing"
assert_contains "$(cat "$ERR")" 'nothing to sort' "a task with no gate line says so"
run_stubbed "$ON" >/dev/null; expect_code 2 $? "no task id is a usage error"
run_stubbed "$ON" ../x >/dev/null; expect_code 2 $? "a path-shaped task id is a usage error"
pass "an unusable gate, file, or brief is by hand without asking"

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
printf '%s' '{"model":"jev-test","answers":{"f0":{"choice":"inside-task","confidence":0.8,"probabilities":{"inside-task":0.85,"grows-task":0.05,"style-only":0.05,"destructive":0.05}},"f1":{"choice":"style-only","confidence":0.9,"probabilities":{"style-only":2}}}}' \
  > "$TMP_ROOT/response.json"
gate "$OPTED" 'a-bug,b-style' "$OPTED/data/$T/nm-r1-findings.txt"
cp "$OPTED/state/$T.status" "$TMP_ROOT/status.before"

out=$(env PATH="$FAKEBIN:$PATH" FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$TMP_ROOT/response.json" \
  TYPESAFE_API_KEY="$KEY" FM_HOME="$OPTED" "$TOOL" "$T" 2>&1); code=$?
expect_code 0 "$code" "the executable exits 0"
assert_equals 1 "$(cat "$LOG/calls")" "the executable makes one request through the library"
assert_contains "$out" 'a-bug: settle (inside-task, confidence 0.8)' "a well-formed confident answer is settle"
assert_contains "$out" 'b-style: by hand (no usable answer)' "a malformed answer to one finding leaves that finding by hand"
assert_equals '["f0","f1"]' "$(jq -c '.questions | keys' "$LOG/body.1")" "one question per finding"
assert_equals 'choice' "$(jq -r '.questions.f0.type' "$LOG/body.1")" "each question is a fixed Choice"
assert_contains "$(jq -r '.questions.f1.instructions' "$LOG/body.1")" 'b-style' "each question names its own finding id"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "the key reaches curl on the fd header"
assert_not_contains "$(cat "$LOG/argv")" "$KEY" "the key never appears on curl argv"
assert_equals 'clean' "$(sort -u "$LOG/child-env")" "the key is absent from every child environment"
assert_not_contains "$out" "$KEY" "the key never appears in the output"
assert_equals "$(cat "$TMP_ROOT/status.before")" "$(cat "$OPTED/state/$T.status")" "the sort writes nothing to the task's status record"
pass "executable: one request of fixed four-way questions through the shared caller; key on the fd header only"

printf '# all fm-finding-sort tests passed\n'
