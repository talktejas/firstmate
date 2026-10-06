#!/usr/bin/env bash
# tests/fm-helper-model.test.sh - the helper model pick (bin/fm-helper-model.sh),
# off unless TYPESAFE_API_KEY is present and the project is listed.
#
# Two layers, neither of which touches the network:
#   - the decision, with the script sourced and fm_jev_choice stubbed at the
#     library boundary, so every gate is asserted by whether a question was
#     asked at all, what was sent, what the hook prints, and what is recorded;
#   - bin/fm-spawn.sh on a fake tmux, proving the worker's settings file gains
#     the hook only with a key, a listed project, and a named strong worker model,
#     and that the command it holds works as written, with the real library
#     and a fake curl.
# Every case runs against a fixture home, so no real key can load.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PICK="$ROOT/bin/fm-helper-model.sh"
TMP_ROOT=$(fm_test_tmproot fm-helper-model)
KEY='test-key-7c1d-never-on-argv'
HOME_ON="$TMP_ROOT/home"
HOME_OFF="$TMP_ROOT/home-off"
HOME_KEY="$TMP_ROOT/home-key"
STATE="$TMP_ROOT/state"
LOG="$STATE/.helper-model.log"
SENT="$TMP_ROOT/sent"
OUT="$TMP_ROOT/out"
mkdir -p "$HOME_ON/config" "$HOME_OFF" "$HOME_KEY" "$STATE"
printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$HOME_ON/.env"
printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$HOME_KEY/.env"
printf '# projects whose hand-offs may be sent\nlisted\n' > "$HOME_ON/config/jev-code-projects"

# handoff <tool_input-json>: the hook input Claude Code sends for one hand-off.
handoff() { jq -cn --argjson input "$1" '{hook_event_name: "PreToolUse", tool_name: "Agent", tool_input: $input}'; }

