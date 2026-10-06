#!/usr/bin/env bash
# tests/fm-intake-route.test.sh - the advisory intake routing
# (bin/fm-intake-route.sh, off unless TYPESAFE_API_KEY is present) and the
# registry listing it reads (bin/fm-project-mode.sh --list).
#
# Neither layer touches the network, and each is pinned to a fixture home so
# no real key can load:
#   - the routing's decisions, with the script sourced and fm_jev_choices
#     stubbed at the library boundary, so what code decides alone is asserted
#     by whether the model was asked at all;
#   - the real executable with the real library and a fake curl, proving the
#     request shape and that the key reaches curl on a file descriptor only.
# The library's own interface is tests/fm-jev-wake-triage.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-intake-route.sh"
MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-intake-route)
KEY='test-key-7c2e-never-on-argv'
ON="$TMP_ROOT/home-on"
OFF="$TMP_ROOT/home-off"
CALLS="$TMP_ROOT/jev-calls"
ERR="$TMP_ROOT/stderr"
PLANTED="ghp_$(printf 'a%.0s' $(seq 1 36))"

mkhome() {  # <home> <key:1|0>
  mkdir -p "$1/data" "$1/config" "$1/state"
  [ "$2" -eq 0 ] || printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$1/.env"
  cat > "$1/data/projects.md" <<EOF
# Projects

- shop [direct-PR +yolo] - Online shop storefront - checkout and cart (added 2026-01-01)
- ledger - Legacy accounting ledger (added 2026-01-02)
- scrape [local-only base=dev] - One-off catalogue scraper (added 2026-01-03)
- oldsite [direct-PR finished] - Retired marketing site (added 2026-01-04)
- gone [finished] - Another completed project (added 2026-01-05)

## Notes

- a prose bullet, not a project entry
Token note: GH_TOKEN=$PLANTED
EOF
  cat > "$1/data/secondmates.md" <<EOF
- shopmate - Owns the shop (home: /h/shopmate; scope: storefront, checkout and cart work; projects: shop; added 2026-01-01)
- books - Owns accounting (home: /h/books; scope: accounting, with GH_TOKEN="$PLANTED" noted; projects: ledger; added 2026-01-02)
- broken line without the structured suffix
EOF
}
mkhome "$ON" 1
mkhome "$OFF" 0

# --- the registry listing ---------------------------------------------------

list=$(FM_HOME="$ON" "$MODE" --list)
assert_equals 'shop ledger scrape' "$(printf '%s\n' "$list" | cut -f1 | tr '\n' ' ' | sed 's/ $//')" \
  "--list offers every entry not marked finished, and no prose bullet"
assert_equals "$(printf 'shop\tdirect-PR\tOnline shop storefront - checkout and cart (added 2026-01-01)')" \
  "$(printf '%s\n' "$list" | head -n 1)" "--list prints name, registered mode, and description"
assert_equals "$(printf 'ledger\tno-mistakes')" "$(printf '%s\n' "$list" | sed -n 2p | cut -f1,2)" "a legacy entry lists as no-mistakes"
assert_equals 'direct-PR off' "$(FM_HOME="$ON" "$MODE" oldsite)" "a finished project keeps its registered posture"
assert_equals 'no-mistakes off' "$(FM_HOME="$ON" "$MODE" gone 2>&1)" "finished alone is not read as a mode"
assert_equals '' "$(FM_HOME="$TMP_ROOT/nowhere" "$MODE" --list)" "--list prints nothing without a registry"
pass "fm-project-mode.sh --list: unfinished entries only, read from the registry"

# --- layer 1: the routing's decisions, Jev stubbed at the library boundary ----

# Runs intake_route_main with fm_jev_choices replaced by a stub that records
# each call and answers from STUB_ANSWERS. STUB_FAIL makes the call an error.
run_stubbed() {  # <home> <request text> [args...]
  local home=$1 text=$2
  shift 2
  rm -f "$CALLS" "$TMP_ROOT/state.json" "$TMP_ROOT/questions.json"
  # shellcheck disable=SC2016 # The inner shell expands its own variables.
  printf '%s' "$text" | FM_HOME="$home" CALLS="$CALLS" OUT="$TMP_ROOT" bash -c '
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
        FM_JEV_ANSWERS=$STUB_ANSWERS
        return 0
      }
      intake_route_main "$@"
    ' _ "$TOOL" "$@" 2> "$ERR"
}
calls() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }
ans() {  # <project choice> <confidence> <secondmate choice|null> <confidence>
  jq -cn --arg p "$1" --argjson pc "$2" --arg m "$3" --argjson mc "$4" '
    {answers: {project: {choice: $p, confidence: $pc, probabilities: {}},
               secondmate: (if $m == "null" then null else {choice: $m, confidence: $mc, probabilities: {}} end)}}'
}
by_hand_unasked() {  # <output> <label> <why>
  assert_equals "$(printf 'project: by hand (%s)\nsecondmate: by hand (%s)' "$3" "$3")" "$1" "$2: both lines are by hand"
  assert_equals 0 "$(calls)" "$2: the model is not asked"
}

