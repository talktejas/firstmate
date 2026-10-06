#!/usr/bin/env bash
# Drives the five Jev commands of this change as their callers run them.
# The TypeSafe endpoint is replaced by a stand-in `curl` on PATH that records
# every request and answers from STANDIN vars; everything else is the real product.
set -u
W=/home/tds/.no-mistakes/worktrees/3605d2c32b02/01M47BDF651PPA16VFF4HRAYP1
D=/tmp/fmdrive; H=$D/home; O=$D/off; L=$D/log
export TMUX_TMPDIR=$D/tmux; unset TMUX TYPESAFE_API_KEY FM_HOME
export STANDIN_LOG=$L STANDIN_JQ=$D/standin.jq FM_CREW_STATE_NO_FORGE=1
KEY=standin-key-9f3a-not-real
GHP="ghp_$(printf 'a%.0s' $(seq 1 36))"
PASS=0; FAIL=0
t() {  # <label> <cmd...>   (stdin passed through)
  rm -rf "$L"; mkdir -p "$L"; echo; echo "### $1"; shift
  printf '$'; printf ' %s' "${@//$W\//}" | cut -c1-400
  PATH="$D/bin:$PATH" "$@" >"$D/out" 2>"$D/err"; RC=$?
  sed 's/^/  stdout| /' "$D/out"; sed 's/^/  stderr| /' "$D/err"
  REQS=$(cat "$L/calls" 2>/dev/null || echo 0); OUT=$(cat "$D/out"); ERR=$(cat "$D/err")
  echo "  exit=$RC requests-made=$REQS"
}
ok() { if eval "$2"; then PASS=$((PASS+1)); echo "  PASS: $1"; else FAIL=$((FAIL+1)); echo "  FAIL: $1"; fi; }
bodies() { cat "$L"/body.* 2>/dev/null; }
keysafe() { ok "key only on the fd header: not on curl argv, not in child env" '[ "$(cat $L/header)" = "Authorization: Bearer $KEY" ] && ! grep -q "$KEY" $L/argv && ! grep -q key-in $L/env'; }
snap() { (cd "$1" && find . -type f ! -name '*.lock' -exec sha1sum {} + | sort); }
SNAP_BEFORE=$(snap $H)

echo "=================== 1. ESCALATION SCREEN ==================="
S=$W/bin/fm-escalation-screen.sh
t "no key: off, by hand, nothing sent" env FM_HOME=$O $S "Should dates show as DD/MM/YYYY or MM/DD/YYYY?"
ok "by hand (off), exit 0, 0 requests" '[[ $OUT == "screen: by hand (off,"* ]] && [ $RC = 0 ] && [ $REQS = 0 ]'
for q in "Should I merge the pull request now?" "Has the captain approved shipping this?" "Should the old rows be deleted?" \
  "Should the stale branch be dropped?" "Should I remove the legacy table?" "Rotate the API token now?" \
  "Is it OK to FORCE-PUSH over the branch?" "Which password policy do we want?"; do
  t "code rule (key present, stand-in would say cheap-to-reverse 0.99)" env FM_HOME=$H CHOICE=cheap-to-reverse CONF=0.99 $S "$q"
  ok "captain's by code, 0 requests" '[[ $OUT == "screen: captain'"'"'s (names a merge"* ]] && [ $REQS = 0 ] && [ $RC = 0 ]'