# hook <home> <project> <tool_input-json>: source the script, stub the library
# boundary, run the hook. STUB_CHOICE and STUB_CONF are the answer;
# STUB_MODE=error makes the call fail. The hook's stdout lands in $OUT.
hook() {
  : > "$SENT"
  handoff "$3" | (
    # shellcheck source=bin/fm-helper-model.sh
    . "$PICK"
    fm_jev_choice() {
      cat "$3" > "$SENT"
      # shellcheck disable=SC2034 # read by the sourced script
      FM_JEV_ANSWER='' FM_JEV_CHOICE='' FM_JEV_CONFIDENCE='' FM_JEV_LATENCY_MS=null
      [ "${STUB_MODE:-ok}" != error ] || return 1
      FM_JEV_CHOICE=${STUB_CHOICE:-mechanical}
      FM_JEV_CONFIDENCE=${STUB_CONF:-0.9}
      # shellcheck disable=SC2034
      FM_JEV_LATENCY_MS=7
      # shellcheck disable=SC2034
      FM_JEV_ANSWER=$(jq -cn --arg c "$FM_JEV_CHOICE" --argjson p "$FM_JEV_CONFIDENCE" '
        {choice: $c, confidence: $p, probabilities: (if $c == "mechanical" then {mechanical: $p, judgement: (1 - $p)} else {mechanical: (1 - $p), judgement: $p} end)}')
      return 0
    }
    fm_helper_model_hook "$1" "$STATE" task1 "$2"
  ) > "$OUT"
}

GREP='{"description":"Find callers","prompt":"List every caller of parse_rate.","subagent_type":"general-purpose","run_in_background":false}'

# --- layer 1: the decision ---------------------------------------------------

hook "$HOME_OFF" listed "$GREP"
expect_code 0 $? "no key must let the hand-off through"
assert_equals '' "$(cat "$SENT" "$OUT")" "no key must ask and print nothing"
hook "$HOME_ON" unlisted "$GREP"
assert_equals '' "$(cat "$SENT" "$OUT")" "the key alone must send nothing about an unlisted project"
assert_absent "$LOG" "nothing is recorded when nothing is asked"
pass "absent key or unlisted project: nothing asked, printed, or recorded"

hook "$HOME_ON" listed "$GREP"
expect_code 0 $? "the hook always exits 0"
assert_equals 'description prompt type' "$(jq -r '.helper | keys | join(" ")' "$SENT")" "only the hand-off is sent"
assert_equals 'sonnet' "$(jq -r .hookSpecificOutput.updatedInput.model "$OUT")" "a confident mechanical lowers the model"
assert_equals "$(jq -cS . <<<"$GREP")" "$(jq -cS '.hookSpecificOutput.updatedInput | del(.model)' "$OUT")" \
  "nothing else in the tool input changes"
assert_equals 'PreToolUse' "$(jq -r .hookSpecificOutput.hookEventName "$OUT")" "the answer names its event"
assert_equals 'false' "$(jq -r '.hookSpecificOutput | has("permissionDecision")' "$OUT")" \
  "the hook never names a permission decision"
assert_equals 'task1 cheaper mechanical 0.9 Find callers' \
  "$(tail -n 1 "$LOG" | jq -r '[.task, .outcome, .choice, .confidence, .description] | join(" ")')" "the pick is recorded"
assert_no_grep parse_rate "$LOG" "the prompt is never written to the record"
pass "confident mechanical: model lowered, input otherwise intact, recorded"

STUB_CHOICE=judgement hook "$HOME_ON" listed "$GREP"
assert_equals '' "$(cat "$OUT")" "judgement keeps the model the worker asked for"
assert_equals 'kept' "$(tail -n 1 "$LOG" | jq -r .outcome)" "a kept hand-off is recorded"
STUB_CONF=0.55 hook "$HOME_ON" listed "$GREP"
assert_equals '' "$(cat "$OUT")" "a mechanical below the floor keeps the model"
STUB_MODE=error hook "$HOME_ON" listed "$GREP"
expect_code 0 $? "a failed call must let the hand-off through"
assert_equals '' "$(cat "$OUT")" "a failed call keeps the model"
assert_equals 'error' "$(tail -n 1 "$LOG" | jq -r .outcome)" "a failed call is recorded"
pass "judgement, low confidence, and a failed call: the helper keeps its model"

for input in \
  '{"description":"d","prompt":"p","subagent_type":"general-purpose","model":"opus"}' \
  '{"description":"d","prompt":"p","subagent_type":"general-purpose","model":"haiku"}' \
  '{"description":"d","prompt":"p","subagent_type":"Explore"}' \
  '{"description":"d","prompt":"p","subagent_type":"fork"}' \
  '{"description":"d","prompt":"p","subagent_type":"my-custom-agent"}'; do
  hook "$HOME_ON" listed "$input"
  assert_equals '' "$(cat "$SENT" "$OUT")" "code decides without asking: $input"
done
hook "$HOME_ON" listed '{"description":"d","prompt":"p"}'
assert_equals 'general-purpose' "$(jq -r .helper.type "$SENT")" "a hand-off with no type is the general-purpose helper"
printf 'not json\n' | "$PICK" --hook "$HOME_ON" "$STATE" task1 listed > "$OUT"
expect_code 0 $? "unreadable hook input must let the hand-off through"
assert_equals '' "$(cat "$OUT")" "and print nothing"
pass "code facts first: a named model or a non-inheriting helper type is never asked about"

long=$(printf 'HEAD-MARK %05000d TAIL-MARK' 0)
hook "$HOME_ON" listed "$(jq -cn --arg p "$long" '{description: "d", prompt: $p}')"
assert_equals 4000 "$(jq -r '.helper.prompt | length' "$SENT")" "a long prompt is bounded"
assert_contains "$(cat "$SENT")" TAIL-MARK "a long prompt keeps its end"
assert_not_contains "$(cat "$SENT")" HEAD-MARK "and drops its start"
assert_equals "$long" "$(jq -r .hookSpecificOutput.updatedInput.prompt "$OUT")" "the helper still gets the whole prompt"
pass "a long prompt is sent as its end and handed on whole"

"$PICK" --enabled "$HOME_OFF" listed opus; expect_code 1 $? "no key: off"
"$PICK" --enabled "$HOME_ON" unlisted opus; expect_code 1 $? "unlisted project: off"
"$PICK" --enabled "$HOME_ON" listed claude-sonnet-5-5; expect_code 1 $? "a worker already on sonnet: off"
"$PICK" --enabled "$HOME_ON" listed haiku; expect_code 1 $? "a worker already on haiku: off"
"$PICK" --enabled "$HOME_ON" listed opus; expect_code 0 $? "key, listed project, strong worker: on"
"$PICK" --enabled "$HOME_ON" listed ''; expect_code 1 $? "no model named: off, so the pick can never raise a helper"
pass "--enabled: key, listed project, and a worker model worth lowering from"

# --- layer 2: what bin/fm-spawn.sh writes for the worker ----------------------

# spawn_settings <name> <home> [spawn args...]: launch a ship worker for a
# project named `listed` on a fake tmux with <home>'s key and project list, and
# print the worker's settings file with this launch's own paths named.
spawn_settings() {
  local name=$1 keyhome=$2 dir="$TMP_ROOT/spawn-$1" fakebin id="hm$$-$1"
  shift 2
  fakebin=$(fm_fakebin "$dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n' ;; esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_test_fake_treehouse_lease "$fakebin"
  mkdir -p "$dir/home/data/$id" "$dir/home/projects" "$dir/home/state" "$dir/home/config" "$dir/home/user-home"
  [ ! -f "$keyhome/.env" ] || cp "$keyhome/.env" "$dir/home/.env"
  [ ! -f "$keyhome/config/jev-code-projects" ] || cp "$keyhome/config/jev-code-projects" "$dir/home/config/"
  printf 'claude\n' > "$dir/home/config/crew-harness"
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  touch "$dir/home/state/.last-watcher-beat"
  fm_git_worktree "$dir/listed" "$dir/wt" "wt-$name"
  printf '# Task\n## Captain'"'"'s intent\nExercise the helper model pick.\n\n## Firstmate spec\nNothing more.\n' \
    > "$dir/home/data/$id/brief.md"
  env -u TYPESAFE_API_KEY -u GIT_CONFIG_PARAMETERS \
    FM_ROOT_OVERRIDE='' FM_HOME="$dir/home" HOME="$dir/home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_PROJECTS_OVERRIDE="$dir/home/projects" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$dir/wt" TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$dir/listed" --mode no-mistakes --yolo off "$@" > "$dir/out" 2>&1 \
    || fail "spawn $name failed: $(cat "$dir/out")"
  rm -rf "/tmp/fm-$id"
  sed "s#$TMP_ROOT/spawn-$name#DIR#g; s#hm$$-$name#ID#g; s#--gen '[^']*'#--gen GEN#g" "$dir/wt/.claude/settings.local.json"
}

nokey=$(spawn_settings nokey "$HOME_OFF")
assert_not_contains "$nokey" PreToolUse "without a key the worker gets no helper hook"
assert_equals "$nokey" "$(spawn_settings nolist "$HOME_KEY")" \
  "a key without the project listed writes exactly the keyless settings"
assert_equals "$nokey" "$(spawn_settings cheap "$HOME_ON" --model sonnet)" \
  "a worker already on a cheaper model gets exactly the keyless settings"
assert_equals "$nokey" "$(spawn_settings default "$HOME_ON")" \
  "a worker launched with no model named gets exactly the keyless settings"
on=$(spawn_settings on "$HOME_ON" --model opus)
assert_equals 'Agent|Task' "$(jq -r '.hooks.PreToolUse[0].matcher' <<<"$on")" "the hook fires only for the helper-agent tool"
assert_equals "$(jq -cS . <<<"$nokey")" "$(jq -cS 'del(.hooks.PreToolUse)' <<<"$on")" "every other hook is unchanged"

# Run the written command as Claude Code would, against a fake curl.
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
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
tee -a "$FAKE_CURL_LOG.body" | jq -c '{model: "jev-test", answers: (.questions | map_values({choice: "mechanical", confidence: 0.9, probabilities: {mechanical: 0.9, judgement: 0.1}}))}' > "$out"
printf 200
SH
chmod +x "$FAKEBIN/curl"
export FAKE_CURL_LOG="$TMP_ROOT/curl.log"
: > "$FAKE_CURL_LOG"
cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$TMP_ROOT/spawn-on/wt/.claude/settings.local.json")
secret='ghp_'$(printf '%036d' 0)
handoff "$(jq -cn --arg p "Run the linter.
token: $secret
Report its output." '{description: "Run lint", prompt: $p}')" \
  | env -u TYPESAFE_API_KEY PATH="$FAKEBIN:$PATH" sh -c "$cmd" > "$OUT"
expect_code 0 $? "the written command exits 0"
assert_equals 'sonnet' "$(jq -r .hookSpecificOutput.updatedInput.model "$OUT")" "the written command lowers the model"
assert_equals 1 "$(grep -c '^argv:-X$' "$FAKE_CURL_LOG")" "one request per hand-off"
assert_equals 'class' "$(jq -r '.questions | keys | join(" ")' "$FAKE_CURL_LOG.body")" "one question"
assert_no_grep "$secret" "$FAKE_CURL_LOG.body" "a credential line is withheld before sending"
assert_no_grep "$KEY" "$FAKE_CURL_LOG" "the key must not reach curl's argv"
assert_no_grep secret-present "$FAKE_CURL_LOG" "the key must not reach curl's environment"
assert_equals 'cheaper' "$(tail -n 1 "$TMP_ROOT/spawn-on/home/state/.helper-model.log" | jq -r .outcome)" \
  "the pick is recorded in the home's state"
pass "spawn: the worker gets the hook only with a key, a listed project, and a strong model, and it works as written"

echo "all fm-helper-model tests passed"