out=$(run_stubbed "$OFF" 'the cart is broken'); code=$?
expect_code 0 "$code" "no key exits 0"
assert_equals '' "$out" "no key prints nothing on stdout"
assert_equals 0 "$(calls)" "no key: the model is not asked"
assert_contains "$(cat "$ERR")" 'intake-route: off (TYPESAFE_API_KEY absent' "no key says off"
pass "off without the key: no call, nothing printed"

export STUB_ANSWERS
STUB_ANSWERS=$(ans p1 0.9 s1 0.6)
out=$(run_stubbed "$ON" 'the cart loses items at checkout'); code=$?
expect_code 0 "$code" "a routed request exits 0"
assert_equals 1 "$(calls)" "both questions go in one request"
assert_equals "$(printf 'project: shop (confidence 0.9)\nsecondmate: shopmate (confidence 0.6)')" "$out" \
  "a confident project and a second mate exactly at the floor are advised by name"
assert_equals '["none","p1","p2","p3"]' "$(jq -c '.project.criteria | keys' "$TMP_ROOT/questions.json")" \
  "the project options are the unfinished registry entries plus none"
assert_equals '["main","s1","s2"]' "$(jq -c '.secondmate.criteria | keys' "$TMP_ROOT/questions.json")" \
  "the second-mate options are the parseable registry records plus main"
assert_equals '["projects","request","secondmates"]' "$(jq -c 'keys' "$TMP_ROOT/state.json")" "the state is the request and the two registries only"
assert_equals 'the cart loses items at checkout' "$(jq -r .request "$TMP_ROOT/state.json")" "the request text is sent whole"
assert_equals '{"name":"scrape","about":"One-off catalogue scraper (added 2026-01-03)"}' "$(jq -c .projects.p3 "$TMP_ROOT/state.json")" \
  "a project is sent as its name and registry description"
assert_equals 'storefront, checkout and cart work' "$(jq -r .secondmates.s1.scope "$TMP_ROOT/state.json")" "a second mate is sent as its registered scope"
assert_not_contains "$(cat "$TMP_ROOT/state.json" "$TMP_ROOT/questions.json")" 'oldsite' "a finished project is not offered or sent"
assert_not_contains "$(cat "$TMP_ROOT/state.json")" '/h/shopmate' "a second mate's home path is not sent"
assert_not_contains "$(cat "$TMP_ROOT/questions.json")" 'storefront' "the criteria carry no registry text, only option keys"
pass "one request; options read from the registries; confident answers advised by name"

STUB_ANSWERS=$(ans p3 0.95 s1 0.99)
out=$(run_stubbed "$ON" 'scrape the rest')
assert_equals "$(printf 'project: scrape (confidence 0.95)\nsecondmate: main (scrape is local-only)')" "$out" \
  "code keeps a local-only project in the main home whatever the model answered"
STUB_ANSWERS=$(ans p1 0.59 s2 0.59)
out=$(run_stubbed "$ON" 'something about money')
assert_equals "$(printf 'project: by hand (shop below the confidence floor, 0.59)\nsecondmate: by hand (books below the confidence floor, 0.59)')" "$out" \
  "below the floor is by hand, naming the guess"
STUB_ANSWERS=$(ans p3 0.4 s1 0.9)
out=$(run_stubbed "$ON" 'maybe the scraper')
assert_contains "$out" 'secondmate: shopmate (confidence 0.9)' "an unsure local-only project does not override the second-mate answer"
STUB_ANSWERS=$(ans none 0.97 main 0.8)
out=$(run_stubbed "$ON" 'what is the weather')
assert_equals "$(printf 'project: by hand (no single project fits, confidence 0.97)\nsecondmate: main (no scope fits, confidence 0.8)')" "$out" \
  "none is by hand and a confident main is main"
STUB_ANSWERS=$(ans p9 0.99 null 0)
out=$(run_stubbed "$ON" 'x')
assert_equals "$(printf 'project: by hand (no single project fits, confidence 0.99)\nsecondmate: by hand (no usable answer)')" "$out" \
  "an off-list project and a missing second-mate answer are by hand"