done
t "review-gate line is by hand, not asked" env FM_HOME=$H CHOICE=cheap-to-reverse CONF=0.99 $S "ask-user findings=2 on the storefront change"
ok "by hand, 0 requests" '[[ $OUT == "screen: by hand (a review gate"* ]] && [ $REQS = 0 ]'
t "over-long question is by hand, not cut and sent" env FM_HOME=$H CHOICE=cheap-to-reverse CONF=0.99 $S "$(printf 'Which layout? %.0s' $(seq 1 400))"
ok "by hand, 0 requests" '[[ $OUT == "screen: by hand (the question is over 4000"* ]] && [ $REQS = 0 ]'
t "cheap-to-reverse at 0.95 -> yours" env FM_HOME=$H CHOICE=cheap-to-reverse CONF=0.95 $S "Should the helper live in utils.py or a new export module?
export GH_TOKEN=$GHP"
ok "yours, one request" '[ "$OUT" = "screen: yours (cheap-to-reverse, confidence 0.95)" ] && [ $REQS = 1 ]'
echo "  sent state: $(jq -c .state $L/body.1)"
ok "state holds only the question; credential line withheld" '[ "$(jq -c ".state|keys" $L/body.1)" = "[\"question\"]" ] && ! bodies | grep -q "$GHP" && bodies | grep -q "line withheld"'
keysafe
t "cheap-to-reverse below the floor (0.4) -> by hand" env FM_HOME=$H CHOICE=cheap-to-reverse CONF=0.4 $S "Should the empty-state text say No members yet?"
ok "by hand" '[[ $OUT == "screen: by hand (cheap-to-reverse below the confidence floor"* ]]'
t "trade at low confidence (0.3) -> captain's (a small answer never removes the stop)" env FM_HOME=$H CHOICE=trade CONF=0.3 $S "Is commission clawed back on returned stock?"
ok "captain's" '[ "$OUT" = "screen: captain'"'"'s (trade, confidence 0.3)" ]'
t "unclear -> by hand" env FM_HOME=$H CHOICE=unclear CONF=0.95 $S "Which one do you prefer?"
ok "by hand" '[[ $OUT == "screen: by hand (unclear"* ]]'
t "endpoint times out -> by hand, exit 0" env FM_HOME=$H STANDIN_FAIL=1 CHOICE=x CONF=1 $S "Should the helper live in utils.py?"
ok "by hand, exit 0" '[[ $OUT == "screen: by hand (no answer:"* ]] && [ $RC = 0 ]'
t "answer outside the fixed kinds -> by hand" env FM_HOME=$H CHOICE=approve-it CONF=0.99 $S "Should the helper live in utils.py?"
ok "by hand, never yours" '[[ $OUT == "screen: by hand"* ]] && [ $RC = 0 ]'
t "no question -> usage error" env FM_HOME=$H $S
ok "exit 2" '[ $RC = 2 ]'

