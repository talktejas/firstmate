#!/usr/bin/env bash
# tests/fm-pr-risk.test.sh - the advisory pull request risk level
# (bin/fm-pr-risk-lib.sh) that bin/fm-pr-check.sh prints, off unless
# TYPESAFE_API_KEY is present.
#
# Two layers, neither of which touches the network or a real key. Both read the
# change through the real bin/fm-review-diff.sh from a fixture project and task
# worktree:
#   - the rating, with the library sourced and fm_jev_choice stubbed at the
#     library boundary, so each fact, each question that code settles without
#     asking, the per-project opt-in, and each fallback is asserted by the
#     printed line and by how often the model was asked;
#   - the real bin/fm-pr-check.sh with the real Jev library and a fake curl,
#     proving the registration is unchanged with the key absent, that the line
#     is printed beside it with the key present, and that the key reaches curl
#     on a file descriptor and no child environment or argv.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-risk)
KEY='test-key-9c1d-never-on-argv'
URL='https://github.com/o/r/pull/8'
H="$TMP_ROOT/home"
BIN="$TMP_ROOT/bin"
PROJ="$TMP_ROOT/alpha"
WT="$TMP_ROOT/wt"
LISTED="$H/config/jev-code-projects"
mkdir -p "$BIN" "$H/state" "$H/config" "$H/log"

cat > "$BIN/gh.real" <<'SH'
#!/usr/bin/env bash
[ -n "${FAKE_PR_JSON:-}" ] || exit 1
printf '%s\n' "$FAKE_PR_JSON"
SH
cat > "$BIN/curl.real" <<'SH'
#!/usr/bin/env bash
set -u
log=${FAKE_LOG:?}
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "$log/argv"; shift ;;
  esac
done
cat > "$log/body"
cat /dev/fd/3 > "$log/header" 2>/dev/null
[ "${FAKE_CURL_FAIL:-0}" = 0 ] || exit "$FAKE_CURL_FAIL"
jq -c --arg choice "${FAKE_CHOICE:-no}" '(.questions | keys[0]) as $k | (if $choice == "yes" then "no" else "yes" end) as $other |
  {model: "jev-test", answers: {($k): {choice: $choice, confidence: 0.9, probabilities: {($choice): 0.95, ($other): 0.05}}}}' \
  "$log/body" > "$out"
printf 200
SH
ln -s "$(command -v git)" "$BIN/git.real"
# Every git, gh, and curl a run starts records that it ran and whether the key
# was in its environment.
for tool in git gh curl; do
  cat > "$BIN/$tool" <<SH
