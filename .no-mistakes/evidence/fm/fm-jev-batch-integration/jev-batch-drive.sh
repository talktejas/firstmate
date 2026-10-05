#!/usr/bin/env bash
# Manual drive of the real firstmate scripts for the Jev batch. The only thing
# replaced is the remote TypeSafe endpoint: `curl` on PATH is a recorder that
# saves each request body and answers in the API's shape. git, jq, the hooks,
# and every bin/ script are the real ones. `gh` is a fixture forge.
set -u
ROOT=$(pwd)
. "$ROOT/tests/lib.sh"
T=$(fm_test_tmproot fm-jev-drive)
BIN="$T/bin"; LOG="$T/log"; mkdir -p "$BIN" "$LOG"
KEY='drive-key-77aa-never-on-argv'
GHP="ghp_$(printf 'Z%.0s' $(seq 1 36))"
AWS="AKIA$(printf 'Q%.0s' $(seq 1 16))"
FAILS=0

cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
out=''
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; *) printf '%s\n' "$1" >> "$DRIVE_LOG/argv"; shift ;; esac
done
n=$(( $(cat "$DRIVE_LOG/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$DRIVE_LOG/count"
cat > "$DRIVE_LOG/body"; cp "$DRIVE_LOG/body" "$DRIVE_LOG/body.$n"
[ "${DRIVE_CURL_FAIL:-0}" = 0 ] || exit "$DRIVE_CURL_FAIL"
jq -c --arg want "${DRIVE_CHOICE:-no}" '{model: "jev-recorder", answers: (.questions | map_values(
  (.criteria | keys) as $ks | (if ($ks | index($want)) then $want else $ks[0] end) as $c |
  {choice: $c, confidence: 0.9, probabilities: ($ks | map({key: ., value: (if . == $c then 0.9 else (0.1 / (($ks | length) - 1)) end)}) | from_entries)}))}' \
  "$DRIVE_LOG/body" > "$out"
