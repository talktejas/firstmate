#!/usr/bin/env bash
# Drives the real bin/fm-finished-check.sh executable (real fm-jev-lib.sh) with a
# fake curl standing in for api.typesafe.ai. Prints a transcript per scenario.
set -u
ROOT=$1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H=$T/home; S=$H/state; WT=$T/wt; ID=drv; FB=$T/fakebin; REQ=$T/requests; ARGV=$T/argv
mkdir -p "$S" "$FB" "$T/home-off/state"
KEY=drive-key-51ab-secret
printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$H/.env"
git init -q "$WT"; GIT_COMMITTER_DATE=2020-01-01T00:00:00Z git -C "$WT" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m base --date 2020-01-01T00:00:00Z
"$ROOT/bin/fm-busy-event.sh" arm "$S" "$ID" >/dev/null
cp "$S/$ID.busy-state" "$T/home-off/state/" 2>/dev/null
cat > "$FB/curl" <<'SH'
#!/usr/bin/env bash
# FAKE_YES: space list of question keys answered yes. FAKE_MODE: ok|http500|fail|garbage|offlist|slow
printf '%s\n' "$*" >> "$FAKE_ARGV"; env >> "$FAKE_ARGV"
out=''; while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
body=$(cat); printf '%s\n' "$body" >> "$FAKE_REQ"
key=$(jq -r '.questions | keys[0]' <<<"$body")
case "${FAKE_MODE:-ok}" in
  http500) echo '{"error":"down"}' > "$out"; printf 500; exit 0 ;;
  fail) exit 28 ;;
  garbage) echo 'not json <html>' > "$out"; printf 200; exit 0 ;;
  offlist) jq -cn --arg k "$key" '{answers: {($k): {choice: "maybe", confidence: 0.99, probabilities: {maybe: 0.99, no: 0.01}}}}' > "$out"; printf 200; exit 0 ;;
esac
c=${FAKE_CONF:-0.95}; ch=no; p=$(jq -n --argjson c "$c" '1-$c')
case " ${FAKE_YES:-} " in *" $key "*) ch=yes; p=$c ;; esac
jq -cn --arg k "$key" --arg ch "$ch" --argjson c "$c" --argjson p "$p" '{answers: {($k): {choice: $ch, confidence: $c, probabilities: {yes: $p, no: (1-$p)}}}}' > "$out"
printf 200
SH
chmod +x "$FB/curl"
export FAKE_REQ=$REQ FAKE_ARGV=$ARGV
reset() { : > "$REQ"; : > "$ARGV"; rm -f "$S/$ID.status" "$WT/dirty"; touch -t 202601010000 "$S/$ID.busy-state"
  [ $# -eq 0 ] || { printf '%s\n' "$1" > "$S/$ID.status"; touch -t 202601010001 "$S/$ID.status"; }; }
tr_file() { # <bash cmd>... -> transcript path
  local f=$T/transcript.jsonl; jq -cn '{type:"user",message:{content:"do the task"}}' > "$f"
  for c in "$@"; do jq -cn --arg c "$c" '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}' >> "$f"; done; echo "$f"; }
FAILS=0
run() { # <name> <expect: block-substring | NONE> <home> <json>
  local name=$1 exp=$2 home=$3 json=$4 out rc asked verdict
  out=$(printf '%s' "$json" | PATH="$FB:$PATH" "$ROOT/bin/fm-finished-check.sh" "$home" "$home/state" "$ID" "$WT" 2>&1); rc=$?
  asked=$(jq -r '.questions|keys[0]' "$REQ" 2>/dev/null | tr '\n' ' ')
  if [ "$exp" = NONE ]; then [ -z "$out" ] && verdict=PASS || verdict=FAIL
  else case "$out" in *'"decision":"block"'*"$exp"*) verdict=PASS ;; *) verdict=FAIL ;; esac; fi
  [ "$rc" -eq 0 ] || verdict=FAIL
  [ "$verdict" = PASS ] || FAILS=$((FAILS+1))
  printf '\n### %s\n  exit=%s  jev-questions-asked=[%s]\n  hook output: %s\n  => %s\n' "$name" "$rc" "${asked% }" "${out:-<nothing: turn ends as today>}" "$verdict"
}
J() { jq -cn --arg m "$1" --argjson x "${2:-{\}}" '{stop_hook_active:false,last_assistant_message:$m}+$x'; }
Q='I found two ways to store the setting. Which option do you want, A or B?'

