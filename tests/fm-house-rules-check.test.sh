#!/usr/bin/env bash
# tests/fm-house-rules-check.test.sh - the advisory house-rules check
# (bin/fm-house-rules-check.sh, off unless the project is a line of
# config/jev-code-projects and TYPESAFE_API_KEY is present) and the
# definition-of-done step that asks a worker to run it (bin/fm-dod-lib.sh).
#
# Three layers, none of which touches the network, each pinned to a fixture
# home so no real key can load:
#   - the check's decisions over a fixture repository, with the script sourced
#     and fm_jev_choice stubbed at the library boundary, so what code decides
#     alone is asserted by whether the model was asked at all;
#   - the real executable with the real library and a fake curl, proving the
#     request shape and that the key reaches curl on a file descriptor and no
#     child environment, argv, or output;
#   - the generated brief, with and without the opt-in and the key.
# The library's own interface is tests/fm-jev-wake-triage.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-house-rules-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-house-rules-check)
KEY='test-key-9c2e-never-on-argv'
ON="$TMP_ROOT/home-on"
KEYONLY="$TMP_ROOT/home-key-only"
OPTED="$TMP_ROOT/home-opted-no-key"
PROJ=some-proj
REPO="$TMP_ROOT/repo"
CALLS="$TMP_ROOT/jev-calls"
STATES="$TMP_ROOT/jev-states"
ERR="$TMP_ROOT/stderr"
mkdir -p "$ON/config" "$KEYONLY" "$OPTED/config" "$REPO/src" "$REPO/docs" "$STATES"
printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$ON/.env"
printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$KEYONLY/.env"
opt_in() { rm -f "$1/config/house-rules.json"; printf '# opted in\n%s\n' "$PROJ" > "$1/config/jev-code-projects"; }
opt_in "$ON"
opt_in "$OPTED"
export -n FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE 2>/dev/null || true
unset FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE

# --- fixture repository ------------------------------------------------------

rgit() { git -C "$REPO" -c user.email=t@example.invalid -c user.name=t "$@"; }
rgit init -q -b main
printf 'root\n' > "$REPO/src/root.sh"
rgit add -A
rgit commit -qm root
rgit update-ref refs/remotes/origin/main HEAD
printf 'merged = 1\n' > "$REPO/src/merged.sh"
printf 'one\ntwo\nfour\n' > "$REPO/src/a.sh"
printf 'keep\ndrop\nkeep2\n' > "$REPO/src/trim.sh"
printf 'bye\n' > "$REPO/src/gone.sh"
printf '# doc\n' > "$REPO/docs/x.md"
printf '{}\n' > "$REPO/package-lock.json"
rgit add -A
rgit commit -qm base
rgit checkout -qb work
printf 'one\ntwo\nthree\nfour\n' > "$REPO/src/a.sh"
printf 'keep\nkeep2\n' > "$REPO/src/trim.sh"
rm "$REPO/src/gone.sh"
printf '# doc\nmore prose\n' > "$REPO/docs/x.md"
printf '{"a":1}\n' > "$REPO/package-lock.json"
printf 'TOKEN=abc\n' > "$REPO/.env.sample"
printf 'token: abc\n' > "$REPO/src/Secrets.yml"
printf 'quoted = 1\n' > "$REPO/src/q\"uote.sh"
i=0
while [ "$i" -lt 100 ]; do i=$((i + 1)); printf 'line_%s = %s\n' "$i" "$i"; done > "$REPO/src/big.py"
rgit add -A
rgit commit -qm work
NOBASE="$TMP_ROOT/nobase"
git init -q -b trunk "$NOBASE"

# --- layer 1: the check's decisions, Jev stubbed at the library boundary -----