echo; echo "=================== 2. HELPER MODEL PICK ==================="
M=$W/bin/fm-helper-model.sh
en() { PATH="$D/bin:$PATH" $M --enabled "$@" 2>/dev/null; echo $?; }
echo "--enabled exit codes (0 = spawn adds the hook):"
echo "  key + listed project + opus worker        : $(en $H proj claude-opus-5-5)"
echo "  no key                                    : $(en $O proj claude-opus-5-5)"
echo "  project not listed                        : $(en $H otherproj claude-opus-5-5)"
echo "  bare name 'widgets' vs listed acme/widgets: $(en $H widgets claude-opus-5-5)"
echo "  worker already sonnet                     : $(en $H proj claude-sonnet-5-5)"
echo "  worker model not named                    : $(en $H proj '')"
ok "--enabled gate" '[ "$(en $H proj claude-opus-5-5)$(en $O proj claude-opus-5-5)$(en $H otherproj claude-opus-5-5)$(en $H widgets claude-opus-5-5)$(en $H proj claude-sonnet-5-5)$(en $H proj "")" = 011111 ]'
hk() { jq -n --arg t "${1-general-purpose}" --arg m "${2-}" --arg g "$GHP" '{session_id:"s1",tool_name:"Agent",tool_input:({description:"Find callers",prompt:("List every file under src/ that calls parse_rate and report file and line.\nexport GH_TOKEN="+$g),subagent_type:$t,run_in_background:true} + (if $m=="" then {} else {model:$m} end))}'; }
t "mechanical 0.95, listed project -> lowered to sonnet" env CHOICE=mechanical CONF=0.95 $M --hook $H proj < <(hk)
ok "prints updatedInput with model sonnet, other fields intact, no permission decision" 'jq -e ".hookSpecificOutput.updatedInput.model==\"sonnet\" and .hookSpecificOutput.updatedInput.run_in_background==true and (.hookSpecificOutput|has(\"permissionDecision\")|not) and (.|has(\"decision\")|not)" $D/out >/dev/null && [ $REQS = 1 ] && [ $RC = 0 ]'
ok "prompt handed on whole (credential line still in the worker's own hand-off)" 'jq -r .hookSpecificOutput.updatedInput.prompt $D/out | grep -q "$GHP"'
echo "  sent state: $(jq -c .state $L/body.1)"
ok "request holds only description, type, prompt; credential line withheld" '[ "$(jq -c ".state.helper|keys" $L/body.1)" = "[\"description\",\"prompt\",\"type\"]" ] && ! bodies | grep -q "$GHP"'
keysafe
t "judgement -> prints nothing" env CHOICE=judgement CONF=0.99 $M --hook $H proj < <(hk)
ok "empty output, exit 0" '[ -z "$OUT" ] && [ $RC = 0 ] && [ $REQS = 1 ]'
t "mechanical below floor (0.5) -> prints nothing" env CHOICE=mechanical CONF=0.5 $M --hook $H proj < <(hk)
ok "empty output" '[ -z "$OUT" ] && [ $RC = 0 ]'
t "hand-off already names a model (opus) -> never asked, never raised or lowered" env CHOICE=mechanical CONF=0.99 $M --hook $H proj < <(hk general-purpose opus)
ok "empty, 0 requests" '[ -z "$OUT" ] && [ $REQS = 0 ]'
t "helper type Explore (carries its own model) -> never asked" env CHOICE=mechanical CONF=0.99 $M --hook $H proj < <(hk Explore)
ok "empty, 0 requests" '[ -z "$OUT" ] && [ $REQS = 0 ]'
t "project not in jev-code-projects -> nothing sent" env CHOICE=mechanical CONF=0.99 $M --hook $H otherproj < <(hk)
ok "empty, 0 requests" '[ -z "$OUT" ] && [ $REQS = 0 ]'
t "bare name vs owner/repo entry -> nothing sent" env CHOICE=mechanical CONF=0.99 $M --hook $H widgets < <(hk)
ok "empty, 0 requests" '[ -z "$OUT" ] && [ $REQS = 0 ]'
t "no key -> nothing sent" env CHOICE=mechanical CONF=0.99 $M --hook $O proj < <(hk)
ok "empty, 0 requests" '[ -z "$OUT" ] && [ $REQS = 0 ]'
t "endpoint fails -> prints nothing, exit 0" env STANDIN_FAIL=1 CHOICE=mechanical CONF=0.99 $M --hook $H proj < <(hk)
ok "empty, exit 0" '[ -z "$OUT" ] && [ $RC = 0 ]'
t "garbage on stdin -> prints nothing, exit 0" env CHOICE=mechanical CONF=0.99 $M --hook $H proj <<<"not json"
ok "empty, exit 0, 0 requests" '[ -z "$OUT" ] && [ $RC = 0 ] && [ $REQS = 0 ]'

