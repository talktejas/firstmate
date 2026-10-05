#!/usr/bin/env bash
# tests/fm-commit-check.test.sh - the worker commit check (bin/fm-commit-check.sh),
# off unless TYPESAFE_API_KEY is present.
#
# Two layers, neither of which touches the network:
#   - the decision, with the script sourced and fm_jev_choices stubbed at the
#     library boundary, so every gate is asserted by which questions were asked
#     at all, what was sent, and what the committer is told;
#   - real `git commit` runs through the hooks --install writes, with the real
#     library and a fake curl, proving the hooks fire only through the exported
#     setting, the project's own hooks still run, only a credential stops a
#     commit, and the key reaches no child environment or argv.
# Every case runs against a fixture home, so no real key can load.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-commit-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-commit-check)
KEY='test-key-5e2a-never-on-argv'
HOME_ON="$TMP_ROOT/home"
HOME_OFF="$TMP_ROOT/home-off"
WT="$TMP_ROOT/wt"
ASKED="$TMP_ROOT/asked"
SENT="$TMP_ROOT/sent"
ERR="$TMP_ROOT/err"
MSG="$TMP_ROOT/msg"

unset GIT_CONFIG_PARAMETERS
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p "$HOME_ON/config" "$HOME_OFF"
printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$HOME_ON/.env"
printf '# projects whose commits may be sent\nlisted\n' > "$HOME_ON/config/jev-code-projects"
git init -q "$WT"
git -C "$WT" commit -q --allow-empty -m base