# Runs house_rules_main in the fixture repository with fm_jev_choice replaced.
# STUB_YES lists the files answered `yes`, STUB_CONF is the confidence, and
# STUB_FAIL makes every call an error. Prints stdout; stderr lands in $ERR.
run_stubbed() {  # <home> [args...]
  local home=$1
  shift
  rm -rf "$CALLS" "$STATES"
  mkdir -p "$STATES"
  # shellcheck disable=SC2016 # The inner shell expands its own variables.
  ( cd "${RUN_IN:-$REPO}" && FM_HOME="$home" CALLS="$CALLS" STATES="$STATES" bash -c '
      # shellcheck source=/dev/null
      . "$1"
      shift
      fm_jev_choice() {
        local file choice=no conf=${STUB_CONF:-0.9} n
        file=$(jq -r .change.file "$3")
        printf "%s|%s\n" "$file" "$(jq -r .yes "$4")" >> "$CALLS"
        n=$(wc -l < "$CALLS" | tr -d " ")
        cp "$3" "$STATES/$n"
        FM_JEV_ERROR=""
        if [ -n "${STUB_FAIL:-}" ]; then
          FM_JEV_STATUS=error FM_JEV_ERROR="stub is down"
          return 1
        fi
        case " ${STUB_YES:-} " in *" $file "*) choice=yes ;; esac
        FM_JEV_STATUS=ok FM_JEV_CHOICE=$choice FM_JEV_CONFIDENCE=$conf
        FM_JEV_ANSWER=$(jq -cn --arg c "$choice" --argjson k "$conf" \
          "{choice: \$c, confidence: \$k, probabilities: {(\$c): \$k, (if \$c == \"yes\" then \"no\" else \"yes\" end): (1 - \$k)}}")
        return 0
      }
      house_rules_main "$@"
    ' _ "$TOOL" "$@" 2> "$ERR" )
}
calls() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }

out=$(run_stubbed "$OPTED" "$PROJ"); code=$?
expect_code 0 "$code" "no key exits 0"
assert_equals '' "$out" "no key prints no flag"
assert_equals 0 "$(calls)" "no key asks nothing"
assert_contains "$(cat "$ERR")" 'house-rules-check: off' "no key says off"
run_stubbed "$OPTED" --enabled "$PROJ"; code=$?
expect_code 1 "$code" "--enabled is false without a key"
run_stubbed "$ON" --enabled "$PROJ"; code=$?
expect_code 0 "$code" "--enabled is true with a key, an opted-in project, and the built-in rules"
pass "off without the key: no call, no flag, exit 0"

out=$(STUB_YES='src/a.sh' run_stubbed "$KEYONLY" "$PROJ"); code=$?
expect_code 0 "$code" "a key with no project list exits 0"
assert_equals '' "$out" "a key with no project list prints no flag"
assert_equals 0 "$(calls)" "the key alone asks nothing"
assert_contains "$(cat "$ERR")" "off (project \"$PROJ\" is not a line of" "the key alone says the project is not opted in"
run_stubbed "$KEYONLY" --enabled "$PROJ"; code=$?
expect_code 1 "$code" "--enabled is false with the key alone"
out=$(STUB_YES='src/a.sh' run_stubbed "$ON" other-proj)
assert_equals '' "$out" "a project outside the list prints no flag"
assert_equals 0 "$(calls)" "a project outside the list asks nothing"
run_stubbed "$ON" --enabled other-proj; code=$?
expect_code 1 "$code" "--enabled is false for a project outside the list"
printf '{"projects": ["%s"]}\n' "$PROJ" > "$ON/config/house-rules.json"
for unlisted in '' "# $PROJ" "owner/$PROJ" "$PROJ-two"; do
  printf '%s\n' "$unlisted" > "$ON/config/jev-code-projects"
  run_stubbed "$ON" "$PROJ" >/dev/null
  assert_equals 0 "$(calls)" "a project list holding only \"$unlisted\" opts the project out, whatever house-rules.json names"
  run_stubbed "$ON" --enabled "$PROJ"; code=$?
  expect_code 1 "$code" "--enabled is false for a project list holding only \"$unlisted\""