echo; echo "=================== 3. INTAKE ROUTING ==================="
R=$W/bin/fm-intake-route.sh; PM=$W/bin/fm-project-mode.sh
t "registry listing leaves the finished project out" env FM_HOME=$H $PM --list
ok "three unfinished entries, no oldblog, no prose bullet" '[ "$(cut -f1 $D/out | tr "\n" " ")" = "storefront ledger catalogue-scrape " ]'
t "finished keeps the project's registered posture" env FM_HOME=$H $PM oldblog
ok "oldblog still resolves direct-PR" '[[ $OUT == direct-PR* ]]'
t "no key: off" env FM_HOME=$O $R <<<"Checkout fails with a 500 when the cart holds more than twenty items."
ok "nothing on stdout, off on stderr, 0 requests" '[ -z "$OUT" ] && [[ $ERR == "intake-route: off"* ]] && [ $REQS = 0 ] && [ $RC = 0 ]'
t "storefront request -> project and second mate advised" env FM_HOME=$H CHOICE_project=p1 CHOICE_secondmate=s1 CONF=0.97 $R <<<"Checkout fails with a 500 when the cart holds more than twenty items.
GH_TOKEN=$GHP"
ok "two advisory lines, one request" '[ "$OUT" = "project: storefront (confidence 0.97)
secondmate: shop (confidence 0.97)" ] && [ $REQS = 1 ]'
echo "  sent state: $(jq -c .state $L/body.1)"
echo "  project options: $(jq -c '.questions.project.criteria|keys' $L/body.1)  secondmate options: $(jq -c '.questions.secondmate.criteria|keys' $L/body.1)"
ok "finished project never offered or sent; no credential; state is request + registry text only" '! bodies | grep -q oldblog && ! bodies | grep -q "$GHP" && [ "$(jq -c ".state|keys" $L/body.1)" = "[\"projects\",\"request\",\"secondmates\"]" ] && [ "$(jq -c ".questions.project.criteria|keys" $L/body.1)" = "[\"none\",\"p1\",\"p2\",\"p3\"]" ]'
keysafe
t "local-only project -> second mate forced to main by code" env FM_HOME=$H CHOICE_project=p3 CHOICE_secondmate=s1 CONF=0.97 $R <<<"Collect the remaining exhibitors from hall 7."
ok "main (local-only)" '[[ $OUT == *"secondmate: main (catalogue-scrape is local-only)" ]]'
t "low confidence -> by hand" env FM_HOME=$H CHOICE_project=p1 CHOICE_secondmate=s1 CONF=0.4 $R <<<"Add a dark mode."
ok "both by hand" '[[ $OUT == "project: by hand (storefront below"*"secondmate: by hand"* ]]'
t "answer names a project that is not offered -> by hand" env FM_HOME=$H CHOICE_project=p4 CHOICE_secondmate=main CONF=0.99 $R <<<"Fix the typo in the latest blog post."
ok "project by hand" '[[ $OUT == "project: by hand"* ]] && [ $RC = 0 ]'
t "empty request -> by hand, not asked" env FM_HOME=$H CHOICE=p1 CONF=1 $R <<<"   "
ok "by hand, 0 requests" '[[ $OUT == "project: by hand (the request is empty)"* ]] && [ $REQS = 0 ]'
t "oversized request -> by hand, not cut and sent" env FM_HOME=$H CHOICE=p1 CONF=1 $R < <(head -c 20001 /dev/zero | tr '\0' x)
ok "by hand, 0 requests" '[[ $OUT == "project: by hand (the request is over 20000 bytes)"* ]] && [ $REQS = 0 ]'
t "endpoint fails -> by hand, exit 0" env FM_HOME=$H STANDIN_FAIL=1 CHOICE=p1 CONF=1 $R <<<"Checkout fails."
ok "by hand, exit 0" '[[ $OUT == "project: by hand (no answer"* ]] && [ $RC = 0 ]'