# stage <path> <content>...: reset the index and worktree, then stage each pair.
stage() {
  git -C "$WT" reset -q --hard
  git -C "$WT" clean -qfd
  while [ $# -gt 0 ]; do
    mkdir -p "$WT/$(dirname "$1")"
    printf '%b' "$2" > "$WT/$1"
    git -C "$WT" add -- "$1"
    shift 2
  done
}

# check <home> <project> <message>: source the script, stub the library
# boundary, run the check inside the worktree. STUB_YES lists the questions
# answered yes; STUB_CONF is every answer's confidence; STUB_MODE=error makes
# the call fail. Advice lands in $ERR.
check() {
  printf '%s\n' "$3" > "$MSG"
  : > "$ASKED"
  : > "$SENT"
  (
    cd "$WT" || exit 99
    # shellcheck source=bin/fm-commit-check.sh
    . "$CHECK"
    fm_jev_choices() {
      jq -r 'keys_unsorted | join(" ")' "$1" > "$ASKED"
      cat "$2" > "$SENT"
      if [ "${STUB_MODE:-ok}" = error ]; then
        # shellcheck disable=SC2034 # read by the sourced script
        FM_JEV_STATUS=error
        return 1
      fi
      # shellcheck disable=SC2034
      FM_JEV_ANSWERS=$(jq -cn --arg asked "$(cat "$ASKED")" --arg yes " ${STUB_YES:-} " --argjson c "${STUB_CONF:-0.9}" '
        {answers: ($asked | split(" ") | map(. as $k | {key: $k, value: (
          if ($yes | contains(" \($k) ")) then {choice: "yes", confidence: $c, probabilities: {yes: $c, no: (1 - $c)}}
          else {choice: "no", confidence: $c, probabilities: {yes: (1 - $c), no: $c}} end)}) | from_entries)}')
      # shellcheck disable=SC2034
      FM_JEV_STATUS=ok
      return 0
    }
    fm_commit_check "$1" "$2" "$MSG"
  ) 2> "$ERR"
}

asked() { tr -d '\n' < "$ASKED"; }

# --- layer 1: the decision ---------------------------------------------------

stage src/a.py 'x = 1\n' src/b.py 'y = 2\n'
STUB_YES='filler contradicts leftovers unmentioned' check "$HOME_OFF" listed 'Add the two counters'
expect_code 0 $? "no key must let the commit through"
assert_equals '' "$(asked)$(cat "$ERR")" "no key must ask and say nothing"
pass "absent key: nothing asked, nothing said"

STUB_YES='filler contradicts leftovers unmentioned' check "$HOME_ON" unlisted 'Add the two counters'
expect_code 0 $? "an unlisted project must let the commit through"
assert_equals '' "$(asked)$(cat "$ERR")" "the key alone must send nothing about an unlisted project"
pass "key without the project opt-in: nothing sent"

STUB_YES='leftovers unmentioned' check "$HOME_ON" listed 'Add the two counters'
expect_code 0 $? "advice must let the commit through"
assert_equals 'filler contradicts leftovers unmentioned' "$(asked)" "one request carries all four questions"
assert_grep 'advisory, the commit goes through: the staged change appears to carry debug leftovers' "$ERR" "a yes must be said"
assert_grep 'a staged file is not accounted for by the message' "$ERR" "each yes gets its own line"
assert_no_grep 'contradict' "$ERR" "a no must stay silent"
assert_equals 'Add the two counters' "$(jq -r .commit.message "$SENT")" "the message is sent"
assert_equals 'src/a.py src/b.py' "$(jq -r '.commit.files | join(" ")' "$SENT")" "the file names are sent"
assert_contains "$(jq -r .commit.diff "$SENT")" '+x = 1' "the staged diff is sent"
pass "listed project: four questions in one request, a line per yes"

STUB_YES='contradicts leftovers' STUB_CONF=0.55 check "$HOME_ON" listed 'Add the two counters'
assert_equals '' "$(cat "$ERR")" "a yes below the floor must stay silent"
STUB_YES='contradicts' STUB_MODE=error check "$HOME_ON" listed 'Add the two counters'
expect_code 0 $? "a failed call must let the commit through"
assert_equals '' "$(cat "$ERR")" "a failed call must say nothing"
pass "low confidence and a failed call: silent, commit goes through"

stage src/a.py 'x = 1\n'
check "$HOME_ON" listed 'Add the counter'
assert_equals 'filler contradicts leftovers' "$(asked)" "one staged file leaves nothing to be unmentioned"
stage README.md 'hello\n' docs/x.md 'more\n'
check "$HOME_ON" listed 'Describe the setup'
assert_equals 'filler contradicts unmentioned' "$(asked)" "a prose-only change has no added code to hold leftovers"
assert_equals '' "$(jq -r .commit.diff "$SENT")" "prose is left out of the diff"
pass "code facts decide which questions are asked"

stage src/a.py 'x = 1\n' src/b.py 'y = 2\n'
STUB_YES=filler check "$HOME_ON" listed 'WIP.'
assert_equals 'contradicts leftovers unmentioned' "$(asked)" "code settles a filler word without asking"
assert_grep 'the message "WIP." does not say what changed or why' "$ERR" "code-decided filler is said"
check "$HOME_ON" unlisted 'update'
assert_grep 'does not say what changed' "$ERR" "code-decided filler needs no project opt-in"
assert_equals '' "$(asked)" "and still sends nothing"
pass "filler by code: warned unasked, on any project"

stage src/a.py 'x = 1\n' .env.local 'VALUE=1\n' package-lock.json '{}\n'
check "$HOME_ON" listed 'Add the counter and its settings'
assert_contains "$(jq -r .commit.diff "$SENT")" 'src/a.py' "code is sent"
assert_not_contains "$(jq -r .commit.diff "$SENT")" 'VALUE=1' "a secret-shaped file's text is never sent"
assert_not_contains "$(jq -r .commit.diff "$SENT")" 'package-lock' "a lockfile's text is never sent"
pass "secret-shaped and generated paths: named, never quoted"

long=$(printf 'line %04d\\n' $(seq 1 4000))
stage src/big.py "$long"
check "$HOME_ON" listed "Add the table $(printf 'x%.0s' $(seq 1 5000)) THE-END"
assert_equals true "$(jq -r .commit.diff_truncated "$SENT")" "a long diff is flagged as cut"
assert_equals 24000 "$(jq -r '.commit.diff | length' "$SENT")" "a long diff is cut to its bound"
assert_contains "$(jq -r .commit.diff "$SENT")" 'line 4000' "a long diff keeps its end"
assert_equals 4000 "$(jq -r '.commit.message | length' "$SENT")" "a long message is cut to its bound"
assert_contains "$(jq -r .commit.message "$SENT")" 'THE-END' "a long message keeps its end"
pass "long text keeps its end"

stage src/a.py 'x = 1\n'
check "$HOME_ON" listed 'fixup! Add the counter'
assert_equals '' "$(asked)$(cat "$ERR")" "a fixup marker is not judged"
: > "$WT/.git/MERGE_HEAD"
check "$HOME_ON" listed 'Merge the branch'
assert_equals '' "$(asked)$(cat "$ERR")" "a merge is not judged"
rm -f "$WT/.git/MERGE_HEAD"
stage
check "$HOME_ON" listed 'Reword only'
assert_equals '' "$(asked)$(cat "$ERR")" "nothing staged is not judged"
pass "markers, merges and empty changes: skipped"

# Built from pieces so this file never holds a line the check itself would stop.
ghtoken="ghp_$(printf 'a%.0s' $(seq 1 36))"
stage src/a.py 'x = 1\n' src/conf.py "TOKEN = \"$ghtoken\"\\npass" src/db.py 'db_password = "hunter2-hunter2"\n'
STUB_YES='' check "$HOME_ON" unlisted 'Add the client'
expect_code 1 $? "a credential must stop the commit"
assert_grep 'src/conf.py:1: GitHub token' "$ERR" "the stop names file, line and kind"
assert_grep 'src/db.py:1: password or secret literal' "$ERR" "a quoted password literal is caught"
assert_no_grep "$ghtoken" "$ERR" "the value itself is never printed"
assert_grep 'no-verify' "$ERR" "the way past a fixture is named"
assert_equals '' "$(asked)" "Jev has no part in the stop"
# shellcheck disable=SC2016 # A literal placeholder, as a source file would hold it.
stage src/conf.py 'token = os.environ["API_TOKEN"]\npassword = "${DB_PASSWORD}"\n'
check "$HOME_ON" unlisted 'Read the token from the environment'
expect_code 0 $? "a lookup or a placeholder is not a credential"
stage src/conf.py "TOKEN = \"$ghtoken\"\\n"
check "$HOME_OFF" unlisted 'Add the client'
expect_code 0 $? "without a key even a credential goes through, as today"
pass "credentials: stopped by pattern alone, only with a key"

# --- layer 2: real commits through the installed hooks, fake curl -------------

FAKEBIN="$TMP_ROOT/fakebin"
HOOKS="$TMP_ROOT/task tmp/git-hooks"
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
jq -c '{model: "jev-test", answers: (.questions | map_values({choice: "yes", confidence: 0.9, probabilities: {yes: 0.9, no: 0.1}}))}' > "$out"
printf 200
SH
chmod +x "$FAKEBIN/curl"
export FAKE_CURL_LOG="$TMP_ROOT/curl.log"
: > "$FAKE_CURL_LOG"

out=$("$CHECK" --install "$TMP_ROOT/none" "$HOME_OFF" listed)
expect_code 1 $? "install without a key must report off"
assert_equals '' "$out" "install without a key prints no setting"
assert_absent "$TMP_ROOT/none" "install without a key writes nothing"
PARAMS=$(TYPESAFE_API_KEY=$KEY "$CHECK" --install "$HOOKS" "$HOME_OFF" listed)
expect_code 0 $? "an environment key turns install on"
PARAMS=$("$CHECK" --install "$HOOKS" "$HOME_ON" listed) || fail "install with a key must succeed"
assert_equals "'core.hooksPath=$HOOKS'" "$PARAMS" "install prints the one git setting"
pass "install: off without a key, one setting with one"

commit() {  # <message> [git commit args...]
  local message=$1
  shift
  PATH="$FAKEBIN:$PATH" GIT_CONFIG_PARAMETERS=$PARAMS git -C "$WT" commit -q "$@" -m "$message" 2> "$ERR"
}

stage src/a.py 'x = 1\n' src/b.py 'y = 2\n'
git -C "$WT" commit -q -m 'wip' 2> "$ERR" || fail "a commit without the setting must succeed"
assert_equals '' "$(cat "$ERR")" "without the exported setting the hooks do not exist"
assert_equals '' "$(cat "$FAKE_CURL_LOG")" "and nothing is sent"
pass "a git without the exported setting is untouched"

stage src/c.py 'z = 3\n' src/d.py 'w = 4\n'
commit 'Add two more counters' || fail "advice must not stop a real commit"
assert_equals 'Add two more counters' "$(git -C "$WT" log -1 --format=%s)" "the commit was made"
assert_equals 4 "$(grep -c 'advisory, the commit goes through' "$ERR")" "every yes is shown to the committer"
assert_grep 'argv:https://api.typesafe.ai/v1/systemone' "$FAKE_CURL_LOG" "one request went out"
assert_equals 1 "$(grep -c 'argv:-X' "$FAKE_CURL_LOG")" "exactly one request per commit"
assert_no_grep "$KEY" "$FAKE_CURL_LOG" "the key must not reach curl's argv"
assert_no_grep secret-present "$FAKE_CURL_LOG" "the key must not reach curl's environment"
pass "real commit: one request, four advisory lines, commit made, key in no child"

stage src/conf.py "TOKEN = \"$ghtoken\"\\n"
if commit 'Add the client token'; then fail "a credential must stop a real commit"; fi
assert_grep 'src/conf.py:1: GitHub token' "$ERR" "the stop is shown to the committer"
assert_equals 'Add two more counters' "$(git -C "$WT" log -1 --format=%s)" "no commit was made"
commit 'Add the client token fixture' --no-verify || fail "--no-verify must be the way past"
pass "real commit: a credential stops it, --no-verify passes it"

# The project's own hooks keep running, and its own refusal stands.
mkdir -p "$WT/.git/hooks"
printf '#!/bin/sh\necho own-pre-commit >> "%s"\n' "$TMP_ROOT/own.log" > "$WT/.git/hooks/pre-commit"
# shellcheck disable=SC2016 # Expanded by the generated hook.
printf '#!/bin/sh\necho "own-commit-msg $(cat "$1")" >> "%s"\n' "$TMP_ROOT/own.log" > "$WT/.git/hooks/commit-msg"
chmod +x "$WT/.git/hooks/pre-commit" "$WT/.git/hooks/commit-msg"
stage src/e.py 'v = 5\n'
commit 'Add the fifth counter' || fail "a commit with passing project hooks must succeed"
assert_grep own-pre-commit "$TMP_ROOT/own.log" "the project's pre-commit hook still runs"
assert_grep 'own-commit-msg Add the fifth counter' "$TMP_ROOT/own.log" "the project's commit-msg hook still runs"
printf '#!/bin/sh\nexit 7\n' > "$WT/.git/hooks/commit-msg"
: > "$FAKE_CURL_LOG"
stage src/f.py 'u = 6\n'
if commit 'Add the sixth counter'; then fail "the project's own commit-msg refusal must stand"; fi
assert_equals '' "$(cat "$FAKE_CURL_LOG")" "a commit the project refused is not sent"
pass "the project's own hooks still run and still decide"

# --- layer 3: what bin/fm-spawn.sh sends the worker's pane ---------------------

# spawn_lines <name> <home-with-or-without-key>: launch a ship worker on a fake
# tmux and print every line the pane was sent.
spawn_lines() {
  local name=$1 keyhome=$2 dir="$TMP_ROOT/spawn-$1" fakebin id="cc$$-$1"
  fakebin=$(fm_fakebin "$dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;; esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  send-keys)
    shift
    skip=
    for a in "$@"; do
      if [ -n "$skip" ]; then skip=; continue; fi
      case "$a" in
        -t) skip=1 ;;
        -l | Enter | C-m) ;;
        *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
      esac
    done
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_test_fake_treehouse_lease "$fakebin"
  mkdir -p "$dir/home/data/$id" "$dir/home/projects" "$dir/home/state" "$dir/home/config" "$dir/home/user-home"
  [ ! -f "$keyhome/.env" ] || cp "$keyhome/.env" "$dir/home/.env"
  printf 'claude\n' > "$dir/home/config/crew-harness"
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  touch "$dir/home/state/.last-watcher-beat"
  fm_git_worktree "$dir/listed" "$dir/wt" "wt-$name"
  printf '# Task\n## Captain'"'"'s intent\nExercise the commit check.\n\n## Firstmate spec\nNothing more.\n' \
    > "$dir/home/data/$id/brief.md"
  : > "$dir/launch.log"
  env -u TYPESAFE_API_KEY -u GIT_CONFIG_PARAMETERS \
    FM_ROOT_OVERRIDE='' FM_HOME="$dir/home" HOME="$dir/home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_PROJECTS_OVERRIDE="$dir/home/projects" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$dir/wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$dir/launch.log" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$dir/listed" --mode no-mistakes --yolo off > "$dir/out" 2>&1 \
    || fail "spawn $name failed: $(cat "$dir/out")"
  rm -rf "/tmp/fm-$id/gotmp"
  cat "$dir/launch.log"
}

lines=$(spawn_lines off "$HOME_OFF")
assert_contains "$lines" 'export FM_TASK_ID=' "the keyless spawn still launches"
assert_not_contains "$lines" GIT_CONFIG_PARAMETERS "without a key the pane is sent no git setting"
assert_absent "/tmp/fm-cc$$-off/git-hooks" "without a key no hooks are written"
lines=$(spawn_lines on "$HOME_ON")
export_line=$(printf '%s\n' "$lines" | grep '^export GIT_CONFIG_PARAMETERS=') \
  || fail "with a key the pane must be sent the git setting: $lines"
# Run the sent line as the pane's shell would, then commit as the worker would.
rm -f "$WT/.git/hooks/pre-commit" "$WT/.git/hooks/commit-msg"
stage src/g.py 't = 7\n'
(
  eval "$export_line"
  PATH="$FAKEBIN:$PATH" git -C "$WT" commit -q -m 'update' 2> "$ERR"
) || fail "a commit under the spawned setting must succeed"
assert_grep 'the message "update" does not say what changed or why' "$ERR" "the spawned hook checks the worker's commit"
rm -rf "/tmp/fm-cc$$-off" "/tmp/fm-cc$$-on"
pass "spawn: the pane gets the git setting only with a key, and it works as sent"

echo "all fm-commit-check tests passed"