done
opt_in "$ON"
pass "the key alone sends nothing: only a project named in config/jev-code-projects is checked"

out=$(STUB_YES='src/a.sh' run_stubbed "$ON" "$PROJ"); code=$?
expect_code 0 "$code" "a flagged run still exits 0"
assert_equals 6 "$(calls)" "three eligible blocks are each asked both built-in rules"
assert_equals 'src/a.sh src/big.py' "$(cut -d'|' -f1 "$CALLS" | sort -u | tr '\n' ' ' | sed 's/ $//')" \
  "prose, a lockfile, secret-shaped files in either case, a deleted file, a removal-only hunk, a path git quotes, and work already on the default branch are never offered"
assert_equals 2 "$(printf '%s\n' "$out" | grep -c '^src/a\.sh:3: ')" "a yes at the floor flags the block's first added line once per rule"
assert_contains "$out" 'src/a.sh:3: hardcoded-choice (confidence 0.9): Do the added lines hard-code' "a flag names file, line, rule, and confidence"
assert_contains "$out" 'src/a.sh:3: own-compat-layer (confidence 0.9): ' "each rule is its own question"
assert_not_contains "$out" 'src/big.py' "a no is never a flag"
assert_contains "$(jq -r .change.block "$STATES/1")" '+three' "the block carries the added line"
assert_contains "$(cat "$ERR")" '2 advisory flag(s) from 6 question(s) over 3 changed block(s) and 2 rule(s) since main' \
  "the summary counts the run, against the default-branch copy closest to HEAD rather than a lagging origin"
pass "code picks the blocks; a confident yes becomes a file:line flag"

out=$(STUB_YES='src/big.py' run_stubbed "$ON" "$PROJ")
assert_equals 'src/big.py:1: src/big.py:81: ' "$(printf '%s\n' "$out" | cut -d' ' -f1 | sort -u -t: -k2,2n | tr '\n' ' ')" \
  "a long hunk is cut into blocks, each flagged at its own first added line"
assert_equals 80 "$(jq -r .change.block "$STATES/3" | grep -c '^+')" "a block holds at most the line bound"
out=$(STUB_YES='src/a.sh src/big.py' STUB_CONF=0.59 run_stubbed "$ON" "$PROJ")
assert_equals '' "$out" "a yes below the confidence floor is not a flag"
assert_equals 6 "$(calls)" "low confidence still asked every question"
pass "long hunks split into bounded blocks; low confidence means no flag"

out=$(STUB_FAIL=1 run_stubbed "$ON" "$PROJ"); code=$?
expect_code 0 "$code" "a failing model exits 0"
assert_equals '' "$out" "a failing model flags nothing"
assert_equals 3 "$(calls)" "asking stops after three failed calls"
assert_contains "$(cat "$ERR")" 'stopped because 3 calls failed, last: stub is down, 3 question(s) not asked' "the summary says what went unasked"
out=$(RUN_IN="$NOBASE" run_stubbed "$ON" "$PROJ"); code=$?
expect_code 0 "$code" "a repository with no default branch exits 0"
assert_equals 0 "$(calls)" "a repository with no default branch asks nothing"
assert_contains "$(cat "$ERR")" 'not run (no merge base with a default branch)' "a missing base says why nothing ran"
run_stubbed "$ON" --bogus "$PROJ"; code=$?
expect_code 2 "$code" "an unknown argument is a usage error"
run_stubbed "$ON"; code=$?
expect_code 2 "$code" "a missing project name is a usage error"
assert_equals 0 "$(calls)" "a missing project name asks nothing"
pass "errors, a missing base, and bad usage never flag and never fail the change"

printf '%s\n' '{"rules": [{"id": "only-rule", "question": "Is it \\d so?", "yes": "Y1", "no": "N1"}]}' \
  > "$ON/config/house-rules.json"