echo; echo "=================== 4. WORKER HEALTH ==================="
HL=$W/bin/fm-worker-health.sh; CS=$W/bin/fm-crew-state.sh
G=$(cat $D/gen)
printf 'working: [2026-10-06T10:00:00Z] setup done, starting on the fix\nworking: [2026-10-06T10:02:00Z] note GH_TOKEN="%s"\n' "$GHP" > $H/state/t1.status
mkdir -p $H/state/t1.inbox; echo "INBOX-MESSAGE-TEXT-q7" > $H/state/t1.inbox/001.msg
echo "  real pane content right now: $(tmux capture-pane -p -t fmdrive:fm-t1 | head -2 | tr '\n' ' ')"
t "real crew-state read of the fixture task (idle harness, status log)" env FM_HOME=$H $CS t1
CREW=$OUT
t "no key: the crew-state line alone" env FM_HOME=$O FM_STATE_OVERRIDE=$H/state CHOICE=stuck CONF=0.99 $HL t1
ok "stdout is exactly the crew-state line, 0 requests" '[ "$OUT" = "$CREW" ] && [ $REQS = 0 ] && [ $RC = 0 ]'
t "key present, stuck 0.9 -> advisory health line added" env FM_HOME=$H CHOICE=stuck CONF=0.9 $HL t1
ok "crew-state line unchanged first, then health line" '[ "$OUT" = "$CREW
health: stuck (confidence 0.9, advice only)" ] && [ $REQS = 1 ]'
echo "  sent state: $(jq -c .state $L/body.1)"
ok "never the pane, never typed shell text, never an inbox message's text, credential status line withheld" '! bodies | grep -q PANE-TYPED-MARKER-zz91 && ! bodies | grep -q INBOX-MESSAGE-TEXT-q7 && ! bodies | grep -q "$GHP" && bodies | grep -q "line withheld" && [ "$(jq .state.worker.unread_instructions $L/body.1)" = 1 ]'
keysafe
for c in working waiting finished; do
  t "$c 0.8 -> health line" env FM_HOME=$H CHOICE=$c CONF=0.8 $HL t1
  ok "health: $c" '[[ $OUT == *"health: '$c' (confidence 0.8, advice only)" ]]'
done
t "low confidence (0.5) -> no health line" env FM_HOME=$H CHOICE=stuck CONF=0.5 $HL t1
ok "crew-state line alone" '[ "$OUT" = "$CREW" ] && [ $RC = 0 ]'
t "answer outside the four kinds -> no health line" env FM_HOME=$H CHOICE=kill-it CONF=0.99 $HL t1
ok "crew-state line alone" '[ "$OUT" = "$CREW" ] && [ $RC = 0 ]'
t "endpoint fails -> no health line, exit 0" env FM_HOME=$H STANDIN_FAIL=1 CHOICE=stuck CONF=0.9 $HL t1
ok "crew-state line alone" '[ "$OUT" = "$CREW" ] && [ $RC = 0 ]'
$W/bin/fm-busy-event.sh apply $H/state t1 busy --gen $G --source claude-hook --event prompt-submit
t "harness busy (real pane read) -> still asked, working" env FM_HOME=$H CHOICE=working CONF=0.95 $HL t1
ok "source: pane line then health: working" '[[ $OUT == "state: working · source: pane"*"health: working"* ]] && ! bodies | grep -q PANE-TYPED-MARKER-zz91'
$W/bin/fm-busy-event.sh apply $H/state t1 idle --gen $G --source claude-hook --event stop
printf 'kind=ship\nworktree=/tmp/fmdrive/gone\n' > $H/state/t2.meta; echo 'working: [x] hi' > $H/state/t2.status
t "worktree gone (source: none) -> code decides, never asked" env FM_HOME=$H CHOICE=stuck CONF=0.99 $HL t2
ok "one line, 0 requests" '[ "$(wc -l < $D/out)" = 1 ] && [ $REQS = 0 ]'
sed 's/kind=ship/kind=secondmate/' $H/state/t1.meta > $H/state/t3.meta; cp $H/state/t1.status $H/state/t3.status
t "secondmate -> never asked" env FM_HOME=$H CHOICE=stuck CONF=0.99 $HL t3
ok "0 requests, no health line" '[ $REQS = 0 ] && ! grep -q "^health:" $D/out'
t "bad task id -> usage error" env FM_HOME=$H $HL '../etc'
ok "exit 2" '[ $RC = 2 ]'
rm -f $H/state/t2.* $H/state/t3.*