#!/usr/bin/env bash
if [ -n "\${TYPESAFE_API_KEY+x}" ] || [ -n "\${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf '$tool:secret-present\n' >> "$H/log/child-env"
else
  printf '$tool:clean\n' >> "$H/log/child-env"
fi
exec "$BIN/$tool.real" "\$@"
SH
done
chmod +x "$BIN"/*
export FM_HOME="$H" FM_GUARD_GRACE=999999 FAKE_LOG="$H/log" PATH="$BIN:$PATH"

fm_git_identity
fm_git_init_commit "$PROJ"
mkdir -p "$PROJ/src"
seq 1 4 > "$PROJ/src/old.js"
git -C "$PROJ" add src/old.js
git -C "$PROJ" commit -qm 'add old'
git -C "$PROJ" worktree add --quiet -b fm/task-a "$WT"
fm_write_meta "$H/state/task-a.meta" "window=fm-task-a" "kind=ship" "worktree=$WT" "project=$PROJ"

# Make the task branch hold exactly this change. <path>:<lines>|<path>:deleted ...
change() {
  local spec path n
  git -C "$WT" reset -q --hard main
  for spec; do
    path=${spec%:*} n=${spec##*:}
    if [ "$n" = deleted ]; then
      git -C "$WT" rm -q -- "$path"
    else
      mkdir -p "$WT/$(dirname "$path")"
      seq 1 "$n" > "$WT/$path"
      git -C "$WT" add -- "$path"
    fi
  done
  git -C "$WT" commit -qm change
}

# --- layer 1: the rating, Jev stubbed at the library boundary ---------------

# shellcheck source=bin/fm-pr-risk-lib.sh
. "$ROOT/bin/fm-pr-risk-lib.sh"

JEV_CALLS="$TMP_ROOT/jev-calls"
# JEV_STUB maps a question key to "<choice> <confidence>", "error", or "off";
# a key it does not name answers "no 0.95".
JEV_STUB=''
# shellcheck disable=SC2034,SC2329 # The library boundary: the sourced library reads these outputs.
fm_jev_choice() {  # <question-key> <instructions> <state-json-file> <criteria-json-file>
  local answer choice conf
  printf '%s\n' "$1" >> "$JEV_CALLS"
  cat "$3" > "$TMP_ROOT/jev-state.json"
  FM_JEV_STATUS='' FM_JEV_ERROR='' FM_JEV_LATENCY_MS=7 FM_JEV_ANSWER=''
  FM_JEV_CHOICE='' FM_JEV_CONFIDENCE='' FM_JEV_PROBABILITIES=''
  answer=$(printf '%s\n' "$JEV_STUB" | tr ',' '\n' | sed -n "s/^$1=//p")
  case "${answer:-no 0.95}" in
    off) FM_JEV_STATUS=off; return 1 ;;
    error) FM_JEV_STATUS=error; FM_JEV_ERROR='http 000 after 5001 ms: '; return 1 ;;
  esac
  read -r choice conf <<EOF
${answer:-no 0.95}
EOF
  FM_JEV_STATUS=ok FM_JEV_CHOICE=$choice FM_JEV_CONFIDENCE=$conf
  FM_JEV_ANSWER=$(jq -nc --arg choice "$choice" --argjson c "$conf" \
    '{choice: $choice, confidence: $c, probabilities: {($choice): $c}}')
  return 0
}

rate() {  # <jev-stub> -> the printed line
  JEV_STUB=$1
  : > "$JEV_CALLS"; : > "$H/log/child-env"
  TYPESAFE_API_KEY_PRIVATE=
  fm_pr_risk task-a github "$URL" github.com o/r 8 alpha
}
calls() { tr '\n' ' ' < "$JEV_CALLS" | sed 's/ $//'; }

export FAKE_PR_JSON='{"title":"Tidy the parser","body":"Splits one long function."}'
change src/parser.js:12
printf 'alpha\n' > "$LISTED"

out=$(rate ''); rc=$?
assert_equals "1|" "$rc|$out" "with the key absent nothing is printed"
assert_equals '' "$(cat "$H/log/child-env")" "with the key absent the change is not even read"
assert_equals '' "$(calls)" "with the key absent Jev is not asked"

printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$H/.env"
out=$(rate '')
assert_equals 'risk: low - no risk fact found and all three questions answered no' "$out" "no fact and three counted no answers is low"
assert_equals 'untested mismatch irreversible' "$(calls)" "the three judgements are separate questions"
assert_equals '12|1|Tidy the parser' \
  "$(jq -r '.change | "\(.facts.changed_lines)|\(.facts.code_files_changed)|\(.title)"' "$TMP_ROOT/jev-state.json")" \
  "the question carries the facts and the forge's title"
assert_not_contains "$out$(cat "$TMP_ROOT/jev-state.json")" "$KEY" "the key is in neither the line nor the question"

change src/parser.js:12 tests/parser.test.js:5
out=$(rate 'untested=yes 0.99')
assert_equals 'mismatch irreversible' "$(calls)" "a changed test file settles untested in code, unasked"
assert_contains "$out" 'risk: low' "a changed test file is not flagged untested"
change README.md:30
rate '' >/dev/null
assert_equals 'mismatch irreversible' "$(calls)" "a documentation-only change settles untested in code, unasked"

for case in 'db/migrations/0042_drop.sql|database migration' 'app/AuthController.php|login and permissions' \
  'src/billing/invoice.ts|payments'; do
  change "${case%%|*}:3"
  out=$(rate '')
  assert_contains "$out" "risk: high - ${case##*|}" "${case%%|*} is high by path"
done
change 'db/migrations/café.sql:3'
assert_contains "$(rate '')" 'risk: high - database migration' "a path git prints quoted is still classified"
assert_equals '1|3' "$(jq -r '.change.facts | "\(.files)|\(.changed_lines)"' "$TMP_ROOT/jev-state.json")" \
  "a path git prints quoted is counted as its own file"
change src/authors/list.js:3
assert_contains "$(rate '')" 'risk: low' "an authors path is not a login path"
change src/old.js:deleted
assert_contains "$(rate '')" 'risk: medium - 1 deleted file(s)' "a deleted file is medium"
change src/big.js:400
assert_contains "$(rate '')" 'risk: medium - size (400 lines in 1 files)' "400 changed lines is medium"
change src/big.js:1500
assert_contains "$(rate '')" 'risk: high - size (1500 lines in 1 files)' "1500 changed lines is high"
pass "facts: paths, deletions, and size set the level in code; no answer lowers it"

change src/parser.js:12
assert_contains "$(rate 'untested=yes 0.9')" 'risk: medium - behaviour changed with no test' "a counted untested yes raises to medium"
assert_contains "$(rate 'mismatch=yes 0.9')" 'risk: medium - description does not match the change' "a counted mismatch yes raises to medium"
assert_contains "$(rate 'irreversible=yes 0.9')" 'risk: high - something hard to undo' "a counted irreversible yes raises to high"
out=$(rate 'irreversible=yes 0.59')
assert_equals 'risk: not rated - no risk fact found; unanswered: irreversible (Jev unsure)' "$out" "a yes below the floor raises nothing and is not rated"
out=$(rate 'mismatch=no 0.4')
assert_contains "$out" 'risk: not rated' "a no below the floor never yields low"
out=$(rate 'untested=maybe 0.9')
assert_contains "$out" 'unanswered: untested (Jev unsure)' "a choice outside the fixed list is not counted"
out=$(rate 'untested=error')
assert_equals 'risk: not rated - no risk fact found; unanswered: untested (Jev error), mismatch (Jev error), irreversible (Jev error)' "$out" "Jev down is not rated"
assert_equals 'untested' "$(calls)" "after one failed call the rest are not attempted"
change db/migrations/0042_drop.sql:3
out=$(rate 'untested=error')
assert_contains "$out" 'risk: high - database migration; unanswered:' "Jev down never lowers a level the facts set"
change src/parser.js:12
out=$(FAKE_PR_JSON='' rate '')
assert_contains "$out" 'risk: not rated - no risk fact found; unanswered: mismatch (description unreadable)' "an unreadable description leaves mismatch unasked"
assert_equals 'untested irreversible' "$(calls)" "the other two questions are still asked"
mv "$H/state/task-a.meta" "$H/state/task-a.meta.off"
assert_equals 'risk: not rated - the change could not be read' "$(rate '')" "an unreadable change is not rated"
assert_equals '' "$(calls)" "an unreadable change asks nothing"
mv "$H/state/task-a.meta.off" "$H/state/task-a.meta"
pass "judgement: a counted yes only raises; unsure, down, or unreadable is not rated"

NOT_LISTED='untested (project not listed), mismatch (project not listed), irreversible (project not listed)'
rm -f "$LISTED"
out=$(rate 'irreversible=yes 0.99')
assert_equals "risk: not rated - no risk fact found; unanswered: $NOT_LISTED" "$out" "with no list file the project is not rated, never low"
assert_equals '' "$(calls)" "with no list file Jev is asked nothing"
assert_grep 'git:clean' "$H/log/child-env" "with no list file the change is still read locally"
assert_no_grep '^gh:' "$H/log/child-env" "with no list file the forge is not read for a description"
: > "$LISTED"
assert_contains "$(rate '')" "unanswered: $NOT_LISTED" "an empty list file lists no project"
printf '# alpha\nbeta\nalpha-two\n' > "$LISTED"
assert_contains "$(rate '')" "unanswered: $NOT_LISTED" "a commented-out or merely similar name does not list the project"
assert_equals '' "$(calls)" "an unlisted project asks nothing"
change db/migrations/0042_drop.sql:3 tests/drop.test.js:2
out=$(rate '')
assert_equals 'risk: high - database migration; unanswered: mismatch (project not listed), irreversible (project not listed)' "$out" \
  "an unlisted project keeps the level its facts set and names what stayed unanswered"
printf '# projects whose changes Jev may see\nbeta\n\nalpha\n' > "$LISTED"
assert_equals 'risk: high - database migration' "$(rate '')" "a project listed beside comment lines is rated in full"
assert_equals 'mismatch irreversible' "$(calls)" "a listed project is asked"
pass "opt-in: only a project listed in config/jev-code-projects is sent to Jev"

# --- layer 2: the real bin/fm-pr-check.sh, real library, fake curl ----------

change db/migrations/0042_drop.sql:3 src/parser.js:12

check() {  # [env assignments...] -> runs the real registration for a fresh task
  fm_write_meta "$H/state/task-a.meta" "window=fm-task-a" "kind=ship" "worktree=$WT" "project=$PROJ"
  rm -f "$H/log/"*
  env FM_STATE_OVERRIDE="$H/state" "$@" "$ROOT/bin/fm-pr-check.sh" task-a "$URL" 2>"$TMP_ROOT/err"
}

rm -f "$H/.env"
out=$(check) || fail "the registration failed with the key absent: $(cat "$TMP_ROOT/err")"
assert_equals 'armed: state/task-a.check.sh' "$out" "with the key absent the output is exactly the registration"
assert_absent "$H/log/body" "with the key absent no Jev call is made"

out=$(check TYPESAFE_API_KEY="$KEY") || fail "the registration failed with the key present: $(cat "$TMP_ROOT/err")"
assert_equals "armed: state/task-a.check.sh
risk: high - database migration" "$out" "with the key present the level is printed beside the registration"
assert_equals "pr=$URL" "$(grep '^pr=' "$H/state/task-a.meta")" "the pull request is recorded as before"
assert_present "$H/state/task-a.pr-poll" "the merge poll is armed as before"
assert_equals "Authorization: Bearer $KEY" "$(cat "$H/log/header")" "the key reaches curl on the fd header"
assert_not_contains "$(cat "$H/log/argv")" "$KEY" "the key never appears on curl argv"
assert_no_grep 'secret-present' "$H/log/child-env" "the key is in no child's environment"
assert_grep 'curl:clean' "$H/log/child-env" "the child environments were actually observed"
assert_not_contains "$(cat "$TMP_ROOT/err")$(cat "$H/state/task-a.meta")" "$KEY" "the key is in neither stderr nor the task record"

printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$H/.env"
out=$(check FAKE_CHOICE=yes) || fail "the registration failed with the key in .env"
assert_contains "$out" 'risk: high - database migration, behaviour changed with no test, description does not match the change, something hard to undo' \
  "the key is read from the home's .env and every counted yes is named"
change src/parser.js:12
out=$(check FAKE_CURL_FAIL=28) || fail "a Jev timeout failed the registration"
assert_equals "armed: state/task-a.check.sh
risk: not rated - no risk fact found; unanswered: untested (Jev error), mismatch (Jev error), irreversible (Jev error)" "$out" \
  "a Jev timeout still registers and prints not rated"
assert_present "$H/state/task-a.pr-poll" "a Jev timeout leaves the merge poll armed"

rm -f "$LISTED"
out=$(check FAKE_CHOICE=yes) || fail "the registration failed for an unlisted project: $(cat "$TMP_ROOT/err")"
assert_equals "armed: state/task-a.check.sh
risk: not rated - no risk fact found; unanswered: $NOT_LISTED" "$out" "an unlisted project still registers and is not rated"
assert_absent "$H/log/body" "the key alone sends nothing about an unlisted project"
pass "fm-pr-check: unchanged without the key; one advisory line with it; the key stays off argv and child environments"

printf '# all fm-pr-risk tests passed\n'