reset; FAKE_YES=asks_question run "1. unreported question -> sent back with one line" 'asks a question, but nobody was told' "$H" "$(J "$Q")"
reset; FAKE_YES='asks_question partial_or_blocked claims_finished' run "2. no key -> off, nothing asked" NONE "$T/home-off" "$(J "$Q")"
reset; FAKE_MODE=http500 FAKE_YES=asks_question run "3a. Jev returns HTTP 500 -> turn ends" NONE "$H" "$(J "$Q")"
reset; FAKE_MODE=fail FAKE_YES=asks_question run "3b. Jev unreachable/timeout (curl exit 28) -> turn ends" NONE "$H" "$(J "$Q")"
reset; FAKE_MODE=garbage run "3c. Jev returns non-JSON -> turn ends" NONE "$H" "$(J "$Q")"
reset; FAKE_MODE=offlist run "3d. Jev answers off the fixed list ('maybe' 0.99) -> turn ends" NONE "$H" "$(J "$Q")"
reset; FAKE_CONF=0.55 FAKE_YES='asks_question partial_or_blocked claims_finished' run "4. Jev unsure (yes at 0.55, floor 0.6) -> turn ends" NONE "$H" "$(J "$Q")"
reset; FAKE_YES='asks_question partial_or_blocked claims_finished claims_checks_passed' run "5. stop already follows a send-back (stop_hook_active) -> never loops" NONE "$H" "$(jq -cn --arg m "$Q" '{stop_hook_active:true,last_assistant_message:$m}')"
reset 'needs-decision: A or B?'; FAKE_YES='asks_question partial_or_blocked' run "6. question WAS reported (needs-decision:) -> nothing asked" NONE "$H" "$(J "$Q")"
reset; FAKE_YES=partial_or_blocked run "7. unreported partial work -> sent back" 'partial or blocked, but you reported no state' "$H" "$(J 'I updated the parser but the migration step is not done yet.')"
reset 'done: PR ready'; FAKE_YES=partial_or_blocked run "8. reported done: but message says partial -> sent back" 'you reported done:, but your closing message says work is partial' "$H" "$(J 'Parser updated. The migration is not done yet.')"
reset 'done: PR ready'; FAKE_YES='claims_finished asks_question' run "8b. reported done: and consistent message -> turn ends (model alone cannot block)" NONE "$H" "$(J 'Done, all committed.')"
reset; touch "$WT/dirty"; FAKE_YES=claims_finished run "9. claims finished, files changed, no state -> sent back" 'says the work is finished, but you reported no state' "$H" "$(J 'The fix is implemented and ready.')"
reset; FAKE_YES=claims_finished run "9b. claims finished, NO files changed (fact false) -> Jev not asked that, turn ends" NONE "$H" "$(J 'The current branch is fm/x. Finished looking.')"
SECRET_CMD="curl -H 'Authorization: Bearer sk-live-SHELLSECRET' https://x.example && git status"
reset 'done: ready'; TP=$(tr_file "$SECRET_CMD" "ls -la" "git commit -m wip")
FAKE_YES=claims_checks_passed run "10. claims checks passed, no check command ran this turn -> sent back" 'says checks passed, but no test or check command ran this turn' "$H" "$(J 'All tests pass and lint is clean.' "{\"transcript_path\":\"$TP\"}")"
printf '  shell command text present in ANY request sent to Jev: %s\n' "$(grep -c -E 'SHELLSECRET|git status|ls -la' "$REQ")"
printf '  top-level state keys sent: %s\n' "$(jq -c '.state|keys' "$REQ" | sort -u | tr '\n' ' ')"
grep -q -E 'SHELLSECRET|ls -la' "$REQ" && FAILS=$((FAILS+1))
reset 'done: ready'; TP=$(tr_file "git status" "npm test")
FAKE_YES=claims_checks_passed run "10b. claims checks passed and 'npm test' DID run -> not asked, turn ends" NONE "$H" "$(J 'All tests pass and lint is clean.' "{\"transcript_path\":\"$TP\"}")"
reset 'done: ready'; TP=$(tr_file $(for i in $(seq 1 60); do echo "true"; done)); TP=$(tr_file "bin/fm-test-run.sh" $(for i in $(seq 1 60); do echo "pwd"; done))
FAKE_YES=claims_checks_passed run "10c. adversarial: check ran, then 60 other commands -> still counted, turn ends" NONE "$H" "$(J 'All tests pass.' "{\"transcript_path\":\"$TP\"}")"
reset 'done: ready'; FAKE_YES=claims_checks_passed run "10d. transcript unreadable -> checks question withheld, turn ends" NONE "$H" "$(J 'All tests pass.' '{"transcript_path":"/nonexistent/t.jsonl"}')"
reset; LONG="$(head -c 9000 /dev/zero | tr '\0' 'x') Which option do you want, TAILMARK-A or B?"
FAKE_YES=asks_question run "11. 9000+ char message ending in a question -> the END is sent, question caught" 'asks a question' "$H" "$(J "$LONG")"
printf '  closing_message length sent: %s ; contains tail sentence: %s\n' "$(jq -r '.state.closing_message|length' "$REQ" | sort -u | tr '\n' ' ')" "$(grep -c TAILMARK-A "$REQ")"
reset; FAKE_YES=asks_question run "12. background tasks still running -> turn ends" NONE "$H" "$(J "$Q" '{"background_tasks":[{"id":"b1"}]}')"
reset; FAKE_YES=asks_question run "13. key hygiene (fake curl records argv+env)" 'asks a question' "$H" "$(J "$Q")"
printf '  API key occurrences in curl argv or child env: %s ; in request body: %s\n' "$(grep -c "$KEY" "$ARGV")" "$(grep -c "$KEY" "$REQ")"
grep -q "$KEY" "$ARGV" "$REQ" && FAILS=$((FAILS+1))
out=$("$ROOT/bin/fm-finished-check.sh" 2>&1 </dev/null); printf '\n### 14. wrong arg count -> exit %s, stdout/stderr: %s\n' "$?" "$out"
printf '\nSCENARIO FAILURES: %s\n' "$FAILS"