printf 200
SH
chmod +x "$BIN/curl"
export DRIVE_LOG="$LOG" PATH="$BIN:$PATH"
reset_log() { rm -f "$LOG"/*; }
requests() { cat "$LOG/count" 2>/dev/null || echo 0; }
say() { printf '\n=== %s\n' "$*"; }
expect() {  # <description> <command...>
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then printf 'PASS  %s\n' "$d"; else printf 'FAIL  %s\n' "$d"; FAILS=$((FAILS + 1)); fi
}
body_has() { grep -qF -- "$1" "$LOG"/body* 2>/dev/null; }
body_lacks() { ! body_has "$1"; }
eq() { [ "$1" = "$2" ]; }

fm_git_identity

###########################################################################
say "A. commit check: real git commits through the hooks --install writes"
H="$T/home"; mkdir -p "$H/config" "$H/state"
printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$H/.env"
printf '# opted in\nlisted\n' > "$H/config/jev-code-projects"
WT="$T/wt"; fm_git_init_commit "$WT"
OTHER="$T/other"; fm_git_init_commit "$OTHER"

out=$("$ROOT/bin/fm-commit-check.sh" --install "$T/hooks-unlisted" "$H" notlisted "$WT" 2>&1); rc=$?
printf '$ fm-commit-check.sh --install <hooks> <home> notlisted <wt>   -> rc=%s output=[%s]\n' "$rc" "$out"
expect "an unlisted project gets no hooks: exit 1, nothing printed, no directory" \
  bash -c "[ $rc -eq 1 ] && [ -z '$out' ] && [ ! -e '$T/hooks-unlisted' ]"
out=$("$ROOT/bin/fm-commit-check.sh" --install "$T/hooks-other-owner" "$H" someone/listed "$WT" 2>&1); rc=$?
expect "an owner/repo spelling does not match the bare project entry" eq "$rc" 1

GCP=$("$ROOT/bin/fm-commit-check.sh" --install "$T/hooks" "$H" listed "$WT"); rc=$?
printf '$ fm-commit-check.sh --install <hooks> <home> listed <wt>      -> rc=%s setting=[%s]\n' "$rc" "${GCP//$T/<tmp>}"
expect "a listed project with a key gets the hooks setting" bash -c "[ $rc -eq 0 ] && [ -n \"\$1\" ]" _ "$GCP"

reset_log
mkdir -p "$WT/src"
printf 'const SOURCE_BODY_MARKER = 41\n' > "$WT/src/parser.js"
printf 'SOURCE_BODY_MARKER docs\n' > "$WT/notes.md"
git -C "$WT" add -A
msg=$(printf 'Parse trailing commas\n\nReproduced with the staging token:\nGH_TOKEN=%s\nNothing else changed.' "$GHP")
err=$(GIT_CONFIG_PARAMETERS=$GCP git -C "$WT" commit -q -m "$msg" 2>&1); rc=$?
printf '$ git commit -m "<message holding a GitHub token line>"   -> rc=%s stderr=[%s] requests=%s\n' "$rc" "$err" "$(requests)"
printf 'state sent to Jev:\n'; jq .state "$LOG/body"
expect "the commit is made" eq "$(git -C "$WT" log -1 --format=%s)" 'Parse trailing commas'
expect "exactly one request per commit" eq "$(requests)" 1
expect "the token pasted into the message is not in the request" body_lacks "$GHP"
expect "its line is replaced by the fixed placeholder" body_has 'line withheld: looks like a credential'
expect "no line of staged content is sent, only names" body_lacks SOURCE_BODY_MARKER
expect "the key is not on curl argv" bash -c "! grep -qF '$KEY' '$LOG/argv'"

reset_log
printf 'x = 2\n' > "$WT/src/a.py"; printf 'y = 2\n' > "$WT/src/b.py"; git -C "$WT" add -A
before=$(git -C "$WT" rev-parse HEAD)
err=$(DRIVE_CHOICE=yes GIT_CONFIG_PARAMETERS=$GCP git -C "$WT" commit -q -m 'update' 2>&1); rc=$?
printf '$ git commit -m update   (Jev answers yes to every question)   -> rc=%s\n%s\n' "$rc" "$err"
expect "three confident yes answers only advise: the commit still goes through" \
  bash -c "[ $rc -eq 0 ] && [ '$(git -C "$WT" rev-parse HEAD)' != '$before' ]"
expect "the advice says the commit goes through" bash -c "printf '%s' \"\$1\" | grep -q 'advisory, the commit goes through'" _ "$err"

reset_log
printf 'z = 3\n' > "$WT/src/c.py"; git -C "$WT" add -A
err=$(DRIVE_CURL_FAIL=28 GIT_CONFIG_PARAMETERS=$GCP git -C "$WT" commit -q -m 'Add c module' 2>&1); rc=$?
printf '$ git commit   (Jev times out)   -> rc=%s stderr=[%s]\n' "$rc" "$err"
expect "a Jev timeout neither stops the commit nor says anything" bash -c "[ $rc -eq 0 ] && [ -z \"\$1\" ]" _ "$err"

reset_log
printf 'token = "%s"\n' "$GHP" > "$WT/src/conf.py"; git -C "$WT" add -A
before=$(git -C "$WT" rev-parse HEAD)
err=$(GIT_CONFIG_PARAMETERS=$GCP git -C "$WT" commit -q -m 'Add the client config' 2>&1); rc=$?
printf '$ git commit   (a staged line holds a GitHub token)   -> rc=%s\n%s\n' "$rc" "$err"
expect "the pattern stop refuses the commit by code alone" bash -c "[ $rc -ne 0 ] && [ '$(git -C "$WT" rev-parse HEAD)' = '$before' ]"
expect "the stop names file:line and kind, never the value" bash -c "printf '%s' \"\$1\" | grep -q 'src/conf.py:1: GitHub token' && ! printf '%s' \"\$1\" | grep -qF '$GHP'" _ "$err"
expect "nothing is sent for a stopped commit" eq "$(requests)" 0
git -C "$WT" reset -q --hard

reset_log
printf 'token = "%s"\n' "$GHP" > "$OTHER/conf.py"; git -C "$OTHER" add -A
err=$(GIT_CONFIG_PARAMETERS=$GCP git -C "$OTHER" commit -q -m 'x' 2>&1); rc=$?
printf '$ git commit in ANOTHER repository under the same exported setting   -> rc=%s stderr=[%s] requests=%s\n' "$rc" "$err" "$(requests)"
expect "a repository that is not the task worktree is untouched: committed, silent, nothing sent" \
  bash -c "[ $rc -eq 0 ] && [ -z \"\$1\" ] && [ '$(requests)' = 0 ]" _ "$err"

reset_log
: > "$H/config/jev-code-projects"
printf 'w = 4\n' > "$WT/src/d.py"; git -C "$WT" add -A
err=$(GIT_CONFIG_PARAMETERS=$GCP git -C "$WT" commit -q -m 'update' 2>&1); rc=$?
printf '$ git commit after the project was removed from the list   -> rc=%s stderr=[%s] requests=%s\n' "$rc" "$err" "$(requests)"
expect "delisting the project stops every send at once" bash -c "[ $rc -eq 0 ] && [ '$(requests)' = 0 ]"

###########################################################################
say "B. risk level: real bin/fm-pr-check.sh registration"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DRIVE_LOG/gh-calls"
[ -n "${DRIVE_GH:-}" ] && exec "$DRIVE_GH" "$@"
[ -n "${FAKE_PR_JSON:-}" ] || exit 1
printf '%s\n' "$FAKE_PR_JSON"
SH
chmod +x "$BIN/gh"
PROJ="$T/alpha"; fm_git_init_commit "$PROJ"
PWT="$T/alpha-wt"; git -C "$PROJ" worktree add -q -b task-a "$PWT"
mkdir -p "$PWT/src" "$PWT/deploy"
printf 'export const retries = 3\nconst awsKey = "%s"\n' "$AWS" > "$PWT/src/client.js"
printf 'ENV_FILE_MARKER=1\n' > "$PWT/deploy/.env"
printf 'PEM_FILE_MARKER\n' > "$PWT/deploy/server.pem"
git -C "$PWT" add -A; git -C "$PWT" commit -qm 'client and deploy files'
URL='https://github.com/acme/alpha/pull/8'
export FM_HOME="$H" FM_GUARD_GRACE=999999
register() {  # [env...] [-- extra args]
  fm_write_meta "$H/state/task-a.meta" "window=fm-task-a" "kind=ship" "worktree=$PWT" "project=$PROJ"
  rm -f "$H/state/task-a.pr-poll"; reset_log
  env FM_STATE_OVERRIDE="$H/state" FAKE_PR_JSON='{"title":"Add client","body":"Adds the client."}' "$@" 2>"$T/err"
}
show() { printf '$ %s\n%s\n(rc=%s, requests=%s)\n' "$1" "$2" "$3" "$(requests)"; }

printf 'alpha\n' > "$H/config/jev-code-projects"
out=$(register "$ROOT/bin/fm-pr-check.sh" task-a "$URL"); rc=$?
show "fm-pr-check.sh task-a $URL   [alpha listed, key present]" "$out" "$rc"
printf 'diff_start sent to Jev:\n'; jq -r '.state.change.diff_start' "$LOG/body.1" 2>/dev/null
expect "the registration succeeds and prints one risk line after the arming" \
  bash -c "[ $rc -eq 0 ] && printf '%s' \"\$1\" | sed -n 2p | grep -q '^risk: '" _ "$out"
expect "the pull request is recorded and the merge poll armed" \
  bash -c "grep -qxF 'pr=$URL' '$H/state/task-a.meta' && [ -e '$H/state/task-a.pr-poll' ]"
expect "the ordinary source line is sent" body_has 'export const retries = 3'
expect "the AWS key line in an ordinary file is in no request" body_lacks "$AWS"
expect "the .env file's content is in no request" body_lacks ENV_FILE_MARKER
expect "the .pem file's content is in no request" body_lacks PEM_FILE_MARKER

printf 'acme/alpha\nalpha-web\n# alpha\n' > "$H/config/jev-code-projects"
out=$(register "$ROOT/bin/fm-pr-check.sh" task-a "$URL"); rc=$?
show "fm-pr-check.sh task-a $URL   [list holds acme/alpha, alpha-web, '# alpha']" "$out" "$rc"
expect "an owner/repo entry, a similar name, and a commented name do not list a firstmate project: nothing sent" eq "$(requests)" 0
expect "the unlisted project still registers and says why it is not rated" \
  bash -c "[ $rc -eq 0 ] && printf '%s' \"\$1\" | grep -q 'project not listed' && [ -e '$H/state/task-a.pr-poll' ]" _ "$out"
expect "the forge description is not read for an unlisted project" bash -c "! grep -q 'title' '$LOG/gh-calls' 2>/dev/null"

printf 'alpha\n' > "$H/config/jev-code-projects"
out=$(register DRIVE_CHOICE=yes "$ROOT/bin/fm-pr-check.sh" task-a "$URL"); rc=$?
show "fm-pr-check.sh task-a $URL   [Jev answers yes to everything]" "$out" "$rc"
expect "a worst-case Jev answer still registers and arms: the level is a printed line only" \
  bash -c "[ $rc -eq 0 ] && [ -e '$H/state/task-a.pr-poll' ]"
out=$(register DRIVE_CURL_FAIL=28 "$ROOT/bin/fm-pr-check.sh" task-a "$URL"); rc=$?
show "fm-pr-check.sh task-a $URL   [Jev times out]" "$out" "$rc"
expect "a Jev timeout still registers and arms" bash -c "[ $rc -eq 0 ] && [ -e '$H/state/task-a.pr-poll' ]"
out=$(register "$ROOT/bin/fm-pr-check.sh" task-a "$URL" --no-risk); rc=$?
show "fm-pr-check.sh task-a $URL --no-risk   [what fm-pr-merge.sh runs]" "$out" "$rc"
expect "the merge-time registration makes no request and prints no risk line" \
  bash -c "[ $rc -eq 0 ] && [ '$(requests)' = 0 ] && ! printf '%s' \"\$1\" | grep -q risk" _ "$out"

###########################################################################
say "C. failed check sort: real bin/fm-pr-state.sh over a fixture forge"
HEADSHA=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
cat > "$BIN/gh-forge" <<SH
#!/usr/bin/env bash
set -o pipefail
serve() {
  case "\$*" in
    "pr view "*" --json state,mergedAt,isDraft,headRefOid,author,mergeable,reviewDecision --jq "*)
      echo '{"state":"OPEN","mergedAt":null,"isDraft":false,"headRefOid":"$HEADSHA","author":{"login":"a","is_bot":false},"mergeable":"MERGEABLE","reviewDecision":"APPROVED"}' ;;
    "api /repos/o/r/pulls/7/reviews"*) echo '[]' ;;
    "pr checks "*) echo '[{"name":"CI Status","state":"FAILURE","bucket":"fail","workflow":"ci"},{"name":"slow","state":"IN_PROGRESS","bucket":"pending","workflow":"ci"}]' ;;
    "api -X GET /repos/o/r/commits/$HEADSHA/check-runs "*)
      echo '{"check_runs":[{"id":41,"status":"completed","conclusion":"failure","details_url":"https://github.com/o/r/actions/runs/5/job/41","app":{"slug":"github-actions"}}]}' ;;
    "api -X GET /repos/o/r/actions/runs/5/jobs "*) echo '{"jobs":[]}' ;;
    "run view --job 41 --log-failed -R o/r")
      printf 'build\tpush\t2026-10-06T10:00:00.0000000Z error: push failed with GH_TOKEN=%s\nbuild\ttest\t2026-10-06T10:00:01.0000000Z assert failed in the parser\n' "$GHP" ;;
    "pr view "*" --json baseRefName --jq .baseRefName") echo '{"baseRefName":"main"}' ;;
    "api -X GET /repos/o/r/commits/main/check-runs "*) echo '{"check_runs":[]}' ;;
    *) echo "unexpected gh call: \$*" >&2; exit 91 ;;
  esac
}
prog=; prev=
for arg in "\$@"; do [ "\$prev" != --jq ] || prog=\$arg; prev=\$arg; done
if [ -n "\$prog" ]; then serve "\$@" | jq -r "\$prog"; else serve "\$@"; fi
SH
chmod +x "$BIN/gh-forge"
state() {  # [env...] -- args
  reset_log
  env DRIVE_GH="$BIN/gh-forge" DRIVE_CHOICE=code_bug "$@" 2>"$T/err"
}
PRURL=https://github.com/o/r/pull/7
printf 'o/r\n' > "$H/config/jev-code-projects"
plain=$(state "$ROOT/bin/fm-pr-state.sh" "$PRURL"); rc=$?
show "fm-pr-state.sh $PRURL   [o/r listed, key present, option NOT given]" "$plain" "$rc"
expect "without --sort-failed-checks nothing is sent and no label is printed" \
  bash -c "[ '$(requests)' = 0 ] && ! printf '%s' \"\$1\" | grep -q 'FAILED CHECK SORT'" _ "$plain"
expect "without the option no check-run or job-log read is made" bash -c "! grep -Eq 'check-runs|run view' '$LOG/gh-calls'"

out=$(state "$ROOT/bin/fm-pr-state.sh" --sort-failed-checks "$PRURL"); rc=$?
show "fm-pr-state.sh --sort-failed-checks $PRURL   [o/r listed]" "$out" "$rc"
printf 'state sent to Jev:\n'; jq .state "$LOG/body" 2>/dev/null
expect "the failed check gains one label and the blocker lines are unchanged" \
  eq "$out" "$(printf '%s\nFAILED CHECK SORT: CI Status: code bug (jev, confidence 0.9)' "$plain")"
expect "the token in the job log is not in the request" body_lacks "$GHP"
expect "the failure line beside it is sent" body_has 'assert failed in the parser'

for entry in r x/r O/R 'o/r-web' '# o/r'; do
  printf '%s\n' "$entry" > "$H/config/jev-code-projects"
  out=$(state "$ROOT/bin/fm-pr-state.sh" --sort-failed-checks "$PRURL"); rc=$?
  printf '$ list entry [%s] -> %s (requests=%s)\n' "$entry" "$(printf '%s' "$out" | grep 'FAILED CHECK SORT')" "$(requests)"
  expect "list entry '$entry' does not allow o/r: unknown, nothing sent" \
    bash -c "[ '$(requests)' = 0 ] && printf '%s' \"\$1\" | grep -qx 'FAILED CHECK SORT: CI Status: unknown'" _ "$out"
done
printf 'o/r\n' > "$H/config/jev-code-projects"
out=$(state DRIVE_CURL_FAIL=7 "$ROOT/bin/fm-pr-state.sh" --sort-failed-checks "$PRURL"); rc=$?
show "fm-pr-state.sh --sort-failed-checks $PRURL   [Jev unreachable]" "$out" "$rc"
expect "with Jev down the report is intact, exit 0, label unknown" \
  eq "$rc:$out" "0:$(printf '%s\nFAILED CHECK SORT: CI Status: unknown' "$plain")"
mv "$H/.env" "$H/.env.off"
out=$(state "$ROOT/bin/fm-pr-state.sh" --sort-failed-checks "$PRURL"); rc=$?
mv "$H/.env.off" "$H/.env"
expect "without a key the option prints exactly the plain report" eq "$out" "$plain"

###########################################################################
say "D. the one caller: adversarial inputs to the credential filter"
ask() {  # <state-json> -> the state as sent
  reset_log
  printf '%s' "$1" > "$T/state.json"
  ( . "$ROOT/bin/fm-jev-lib.sh"; fm_jev_key_load "$H" && fm_jev_choice q 'pick' "$T/state.json" <(printf '{"yes":"y","no":"n"}') ) >/dev/null 2>&1
  jq -c .state "$LOG/body" 2>/dev/null
}
BODY1=MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7
BODY2=VJTUt9Us8cKjMzEfYyjiWA4R4ypbHjGmqkQH3uRwPz1JhG0VbXw9
tail_only=$(jq -cn --arg b1 "$BODY1" --arg b2 "$BODY2" '{block: "\($b1)\n\($b2)\n-----END RSA PRIVATE KEY-----\nplain line after"}')
sent=$(ask "$tail_only"); printf 'key tail with no BEGIN line   -> sent: %s\n' "$sent"
expect "a key tail cut off from its BEGIN line sends no body line and no END marker" \
  bash -c "! grep -qF '$BODY1' '$LOG/body' && ! grep -qF '$BODY2' '$LOG/body' && ! grep -q 'END RSA' '$LOG/body'"
expect "the ordinary line after the block is still sent" body_has 'plain line after'
whole=$(jq -cn --arg b1 "$BODY1" '{a: {deep: ["before\n-----BEGIN OPENSSH PRIVATE KEY-----\n\($b1)\n-----END OPENSSH PRIVATE KEY-----\nafter"]}}')
sent=$(ask "$whole"); printf 'whole block, nested in the state -> sent: %s\n' "$sent"
expect "a whole private key block nested deep in the state is replaced by one placeholder" \
  eq "$sent" '{"a":{"deep":["before\n[line withheld: looks like a credential]\nafter"]}}'
open=$(jq -cn --arg b1 "$BODY1" '{t: "x\n-----BEGIN PRIVATE KEY-----\n\($b1)\nstill key"}')
sent=$(ask "$open"); printf 'block with no END line          -> sent: %s\n' "$sent"
expect "a block with no END line is withheld to the end of the string" eq "$sent" '{"t":"x\n[line withheld: looks like a credential]"}'
mixed=$(jq -cn --arg g "$GHP" --arg a "$AWS" '{lines: ["ok line", "export GH=\($g)", "id \($a) here", "password = \"hunter2hunter2\"", "xoxb-1234567890-abcdefghij", "the token type is bearer"]}')
sent=$(ask "$mixed"); printf 'one string per credential kind  -> sent: %s\n' "$sent"
expect "GitHub, AWS, Slack and quoted-password lines are each withheld; ordinary lines pass" \
  eq "$sent" '{"lines":["ok line","[line withheld: looks like a credential]","[line withheld: looks like a credential]","[line withheld: looks like a credential]","[line withheld: looks like a credential]","the token type is bearer"]}'

###########################################################################
say "E. house-rules check: an embedded private key spanning two 80-line blocks"
HR="$T/hr"; fm_git_init_commit "$HR"; git -C "$HR" checkout -q -b task
mkdir -p "$HR/src"
{
  for i in $(seq 1 59); do printf 'value_%s = %s\n' "$i" "$i"; done
  printf 'KEY = """-----BEGIN RSA PRIVATE KEY-----\n'
  for i in $(seq 1 49); do printf 'KEYBODYLINE%sMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEA\n' "$i"; done
  printf -- '-----END RSA PRIVATE KEY-----"""\n'
  for i in $(seq 1 10); do printf 'after_%s = %s\n' "$i" "$i"; done
} > "$HR/src/fixtures.py"
git -C "$HR" add -A; git -C "$HR" commit -qm 'fixtures'
printf 'hr\n' > "$H/config/jev-code-projects"
reset_log
out=$(cd "$HR" && "$ROOT/bin/fm-house-rules-check.sh" hr 2>&1); rc=$?
printf '$ fm-house-rules-check.sh hr   -> rc=%s requests=%s\n%s\n' "$rc" "$(requests)" "$out"
printf 'key lines in any request body: %s\n' "$(cat "$LOG"/body.* 2>/dev/null | grep -c 'KEYBODYLINE\|PRIVATE KEY')"
expect "the change was actually sent in more than one block" bash -c "[ '$(requests)' -ge 2 ]"
expect "ordinary lines of both blocks are sent" bash -c "grep -q 'value_1 = 1' '$LOG'/body.* && grep -q 'after_10 = 10' '$LOG'/body.*"
expect "no key body line, BEGIN line or END line is in any request" bash -c "! cat '$LOG'/body.* | grep -q 'KEYBODYLINE\|PRIVATE KEY'"
expect "the check exits 0 whatever Jev says" eq "$rc" 0

printf '\n%s check(s) failed\n' "$FAILS"
exit "$FAILS"