out=$(STUB_YES='src/a.sh' run_stubbed "$ON" "$PROJ")
assert_equals 3 "$(calls)" "configured rules replace the built-in rules"
assert_equals 'src/a.sh:3: only-rule (confidence 0.9): Is it \d so?' "$out" "a configured rule flags under its own id and question, backslash intact"
assert_equals 'Y1' "$(cut -d'|' -f2 "$CALLS" | sort -u)" "the rule's own criteria are what is asked"
printf '{"rules": []}\n' > "$ON/config/house-rules.json"
out=$(run_stubbed "$ON" "$PROJ")
assert_equals 6 "$(calls)" "an empty rules array means the two built-in rules"
printf '{"rules": [{"id": "Bad Id", "question": "q"}]}\n' > "$ON/config/house-rules.json"
out=$(run_stubbed "$ON" "$PROJ"); code=$?
expect_code 0 "$code" "malformed rules exit 0"
assert_equals 0 "$(calls)" "malformed rules ask nothing"
assert_contains "$(cat "$ERR")" 'has invalid rules' "malformed rules say so"
run_stubbed "$ON" --enabled "$PROJ"; code=$?
expect_code 1 "$code" "--enabled is false with malformed rules"
opt_in "$ON"
pass "config/house-rules.json rules replace the built-in ones; empty means built-in; malformed never runs"

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
printf '%s' '{"model":"jev-test","answers":{"house_rule":{"choice":"yes","confidence":0.8,"probabilities":{"yes":0.9,"no":0.1}}}}' \
  > "$TMP_ROOT/response.json"