echo; echo "=================== 5. ALREADY-EXISTS SEARCH ==================="
X=$W/bin/fm-exists-search.sh; cd $D/proj
Q="Does this function parse a rate string into a number?"
t "no key: off" env FM_HOME=$O YES_RE=rate CONF=0.9 $X proj "$Q"
ok "off line, nothing printed, 0 requests" '[ -z "$OUT" ] && [[ $ERR == "exists-search: off (TYPESAFE_API_KEY"* ]] && [ $REQS = 0 ] && [ $RC = 0 ]'
t "project not opted in: off, no code leaves" env FM_HOME=$H YES_RE=rate CONF=0.9 $X otherproj "$Q"
ok "off, 0 requests" '[ -z "$OUT" ] && [[ $ERR == *"is not a line of"* ]] && [ $REQS = 0 ]'
t "bare name 'widgets' does not match the owner/repo entry acme/widgets" env FM_HOME=$H YES_RE=rate CONF=0.9 $X widgets "$Q"
ok "off, 0 requests" '[ -z "$OUT" ] && [ $REQS = 0 ]'
t "opted-in project, a question" env FM_HOME=$H YES_RE='rate string' CONF=0.93 $X proj "$Q"
ok "prints the two functions that do it, as file:line" 'grep -q "^lib/rates.sh:1: yes 0.93: parse_rate() {" $D/out && grep -q "^lib/new.sh:1: yes 0.93: rate_from_string() {" $D/out && [ "$(wc -l < $D/out)" = 2 ]'
echo "  files sent: $(bodies | jq -r '.state.functions[].file' | sort -u | tr '\n' ' ')"
ok "secret-named file never offered; credential line inside a function withheld" '! bodies | grep -q "secrets.sh" && ! bodies | grep -q hunter2 && ! bodies | grep -q "$GHP" && bodies | grep -q "line withheld"'
keysafe
t "path limit" env FM_HOME=$H YES_RE='.' CONF=0.9 $X proj "$Q" lib/util.py
ok "only lib/util.py asked about" '[ "$(bodies | jq -r ".state.functions[].file" | sort -u)" = lib/util.py ]'
t "yes below the floor -> no match" env FM_HOME=$H YES_RE='rate string' CONF=0.5 $X proj "$Q"
ok "nothing printed, exit 0" '[ -z "$OUT" ] && [ $RC = 0 ]'
t "endpoint fails -> no match, exit 0, says how many went unasked" env FM_HOME=$H STANDIN_FAIL=1 YES_RE=rate CONF=0.9 $X proj "$Q"
ok "exit 0, nothing printed" '[ -z "$OUT" ] && [ $RC = 0 ] && [[ $ERR == *"not asked because"* ]]'
t "--change on the feat branch (adds rate_from_string)" env FM_HOME=$H YES_RE='rate string' CONF=0.96 $X proj --change
ok "names the existing function the new one may repeat" '[ "$OUT" = "lib/new.sh:1: may repeat lib/rates.sh:1 (yes 0.96): parse_rate() {" ]'
t "--enabled gate" env FM_HOME=$H $X --enabled proj
ok "exit 0 opted in; 1 when not" '[ $RC = 0 ] && ! FM_HOME=$H $X --enabled otherproj && ! FM_HOME=$O $X --enabled proj'
t "no question -> usage error" env FM_HOME=$H $X proj
ok "exit 2" '[ $RC = 2 ]'
cd $W
t "ship brief gains the search lines only when opted in" bash -c ". $W/bin/fm-dod-lib.sh; fm_brief_exists_search_step $H $D/proj ship"
ok "brief lines name the command and --change" '[[ $OUT == *"fm-exists-search.sh proj"*"--change"* ]]'
t "brief for a project not opted in" bash -c ". $W/bin/fm-dod-lib.sh; fm_brief_exists_search_step $H /x/otherproj ship"
ok "adds nothing" '[ -z "$OUT" ]'

echo; echo "=================== HOME UNTOUCHED ==================="
rm -rf $H/state/t1.inbox; printf 'working: [2026-10-06T10:00:00Z] setup done, starting on the fix\n' > $H/state/t1.status
SNAP_AFTER=$(snap $H)
echo "files in the home after every run above:"; (cd $H && find . -type f | sort | sed 's/^/  /')
ok "no command wrote a record into the home (only the fixture's own busy-state changed)" '[ "$(diff <(echo "$SNAP_BEFORE" | grep -v "busy-state\|t1.status") <(echo "$SNAP_AFTER" | grep -v "busy-state\|t1.status"))" = "" ]'
echo; echo "TOTAL: $PASS passed, $FAIL failed"