out=$(STUB_FAIL=1 run_stubbed "$ON" 'x'); code=$?
expect_code 0 "$code" "a failing model exits 0"
assert_equals "$(printf 'project: by hand (no answer: stub is down)\nsecondmate: by hand (no answer: stub is down)')" "$out" "a failed call is by hand"
pass "local-only, low confidence, none, off-list, and a failed call"

rm "$ON/data/secondmates.md"
STUB_ANSWERS=$(ans p2 0.8 null 0)
out=$(run_stubbed "$ON" 'ledger totals are off')
assert_equals "$(printf 'project: ledger (confidence 0.8)\nsecondmate: main (no second mate registered)')" "$out" "no second mate registered is main by code"
assert_equals '["project"]' "$(jq -c 'keys' "$TMP_ROOT/questions.json")" "the second-mate question is not asked without a second mate"
mkhome "$ON" 1

out=$(run_stubbed "$ON" '   '); by_hand_unasked "$out" "an empty request" 'the request is empty'
out=$(run_stubbed "$ON" "$(head -c 20001 /dev/zero | tr '\0' x)"); by_hand_unasked "$out" "an over-long request" 'the request is over 20000 bytes'
printf '# Projects\n\n- gone [finished] - Completed (added 2026-01-05)\n' > "$TMP_ROOT/only-finished.md"
mkdir -p "$TMP_ROOT/data-finished"; cp "$TMP_ROOT/only-finished.md" "$TMP_ROOT/data-finished/projects.md"
out=$(FM_DATA_OVERRIDE="$TMP_ROOT/data-finished" run_stubbed "$ON" 'x')
by_hand_unasked "$out" "a registry with no unfinished project" "no unfinished project in $TMP_ROOT/data-finished/projects.md"
run_stubbed "$ON" x --bogus >/dev/null; expect_code 2 $? "an unknown flag is a usage error"
run_stubbed "$ON" x "$TMP_ROOT/no-such-file" >/dev/null; expect_code 2 $? "an unreadable request file is a usage error"
pass "an unusable request or an empty registry is by hand without asking"

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
printf '%s' '{"model":"jev-test","answers":{"project":{"choice":"p2","confidence":0.8,"probabilities":{"p1":0.1,"p2":0.8,"p3":0.05,"none":0.05}},"secondmate":{"choice":"s2","confidence":0.9,"probabilities":{"s2":2}}}}' \
  > "$TMP_ROOT/response.json"
printf 'The ledger totals are off.\nrepro token: GH_TOKEN=%s\nIt started yesterday.\n' "$PLANTED" > "$TMP_ROOT/request.txt"
before=$(cd "$OFF" && find . -type f | sort | xargs cksum)

out=$(env PATH="$FAKEBIN:$PATH" FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$TMP_ROOT/response.json" \
  TYPESAFE_API_KEY="$KEY" FM_HOME="$OFF" "$TOOL" "$TMP_ROOT/request.txt" 2>&1); code=$?
expect_code 0 "$code" "the executable exits 0"
assert_equals 1 "$(cat "$LOG/calls")" "the executable makes one request through the library"
assert_contains "$out" 'project: ledger (confidence 0.8)' "a well-formed confident project answer is advised"
assert_contains "$out" 'secondmate: by hand (no usable answer)' "a malformed second-mate answer leaves only that line by hand"
assert_equals '["project","secondmate"]' "$(jq -c '.questions | keys' "$LOG/body.1")" "the request carries the two questions"
assert_equals 'choice' "$(jq -r '.questions.project.type' "$LOG/body.1")" "each question is a fixed Choice"
sent=$(jq -r .state.request "$LOG/body.1")
assert_contains "$sent" 'It started yesterday.' "the request text keeps its end"
assert_no_grep "$PLANTED" "$LOG/body.1" "no line holding a credential, in the request text or a registry, is in the request"
assert_contains "$sent" 'line withheld: looks like a credential' "the credential line is replaced by the placeholder"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "the key reaches curl on the fd header"
assert_not_contains "$(cat "$LOG/argv")" "$KEY" "the key never appears on curl argv"
assert_equals 'clean' "$(sort -u "$LOG/child-env")" "the key is absent from every child environment"
assert_not_contains "$out" "$KEY" "the key never appears in the output"
assert_equals "$before" "$(cd "$OFF" && find . -type f | sort | xargs cksum)" "routing writes nothing in the home"
pass "executable: one request of fixed-choice questions through the shared caller; credentials withheld; key on the fd header only"

printf '# all fm-intake-route tests passed\n'