out=$(cd "$REPO" && env PATH="$FAKEBIN:$PATH" FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$TMP_ROOT/response.json" \
  TYPESAFE_API_KEY="$KEY" FM_HOME="$OPTED" "$TOOL" "$PROJ" 2>&1); code=$?
expect_code 0 "$code" "the executable exits 0 on a flagged run"
assert_equals 6 "$(cat "$LOG/calls")" "the executable asks each block each rule through the library"
assert_equals 6 "$(printf '%s\n' "$out" | grep -c ' (confidence 0.8): ')" "every confident yes is printed"
assert_equals '["no","yes"]' "$(jq -c '.questions.house_rule.criteria | keys' "$LOG/body.1")" "each question offers exactly yes and no"
assert_equals 'src/a.sh' "$(jq -r '.state.change.file' "$LOG/body.1")" "the state names the changed file"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "the key reaches curl on the fd header"
assert_not_contains "$(cat "$LOG/argv")" "$KEY" "the key never appears on curl argv"
assert_equals 'clean' "$(sort -u "$LOG/child-env")" "the key is absent from every child environment"
assert_not_contains "$out" "$KEY" "the key never appears in the output"
pass "executable: fixed yes/no questions through the shared caller; key on the fd header only"

# --- layer 3: the definition-of-done step ------------------------------------

# shellcheck source=bin/fm-dod-lib.sh
dod() { ( . "$ROOT/bin/fm-dod-lib.sh"; fm_dod_block "$@" ); }
for mode in no-mistakes direct-PR local-only; do
  FM_HOME="$ON" "$ROOT/bin/fm-brief.sh" "hr-$mode" "$PROJ" --mode "$mode" >/dev/null 2>&1 \
    || fail "fm-brief.sh failed for $mode with the project opted in"
  FM_HOME="$ON" "$ROOT/bin/fm-brief.sh" "hr-other-$mode" other-proj --mode "$mode" >/dev/null 2>&1 \
    || fail "fm-brief.sh failed for $mode with another project"
  FM_HOME="$KEYONLY" "$ROOT/bin/fm-brief.sh" "hr-$mode" "$PROJ" --mode "$mode" >/dev/null 2>&1 \
    || fail "fm-brief.sh failed for $mode with the key alone"
  assert_grep "run \`FM_HOME=$ON $TOOL $PROJ\` in the worktree" "$ON/data/hr-$mode/brief.md" \
    "$mode: an opted-in project's brief asks the worker to run the check for that home and project"
  assert_no_grep 'advisory house-rule flags' "$ON/data/hr-other-$mode/brief.md" "$mode: a project outside the list gets no step"
  assert_no_grep 'advisory house-rule flags' "$KEYONLY/data/hr-$mode/brief.md" "$mode: the key alone adds no step"
  plain=$(dod "$mode" "hr-$mode")
  assert_equals "$plain" "$(dod "$mode" "hr-$mode" "$KEYONLY" "$PROJ")" \
    "$mode: with the key alone the definition of done is unchanged"
  assert_equals "$plain" "$(dod "$mode" "hr-$mode" "$ON" other-proj)" \
    "$mode: for a project outside the list the definition of done is unchanged"
  assert_contains "$(dod "$mode" "hr-$mode" "$ON" "/somewhere/projects/$PROJ")" \
    "$TOOL $PROJ\` in the worktree" "$mode: a recorded project path is matched by its name"
done
FM_HOME="$ON" "$ROOT/bin/fm-brief.sh" hr-scout "$PROJ" --scout >/dev/null 2>&1 || fail "fm-brief.sh failed for a scout"
assert_no_grep 'advisory house-rule flags' "$ON/data/hr-scout/brief.md" "a scout brief carries no check"
pass "brief: every ship mode gains the advisory step only for an opted-in project in a home with the key"

# --- credential lines never leave -------------------------------------------

PLANTED="ghp_$(printf 'a%.0s' $(seq 1 36))"
printf 'retries = 3\nGH_TOKEN=%s\n' "$PLANTED" > "$REPO/src/client.sh"
rgit add -A
rgit commit -qm client
rm -rf "$LOG"; mkdir -p "$LOG"
(cd "$REPO" && env PATH="$FAKEBIN:$PATH" FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$TMP_ROOT/response.json" \
  TYPESAFE_API_KEY="$KEY" FM_HOME="$OPTED" "$TOOL" "$PROJ" >/dev/null 2>&1)
sent=$(cat "$LOG"/body.*)
assert_contains "$sent" 'retries = 3' "the block holding the credential line is still asked about"
assert_not_contains "$sent" "$PLANTED" "a changed line holding a credential is in no request"
assert_contains "$sent" 'line withheld: looks like a credential' "the credential line is replaced by the placeholder"
pass "executable: a changed line that looks like a credential is withheld from every request"

# --- the gate and the rules read one config directory -------------------------

ALT="$TMP_ROOT/alt-config"
mkdir -p "$ALT"
printf '%s\n' "$PROJ" > "$ALT/jev-code-projects"
printf '{"rules":[{"id":"alt-rule","question":"Alt?","yes":"Alt yes.","no":"Alt no."}]}\n' > "$ALT/house-rules.json"
FM_CONFIG_OVERRIDE="$ALT" run_stubbed "$KEYONLY" --enabled "$PROJ"; code=$?
expect_code 0 "$code" "FM_CONFIG_OVERRIDE's project list opts the project in for a home that lists none"
out=$(FM_CONFIG_OVERRIDE="$ALT" STUB_YES='src/a.sh' run_stubbed "$KEYONLY" "$PROJ")
assert_contains "$out" 'src/a.sh:3: alt-rule ' "the rules come from the same directory as the project list"
: > "$ALT/jev-code-projects"
FM_CONFIG_OVERRIDE="$ALT" run_stubbed "$ON" --enabled "$PROJ"; code=$?
expect_code 1 "$code" "the home's own project list is not read when FM_CONFIG_OVERRIDE names another directory"
pass "FM_CONFIG_OVERRIDE selects one directory for both the project list and the rules"

printf '# all fm-house-rules-check tests passed\n'
