#!/usr/bin/env bash
# tests/fm-exists-search.test.sh - the advisory "does this already exist?"
# search (bin/fm-exists-search.sh, off unless the project is a line of
# config/jev-code-projects and TYPESAFE_API_KEY is present) and the brief lines
# that offer it to a worker (bin/fm-dod-lib.sh, bin/fm-brief.sh).
#
# Three layers, none of which touches the network, each pinned to a fixture
# home so no real key can load:
#   - the search's decisions over a fixture repository, with the script sourced
#     and fm_jev_choices stubbed at the library boundary, so what code decides
#     alone is asserted by which functions the model was asked about;
#   - the real executable with the real library and a fake curl, proving the
#     request shape, the withheld credential line, and that the key reaches
#     curl on a file descriptor and no child environment, argv, or output;
#   - the generated brief, with and without the opt-in and the key.
# The library's own interface is tests/fm-jev-wake-triage.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-exists-search.sh"
TMP_ROOT=$(fm_test_tmproot fm-exists-search)
KEY='test-key-4f1b-never-on-argv'
ON="$TMP_ROOT/home-on"
KEYONLY="$TMP_ROOT/home-key-only"
OPTED="$TMP_ROOT/home-opted-no-key"
PROJ=some-proj
REPO="$TMP_ROOT/repo"
CALLS="$TMP_ROOT/jev-calls"
STATES="$TMP_ROOT/jev-states"
ERR="$TMP_ROOT/stderr"
Q='Does this work out commission per item?'
mkdir -p "$ON/config" "$KEYONLY" "$OPTED/config" "$REPO/src" "$REPO/docs" "$REPO/vendor" "$REPO/gen" "$STATES"
printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$ON/.env"
printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$KEYONLY/.env"
printf '# opted in\n%s\n' "$PROJ" > "$ON/config/jev-code-projects"
printf '%s\n' "$PROJ" > "$OPTED/config/jev-code-projects"
export -n FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE 2>/dev/null || true
unset FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE

# --- fixture repository ------------------------------------------------------

rgit() { git -C "$REPO" -c user.email=t@example.invalid -c user.name=t "$@"; }
rgit init -q -b main
cat > "$REPO/src/pay.sh" <<'EOF'
# pay helpers
commission_per_item() {
  echo $(( $1 * $2 / 100 ))
}

order_total() {
  echo $(( $1 + $2 ))
}
EOF
{
  printf 'def slugify(text):\n    return text.lower()\n\n'
  printf 'def long_report(rows):\n'
  i=0
  while [ "$i" -lt 100 ]; do i=$((i + 1)); printf '    line_%s = %s\n' "$i" "$i"; done
} > "$REPO/src/util.py"
printf 'function proseOnly() {\n}\n' > "$REPO/docs/x.md"
printf 'function vendored() {\n}\n' > "$REPO/vendor/lib.js"
printf 'load_token() {\n  echo hidden\n}\n' > "$REPO/src/Secrets.sh"
i=0
while [ "$i" -lt 210 ]; do i=$((i + 1)); printf 'gen_%s() {\n  true\n}\n' "$i"; done > "$REPO/gen/many.sh"
rgit add -A
rgit commit -qm base
rgit update-ref refs/remotes/origin/main HEAD
rgit checkout -qb work
# shellcheck disable=SC2016 # Fixture source text.
printf 'item_commission() {\n  echo $(( $1 * $2 / 100 ))\n}\n' > "$REPO/src/new.sh"
printf '\nshipping_fee() {\n  echo 5\n}\n' >> "$REPO/src/pay.sh"
rgit add -A
rgit commit -qm work
NOBASE="$TMP_ROOT/nobase"
git init -q -b trunk "$NOBASE"

# --- layer 1: the search's decisions, Jev stubbed at the library boundary ----

# Runs exists_main in the fixture repository with fm_jev_choices replaced. A
# function whose code matches STUB_YES is answered `yes` at STUB_CONF, one that
# matches STUB_HIGH at 0.99, and STUB_FAIL makes every request an error.
# Prints stdout; stderr lands in $ERR. Each request appends the opening line of
# every function it asked about to $CALLS and copies its state to $STATES/<n>.
run_stubbed() {  # <home> [args...]
  local home=$1
  shift
  rm -f "$CALLS" "$STATES"/*
  # shellcheck disable=SC2016 # The inner shell expands its own variables.
  ( cd "${RUN_IN:-$REPO}" && FM_HOME="$home" CALLS="$CALLS" STATES="$STATES" bash -c '
      # shellcheck source=/dev/null
      . "$1"
      shift
      fm_jev_choices() {
        local n
        n=$(( $(ls "$STATES" | wc -l) + 1 ))
        cp "$2" "$STATES/$n"
        jq -r --slurpfile q "$1" ".functions | to_entries[] | select(\$q[0][.key]) | .value.code | split(\"\n\")[0]" "$2" >> "$CALLS"
        FM_JEV_ERROR=""
        if [ -n "${STUB_FAIL:-}" ]; then
          FM_JEV_STATUS=error FM_JEV_ERROR="stub is down"
          return 1
        fi
        FM_JEV_STATUS=ok
        FM_JEV_ANSWERS=$(jq -c --arg yes "${STUB_YES:-^$}" --arg high "${STUB_HIGH:-^$}" --argjson k "${STUB_CONF:-0.9}" \
          "{answers: (.functions | map_values(
              if (.code | test(\$high)) then {choice: \"yes\", confidence: 0.99, probabilities: {yes: 0.99, no: 0.01}}
              elif (.code | test(\$yes)) then {choice: \"yes\", confidence: \$k, probabilities: {yes: \$k, no: (1 - \$k)}}
              else {choice: \"no\", confidence: 0.9, probabilities: {yes: 0.1, no: 0.9}} end))}" "$2")
        return 0
      }
      exists_main "$@"
    ' _ "$TOOL" "$@" 2> "$ERR" )
}
asked() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }
requests() { find "$STATES" -type f | wc -l | tr -d ' '; }

out=$(STUB_YES=commission run_stubbed "$OPTED" "$PROJ" "$Q"); code=$?
expect_code 0 "$code" "no key exits 0"
assert_equals '' "$out" "no key prints no match"
assert_equals 0 "$(requests)" "no key asks nothing"
assert_contains "$(cat "$ERR")" 'exists-search: off (TYPESAFE_API_KEY absent' "no key says off"
run_stubbed "$OPTED" --enabled "$PROJ"; code=$?
expect_code 1 "$code" "--enabled is false without a key"
run_stubbed "$ON" --enabled "$PROJ"; code=$?
expect_code 0 "$code" "--enabled is true with a key and an opted-in project"
pass "off without the key: no request, no match, exit 0"

out=$(STUB_YES=commission run_stubbed "$KEYONLY" "$PROJ" "$Q"); code=$?
expect_code 0 "$code" "a key with no project list exits 0"
assert_equals '' "$out" "a key with no project list prints no match"
assert_equals 0 "$(requests)" "the key alone asks nothing"
assert_contains "$(cat "$ERR")" "off (project \"$PROJ\" is not a line of" "the key alone says the project is not opted in"
run_stubbed "$KEYONLY" --enabled "$PROJ"; code=$?
expect_code 1 "$code" "--enabled is false with the key alone"
out=$(STUB_YES=commission run_stubbed "$ON" other-proj "$Q")
assert_equals 0 "$(requests)" "a project outside the list asks nothing"
out=$(STUB_YES=commission run_stubbed "$ON" "owner/$PROJ" "$Q")
assert_equals 0 "$(requests)" "an owner/repo form of an opted-in name asks nothing"
pass "the key alone sends nothing: only a project named in config/jev-code-projects is searched"

out=$(STUB_YES=commission run_stubbed "$ON" "$PROJ" "$Q" src docs vendor); code=$?
expect_code 0 "$code" "a run with matches exits 0"
assert_equals 1 "$(requests)" "seven functions go in one request"
assert_equals 'commission_per_item() { def long_report(rows): def slugify(text): item_commission() { order_total() { shipping_fee() {' \
  "$(sort "$CALLS" | tr '\n' ' ' | sed 's/ $//')" \
  "every function of the given paths is asked about; prose, vendored code, and a secret-shaped file are never offered"
assert_equals 'src/new.sh:1: yes 0.9: item_commission() {
src/pay.sh:2: yes 0.9: commission_per_item() {' "$out" "a confident yes is a file:line match carrying the opening line"
assert_equals "$Q" "$(jq -r .question "$STATES/1")" "the question travels in the state, where the credential filter reads it"
assert_equals 'commission_per_item() {' "$(head -n 1 "$CALLS")" "the function sharing most words with the question is asked first"
long=$(jq -r '.functions[] | select(.file == "src/util.py" and (.code | startswith("def long_report"))) | .code' "$STATES/1")
assert_equals 60 "$(printf '%s\n' "$long" | wc -l | tr -d ' ')" "a long function is cut to the line bound"
assert_contains "$long" 'def long_report(rows):' "a cut function keeps its start"
# shellcheck disable=SC2016 # Fixture source text.
assert_equals 'echo $(( $1 + $2 ))' "$(jq -r '.functions[] | select(.code | startswith("order_total")) | .code' "$STATES/1" | sed -n 2p | sed 's/^ *//')" \
  "a function's text stops before the next function opens"
assert_contains "$(cat "$ERR")" '2 advisory match(es) from 6 of 6 function(s) asked;' "the summary counts the run"
pass "code finds and orders the functions; a confident yes becomes a file:line match"

out=$(STUB_YES=commission STUB_HIGH=item_commission run_stubbed "$ON" "$PROJ" "$Q" src)
assert_equals 'src/new.sh:1: yes 0.99: item_commission() {' "$(printf '%s\n' "$out" | head -n 1)" "matches are printed most probable first"
out=$(STUB_YES=slugify run_stubbed "$ON" "$PROJ" "$Q" src/util.py)
assert_equals 'def long_report(rows): def slugify(text):' "$(sort "$CALLS" | tr '\n' ' ' | sed 's/ $//')" "a path limits the search to its functions"
assert_equals 'src/util.py:1: yes 0.9: def slugify(text):' "$out" "a match in a limited search names its own file and line"
out=$(STUB_YES=commission STUB_CONF=0.59 run_stubbed "$ON" "$PROJ" "$Q" src)
assert_equals '' "$out" "a yes below the confidence floor is not a match"
assert_equals 6 "$(asked)" "low confidence still asked about every function"
out=$(run_stubbed "$ON" "$PROJ" "$Q" docs); code=$?
expect_code 0 "$code" "a search that finds no function exits 0"
assert_equals 0 "$(requests)" "no function means no request"
assert_contains "$(cat "$ERR")" '0 advisory match(es) from 0 of 0 function(s) asked;' "no function says so"
pass "ranked output, path limits, the confidence floor, and an empty search"

out=$(STUB_YES=gen_7 run_stubbed "$ON" "$PROJ" "$Q"); code=$?
expect_code 0 "$code" "a whole-project run exits 0"
assert_equals 25 "$(requests)" "the function bound caps a run at 25 requests of 8"
assert_equals 200 "$(asked)" "at most the bound of functions is asked about"
assert_contains "$(cat "$ERR")" 'from 200 of 216 function(s) asked; 16 not asked because the 200-function bound was reached' \
  "the summary says how many went unasked and why"
assert_contains "$(head -n 3 "$CALLS")" 'commission_per_item() {' "word overlap decides who is inside the bound"
out=$(STUB_FAIL=1 run_stubbed "$ON" "$PROJ" "$Q"); code=$?
expect_code 0 "$code" "a failing model exits 0"
assert_equals '' "$out" "a failing model matches nothing"
assert_equals 3 "$(requests)" "asking stops after three failed requests"
assert_contains "$(cat "$ERR")" 'from 0 of 216 function(s) asked; 216 not asked because 3 requests failed, last: stub is down' \
  "the summary says the search did not happen"
pass "bounds: the function cap and the stop after three failed requests"

out=$(STUB_YES='^commission_per_item' run_stubbed "$ON" "$PROJ" --change); code=$?
expect_code 0 "$code" "a change run exits 0"
assert_equals 'src/new.sh:1: may repeat src/pay.sh:2 (yes 0.9): commission_per_item() {
src/pay.sh:10: may repeat src/pay.sh:2 (yes 0.9): commission_per_item() {' "$out" \
  "each added function is matched to the existing one the model says already does its job"
assert_equals 4 "$(requests)" "each of the two added functions is compared in two requests of 8"
assert_not_contains "$(cat "$CALLS")" 'item_commission' "an added function is never a candidate"
assert_not_contains "$(cat "$CALLS")" 'shipping_fee' "nor is the other added function"
assert_equals 'item_commission() {' "$(jq -r '.new.code | split("\n")[0]' "$STATES/1")" "the added function travels as the probe"
assert_equals 'commission_per_item() {' "$(head -n 1 "$CALLS")" "the existing function sharing most words is compared first"
assert_contains "$(cat "$ERR")" '2 advisory match(es) for 2 function(s) added since origin/main, from 32 comparison(s);' "the change summary counts the run"
out=$(RUN_IN="$NOBASE" run_stubbed "$ON" "$PROJ" --change); code=$?
expect_code 0 "$code" "a repository with no default branch exits 0"
assert_equals 0 "$(requests)" "a repository with no default branch asks nothing"
assert_contains "$(cat "$ERR")" 'not run (no merge base with a default branch)' "a missing base says why nothing ran"
pass "--change compares each added function with the existing ones closest to it"

for bad in "--bogus $PROJ" "" "$PROJ" "$PROJ --change extra"; do
  # shellcheck disable=SC2086 # Each case is a deliberate word list.
  run_stubbed "$ON" $bad; code=$?
  expect_code 2 "$code" "\"$bad\" is a usage error"
  assert_equals 0 "$(requests)" "\"$bad\" asks nothing"
done
run_stubbed "$ON" "$PROJ" '  '; code=$?
expect_code 2 "$code" "an empty question is a usage error"
pass "bad usage exits 2 and asks nothing"

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
jq '{model: "jev-test", answers: (.questions | map_values({choice: "yes", confidence: 0.8, probabilities: {yes: 0.9, no: 0.1}}))}' \
  "$log/body.$n" > "$out"
printf '200'
SH
chmod +x "$FAKEBIN/curl"
PLANTED="ghp_$(printf 'a%.0s' $(seq 1 36))"
printf 'fetch_rates() {\n  retries=3\n  GH_TOKEN=%s\n}\n' "$PLANTED" > "$REPO/src/client.sh"
rgit add -A
rgit commit -qm client

out=$(cd "$REPO" && env PATH="$FAKEBIN:$PATH" FAKE_CURL_LOG="$LOG" TYPESAFE_API_KEY="$KEY" FM_HOME="$OPTED" \
  "$TOOL" "$PROJ" "$Q" src 2>&1); code=$?
expect_code 0 "$code" "the executable exits 0 on a run with matches"
assert_equals 1 "$(cat "$LOG/calls")" "the executable asks through the library in one request"
assert_equals 7 "$(printf '%s\n' "$out" | grep -c ': yes 0.9: ')" "every confident yes is printed"
assert_equals '["no","yes"]' "$(jq -c '[.questions[].criteria | keys] | unique[0]' "$LOG/body.1")" "each question offers exactly yes and no"
assert_equals 7 "$(jq '.questions | length' "$LOG/body.1")" "each function is its own question"
assert_equals "$(jq -c '.questions | keys' "$LOG/body.1")" "$(jq -c '.state.functions | keys' "$LOG/body.1")" \
  "the state holds exactly the functions asked about"
assert_equals "$Q" "$(jq -r .state.question "$LOG/body.1")" "the state carries the question"
sent=$(cat "$LOG/body.1")
assert_contains "$sent" 'retries=3' "the function holding a credential line is still asked about"
assert_not_contains "$sent" "$PLANTED" "a line holding a credential is in no request"
assert_contains "$sent" 'line withheld: looks like a credential' "the credential line is replaced by the placeholder"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "the key reaches curl on the fd header"
assert_not_contains "$(cat "$LOG/argv")" "$KEY" "the key never appears on curl argv"
assert_equals 'clean' "$(sort -u "$LOG/child-env")" "the key is absent from every child environment"
assert_not_contains "$out" "$KEY" "the key never appears in the output"
pass "executable: yes/no questions through the shared caller; credential lines withheld; key on the fd header only"

# --- layer 3: the brief lines ------------------------------------------------

study() { sed -n '/^# Before you write any code$/,/^# Task$/p' "$1"; }
for mode in no-mistakes direct-PR local-only; do
  FM_HOME="$ON" "$ROOT/bin/fm-brief.sh" "es-$mode" "$PROJ" --mode "$mode" >/dev/null 2>&1 \
    || fail "fm-brief.sh failed for $mode with the project opted in"
  FM_HOME="$ON" "$ROOT/bin/fm-brief.sh" "es-other-$mode" other-proj --mode "$mode" >/dev/null 2>&1 \
    || fail "fm-brief.sh failed for $mode with another project"
  FM_HOME="$KEYONLY" "$ROOT/bin/fm-brief.sh" "es-$mode" "$PROJ" --mode "$mode" >/dev/null 2>&1 \
    || fail "fm-brief.sh failed for $mode with the key alone"
  FM_HOME="$OPTED" "$ROOT/bin/fm-brief.sh" "es-$mode" "$PROJ" --mode "$mode" >/dev/null 2>&1 \
    || fail "fm-brief.sh failed for $mode with no key"
  assert_grep "\`FM_HOME=$ON $TOOL $PROJ \"<yes/no question about one function>\"" "$ON/data/es-$mode/brief.md" \
    "$mode: an opted-in project's brief offers the search for that home and project"
  assert_grep "run \`FM_HOME=$ON $TOOL $PROJ --change\`" "$ON/data/es-$mode/brief.md" \
    "$mode: an opted-in project's ship brief asks for the run over its own change"
  assert_equals "$(study "$OPTED/data/es-$mode/brief.md")" "$(study "$ON/data/es-other-$mode/brief.md")" \
    "$mode: a project outside the list gets the study section a home without the key gets"
  assert_equals "$(study "$OPTED/data/es-$mode/brief.md")" "$(study "$KEYONLY/data/es-$mode/brief.md")" \
    "$mode: the key alone leaves the study section unchanged"
  assert_no_grep 'fm-exists-search\.sh' "$OPTED/data/es-$mode/brief.md" "$mode: without the key the brief never names the search"
done
FM_HOME="$ON" "$ROOT/bin/fm-brief.sh" es-scout "$PROJ" --scout >/dev/null 2>&1 || fail "fm-brief.sh failed for a scout"
assert_grep "$TOOL $PROJ \"<yes/no question" "$ON/data/es-scout/brief.md" "a scout brief offers the search too"
assert_no_grep 'search\.sh .* --change' "$ON/data/es-scout/brief.md" "a scout brief carries no change run"
step() { ( . "$ROOT/bin/fm-dod-lib.sh"; fm_brief_exists_search_step "$@" ); }
assert_contains "$(step "$ON" "/somewhere/projects/$PROJ" ship)" "$TOOL $PROJ --change" "a recorded project path is matched by its name"
assert_equals '' "$(step "$ON" '' ship)$(step '' "$PROJ" ship)" "a missing home or project adds nothing"
pass "brief: the search is offered only for an opted-in project in a home with the key"

printf '# all fm-exists-search tests passed\n'
