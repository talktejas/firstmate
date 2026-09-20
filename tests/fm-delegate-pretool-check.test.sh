#!/usr/bin/env bash
# Behavior tests for the primary-session delegate guard: the tracked hook
# registration and the PreToolUse project-work classifier.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-delegate-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-delegate-pretool-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
PROJ="$TMP_ROOT/captain-copy"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$STATE" "$PRIMARY/projects" "$PROJ/src"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q
git -C "$PROJ" init -q
printf 'seeded\n' > "$PROJ/src/app.php"

BRIEF_ONLY_ROUTE='first classify the work under the AGENTS.md intake contract, then use bin/fm-brief.sh followed by bin/fm-spawn.sh for dispatched work'
SCOUT_ROUTE='first classify the work under the AGENTS.md intake contract: work already classified as a scout goes to bin/fm-scout.sh "<question>" [project], while authorized ship work and its bounded research go to bin/fm-brief.sh then bin/fm-spawn.sh'

run_check() {
  local rc=0
  : > "$OUT"
  : > "$ERR"
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$CHECK" --claude --cwd "$PRIMARY" "$@" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_allow() {
  local label=$1 rc=0
  shift
  run_check "$@" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {
  local label=$1 rc=0
  shift
  run_check "$@" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label must deny with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$label deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label deny omitted Claude's permission decision: $(cat "$ERR")"
  jq -e '.systemMessage | startswith("[delegate-project-work]")' "$ERR" >/dev/null 2>&1 \
    || fail "$label deny message lost its code: $(jq -r '.systemMessage' "$ERR")"
}

test_project_reads_are_denied_outright() {
  # No allowance exists: the very first read-shaped call into a project is
  # refused, and it stays refused however long the primary waits between calls.
  expect_deny "first project grep" --tool Bash --command "grep -rn seeded $PROJ/src"
  expect_deny "project cat" --tool Bash --command "cat $PROJ/src/app.php"
  expect_deny "project existence probe" --tool Bash --command "[ -e $PROJ/composer.json ]"
  expect_deny "project git log" --tool Bash --command "git -C $PROJ log -1 --oneline"
  expect_deny "sed without -i is still project work" \
    --tool Bash --command "sed -n 1,10p $PROJ/src/app.php"
  pass "every read-shaped project call is refused, with no per-window allowance to pace"
}

test_no_state_file_paces_the_guard() {
  # There is no budget state to seed or expire: the guard writes nothing into
  # state/ and its verdict cannot be moved by anything left there.
  local before after
  before=$(find "$STATE" -mindepth 1 | sort)
  expect_deny "project read with an empty state dir" \
    --tool Bash --command "grep -rn seeded $PROJ/src"
  after=$(find "$STATE" -mindepth 1 | sort)
  [ "$before" = "$after" ] || fail "the guard wrote pacing state into state/: $after"
  pass "the guard keeps no window state, so no stamp can release a project call"
}

test_firstmate_home_clones_are_supervision_not_project_work() {
  # A secondmate/pool/treehouse home is a separate clone of the firstmate repo.
  # Supervising one is the primary's own job, so it classifies with the home.
  local clone="$TMP_ROOT/fleet-home" lookalike="$TMP_ROOT/lookalike"
  mkdir -p "$clone/bin" "$clone/state"
  printf '# fixture\n' > "$clone/AGENTS.md"
  printf '#!/usr/bin/env bash\n' > "$clone/bin/fm-spawn.sh"
  printf '#!/usr/bin/env bash\n' > "$clone/bin/fm-brief.sh"
  git -C "$clone" init -q
  expect_allow "reading a fleet home's task status" \
    --tool Bash --command "cat $clone/state/task-9.status"
  expect_allow "Read of a fleet home file" --tool Read --path "$clone/AGENTS.md"

  # A repo that merely has AGENTS.md and a bin/ dir is still a project.
  mkdir -p "$lookalike/bin"
  printf '# not a firstmate home\n' > "$lookalike/AGENTS.md"
  git -C "$lookalike" init -q
  expect_deny "a repo without the dispatch contract is a project" \
    --tool Bash --command "cat $lookalike/AGENTS.md"
  pass "a firstmate home clone is supervision territory while a lookalike repo stays a project"
}

test_fleet_scripts_and_axi_tools_always_allowed() {
  expect_allow "fm-spawn with a project argument" \
    --tool Bash --command "bin/fm-spawn.sh task-1 $PROJ --mode no-mistakes --yolo off"
  expect_allow "fm-brief with a project argument" \
    --tool Bash --command "\"\$FM_ROOT\"/bin/fm-brief.sh task-1 $PROJ"
  expect_allow "fm script via bash wrapper" \
    --tool Bash --command "bash bin/fm-crew-state.sh task-1 $PROJ"
  expect_allow "lavish-axi serving a project page" \
    --tool Bash --command "lavish-axi $PROJ/docs/page.html"
  expect_allow "gh-axi" --tool Bash --command "gh-axi pr view 12"
  expect_allow "chrome-devtools-axi shooting into a project path" \
    --tool Bash --command "chrome-devtools-axi screenshot $PROJ/shot.png"
  expect_allow "no-mistakes daemon status" --tool Bash --command "no-mistakes daemon status"
  pass "fm-*.sh, no-mistakes, and the *-axi tools stay allowed with project arguments"
}

test_wrappers_do_not_hide_the_lead_word() {
  # A wrapped dispatch command is still the primary's own job: refusing it would
  # block the very fm-*.sh call the refusal tells the primary to make.
  expect_allow "timeout-wrapped fm-spawn" \
    --tool Bash --command "timeout 900 bin/fm-spawn.sh task-1 $PROJ --mode no-mistakes"
  expect_allow "timeout with options and duration" \
    --tool Bash --command "timeout -k 5 600 lavish-axi $PROJ/docs/page.html"
  expect_allow "bash -c wrapping fm-brief" \
    --tool Bash --command "bash -c \"bin/fm-brief.sh task-1 $PROJ\""
  expect_allow "sh -c wrapping no-mistakes" \
    --tool Bash --command "sh -c \"no-mistakes daemon status $PROJ\""
  # The same wrappers must not launder project work either.
  expect_deny "timeout-wrapped build" \
    --tool Bash --command "timeout 600 npm --prefix $PROJ test"
  expect_deny "bash -c wrapping a project grep" \
    --tool Bash --command "bash -c \"grep -rn seeded $PROJ/src\""
  pass "timeout and shell wrappers resolve to the real lead word in both directions"
}

test_redirection_targets_are_classified() {
  # A redirect into a project is a write whether or not a space follows the
  # operator; the same call must not classify two ways on whitespace alone.
  expect_deny "space-separated redirect" \
    --tool Bash --command "echo hi > $PROJ/src/patch.php"
  expect_deny "attached redirect" \
    --tool Bash --command "echo hi >$PROJ/src/patch.php"
  expect_deny "attached append redirect" \
    --tool Bash --command "echo hi >>$PROJ/src/patch.php"
  expect_deny "attached fd redirect" \
    --tool Bash --command "php -v 2>$PROJ/err.log"
  expect_deny "attached input redirect" \
    --tool Bash --command "cat <$PROJ/src/app.php"
  expect_allow "redirect outside any project" \
    --tool Bash --command "echo hi >/tmp/scratch-notes.txt"
  pass "redirection targets classify the same attached or spaced"
}

test_build_run_and_write_shapes_never_pass() {
  local cmd
  for cmd in \
    "npm --prefix $PROJ test" \
    "timeout 600 npm --prefix $PROJ test" \
    "bash -c \"npm --prefix $PROJ test\"" \
    "php $PROJ/artisan migrate" \
    "make -C $PROJ build" \
    "(cd $PROJ && npm test)" \
    "cd $PROJ" \
    "rm $PROJ/src/app.php" \
    "sed -i s/a/b/ $PROJ/src/app.php" \
    "tee $PROJ/src/app.php" \
    "git -C $PROJ merge feature" \
    "git -C $PROJ checkout main" \
    "git -C $PROJ rebase origin/develop" \
    "git -C $PROJ fetch --all --prune" \
    "git -C $PROJ branch -D feature" \
    "git -C $PROJ tag v1" \
    "git -C $PROJ config user.email x@example.test" \
    "git -C $PROJ remote add up ../up" \
    "git -C $PROJ gc" \
    "git -C $PROJ stash"; do
    expect_deny "project-mutating shape: $cmd" --tool Bash --command "$cmd"
  done
  pass "build, run, cd, write, and every project-mutating git verb are refused"
}

test_read_grep_glob_edit_write_tools_are_classified() {
  expect_deny "Read of a project file" --tool Read --path "$PROJ/src/app.php"
  expect_deny "Grep of a project dir" --tool Grep --path "$PROJ/src"
  expect_deny "Glob under a project" --tool Glob --path "$PROJ/src"
  expect_deny "Edit into a project" --tool Edit --path "$PROJ/src/app.php"
  expect_deny "Write into a project" --tool Write --path "$PROJ/src/new.php"
  expect_deny "NotebookEdit into a project" --tool NotebookEdit --path "$PROJ/nb.ipynb"
  pass "Read/Grep/Glob and Edit/Write/NotebookEdit into a project are all refused"
}

test_home_and_neutral_paths_stay_free() {
  local i
  for i in 1 2 3; do
    expect_allow "home grep $i" --tool Bash --command "grep -n spawn bin/fm-spawn.sh"
    expect_allow "home read $i" --tool Read --path "$PRIMARY/AGENTS.md"
    expect_allow "state tail $i" --tool Bash --command "tail -n 5 state/task-9.status"
    expect_allow "tmp path $i" --tool Bash --command "cat /tmp/scratch-notes.txt"
  done
  expect_allow "no-path command" --tool Bash --command "date"
  pass "the home, state, and non-repo paths are never classified as project work"
}

test_projects_prefix_counts_without_git() {
  # A clone dir that does not exist yet, or where git cannot answer, still
  # classifies by the projects/ prefix.
  expect_deny "listing under projects/" --tool Bash --command "ls projects/brand-new"
  expect_deny "probing under projects/" --tool Bash --command "[ -e projects/brand-new/composer.json ]"
  pass "anything under projects/ is a project even when git cannot resolve it"
}

test_no_environment_assignment_releases_the_guard() {
  # There is no release token. A leading assignment of any name, including the
  # one an earlier contract honoured, is just an assignment.
  local rc=0
  expect_deny "a leading FM_ALLOW_PROJECT_WORK=1 assignment" \
    --tool Bash --command "FM_ALLOW_PROJECT_WORK=1 grep -rn seeded $PROJ/src"
  expect_deny "a leading DEBUG=1 assignment" \
    --tool Bash --command "DEBUG=1 grep -rn seeded $PROJ/src"
  : > "$OUT"; : > "$ERR"
  env FM_ALLOW_PROJECT_WORK=1 FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$CHECK" --claude --cwd "$PRIMARY" --tool Bash --command "grep -rn seeded $PROJ/src" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "an ambient environment must not release the guard, got exit $rc"
  pass "no in-command assignment and no ambient environment releases the guard"
}

test_project_runtime_verbs_are_refused_without_a_path() {
  local cmd
  for cmd in \
    "docker logs jt-backend" \
    "docker restart jt-api" \
    "docker exec -it jt-backend sh" \
    "docker-compose up -d" \
    "podman logs jt-backend" \
    "psql -h localhost -d jewel -c 'select 1'" \
    "mysql -u root -e 'show databases'" \
    "redis-cli keys '*'" \
    "curl http://localhost:8000/health" \
    "curl -s http://127.0.0.1:8000/api/health" \
    "wget -qO- http://localhost:3000/" ; do
    expect_deny "project-runtime shape: $cmd" --tool Bash --command "$cmd"
  done
  # The rule is the verb plus, for http, a loopback target: the primary's own
  # remote work is untouched.
  expect_allow "a remote http request" --tool Bash --command "curl -s https://api.example.test/status"
  expect_allow "gh-axi over https" --tool Bash --command "gh-axi pr view 12"
  expect_allow "docker named by a fleet script" \
    --tool Bash --command "bin/fm-crew-state.sh task-1 docker"
  pass "container, database, and loopback-http shapes are refused with no path at all"
}

test_multi_line_and_heredoc_dispatch_commands_keep_their_release() {
  # The guard must never deny the dispatch commands its own refusal recommends.
  expect_allow "fm-send with a project path on the second line of the message" \
    --tool Bash --command "bin/fm-send.sh task-1 \"start with $PROJ/src/app.php
and report back\""
  expect_allow "a quoted single-token argument containing a newline" \
    --tool Bash --command "bin/fm-spawn.sh task-1 \"$PROJ
--mode no-mistakes\""
  expect_allow "a heredoc brief body naming project files" \
    --tool Bash --command "cat > data/task-1/brief.md <<'EOF'
Investigate $PROJ/src/app.php and $PROJ/database/migrations
EOF"
  # The heredoc body is data, not a command: the command line around it still
  # classifies.
  expect_deny "a heredoc written into a project" \
    --tool Bash --command "cat > $PROJ/src/patch.php <<'EOF'
harmless body
EOF"
  expect_deny "a project grep whose argument spans lines" \
    --tool Bash --command "grep -rn \"seeded
credential\" $PROJ/src"
  # An UNQUOTED newline is still a command boundary: a released lead word on
  # one line must not carry the next line with it.
  expect_deny "an allowed first line does not release the next line" \
    --tool Bash --command "no-mistakes daemon status
grep -rn seeded $PROJ/src"
  expect_deny "a fleet script does not release the next line" \
    --tool Bash --command "bin/fm-spawn.sh task-1 --mode no-mistakes
cat $PROJ/src/app.php"
  # A backslash line continuation is not a command boundary: a long dispatch
  # line keeps its release.
  expect_allow "a backslash-continued fm-spawn keeps its release" \
    --tool Bash --command "bin/fm-spawn.sh task-1 \\
  $PROJ --mode no-mistakes"
  expect_deny "the same two lines without the continuation still deny line two" \
    --tool Bash --command "bin/fm-spawn.sh task-1
  $PROJ --mode no-mistakes"
  # A quoted <<EOF is prose, not a heredoc opener: it must not swallow the
  # lines that follow.
  expect_allow "a steer message mentioning a heredoc" \
    --tool Bash --command "bin/fm-send.sh task-1 \"use cat <<EOF to write it\""
  expect_deny "a quoted heredoc mention does not swallow the next line" \
    --tool Bash --command "bin/fm-send.sh task-1 \"use cat <<EOF to write it\"
grep -rn seeded $PROJ/src"
  expect_deny "a heredoc mention inside a multi-line message does not swallow later lines" \
    --tool Bash --command "bin/fm-send.sh task-1 \"step one
then cat <<EOF into it
step three\"
grep -rn seeded $PROJ/src"
  expect_deny "a quoted span closing on a later line still ends there" \
    --tool Bash --command "bin/fm-send.sh task-1 \"some brief
text << EOF more\"
grep -rn seeded $PROJ/src"
  # The apostrophe idiom pairs quotes the way the shell does, so the message is
  # one argument and the line after it is its own command.
  expect_allow "an apostrophe-escaped steer message" \
    --tool Bash --command "bin/fm-send.sh task-1 'don'\\''t read the project'"
  expect_deny "an apostrophe-escaped message does not fold in the next line" \
    --tool Bash --command "bin/fm-send.sh task-1 'don'\\''t read the project'
grep -rn seeded $PROJ/src"
  expect_deny "an escaped double quote does not fold in the next line" \
    --tool Bash --command "bin/fm-send.sh task-1 \"quote is \\\" and <<EOF\"
grep -rn seeded $PROJ/src"
  # An unbalanced quote is not a span: the rest of the command is still read.
  expect_deny "an unterminated quote does not swallow the next line" \
    --tool Bash --command "bin/fm-send.sh task-1 \"unbalanced message
grep -rn seeded $PROJ/src"
  # A herestring is not a heredoc opener: the lines after it must still be read.
  expect_deny "a herestring does not swallow the next line" \
    --tool Bash --command "jq -r .a <<< \"\$payload\"
grep -rn seeded $PROJ/src"
  pass "quoted multi-line arguments and heredoc bodies stay inside their own command"
}

test_deny_message_names_the_dispatch_path() {
  local actual
  printf '#!/usr/bin/env bash\n' > "$PRIMARY/bin/fm-scout.sh"
  run_check --tool Bash --command "grep -rn seeded $PROJ/src" && fail "scout-present case must still deny"
  actual=$(jq -r '.systemMessage' "$ERR")
  case "$actual" in
    *"$SCOUT_ROUTE"*) ;;
    *) fail "deny must name the scout dispatch route: $actual" ;;
  esac
  # The refusal names the dispatch path and nothing else: any release token it
  # could name would make the mechanism a choice again.
  case "$actual" in
    *FM_ALLOW_PROJECT_WORK*) fail "deny must not advertise a bypass token: $actual" ;;
  esac
  case "$actual" in
    *"blocked tool: Bash"*) ;;
    *) fail "deny must name the blocked tool: $actual" ;;
  esac
  rm -f "$PRIMARY/bin/fm-scout.sh"
  run_check --tool Bash --command "grep -rn seeded $PROJ/src" && fail "scout-absent case must still deny"
  actual=$(jq -r '.systemMessage' "$ERR")
  case "$actual" in
    *"$BRIEF_ONLY_ROUTE"*) ;;
    *) fail "deny must degrade to brief-then-spawn when fm-scout.sh is absent: $actual" ;;
  esac
  pass "the refusal names the intake classification and the dispatch scripts, never the bypass token"
}

test_crewmate_worktree_and_non_firstmate_repo_are_inert() {
  local child="$TMP_ROOT/child" plain="$TMP_ROOT/plain" rc=0
  git -C "$PRIMARY" config user.name fixture
  git -C "$PRIMARY" config user.email fixture@example.test
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/bin" "$child/state"
  printf '# fixture\n' > "$child/AGENTS.md"
  : > "$OUT"; : > "$ERR"
  FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
    "$CHECK" --claude --cwd "$child" --tool Bash --command "grep -rn seeded $PROJ/src && npm --prefix $PROJ test" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a crewmate task worktree must be out of scope, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "task-worktree no-op wrote output"

  mkdir -p "$plain/bin"
  git -C "$plain" init -q
  rc=0
  FM_ROOT_OVERRIDE="$plain" FM_HOME="$plain" FM_STATE_OVERRIDE="$plain/state" \
    "$CHECK" --claude --cwd "$plain" --tool Bash --command "grep -rn seeded $PROJ/src" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a non-firstmate repo must be out of scope, got exit $rc"
  pass "a crewmate investigating project code is untouched, as is any non-firstmate repo"
}

test_secondmate_home_is_in_scope() {
  local second="$TMP_ROOT/second" rc=0
  git -C "$PRIMARY" worktree add -q -b fixture-second "$second"
  mkdir -p "$second/bin" "$second/state"
  printf '# fixture\n' > "$second/AGENTS.md"
  printf 'sm-fixture\n' > "$second/.fm-secondmate-home"
  FM_ROOT_OVERRIDE="$second" FM_HOME="$second" FM_STATE_OVERRIDE="$second/state" \
    "$CHECK" --claude --cwd "$second" --tool Bash --command "grep -rn seeded $PROJ/src" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "a marked secondmate home operates a fleet and must be guarded, got exit $rc"
  # Its own home files stay free even though the home is a linked worktree.
  rc=0
  FM_ROOT_OVERRIDE="$second" FM_HOME="$second" FM_STATE_OVERRIDE="$second/state" \
    "$CHECK" --claude --cwd "$second" --tool Read --path "$second/AGENTS.md" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a secondmate reading its own home must stay allowed, got exit $rc"
  pass "a marked secondmate home is guarded while its own home files stay free"
}

test_stdin_transports_and_output_shapes() {
  local rc=0
  : > "$OUT"; : > "$ERR"
  printf '{"tool_name":"Read","tool_input":{"file_path":"%s/src/app.php"},"cwd":"%s"}' "$PROJ" "$PRIMARY" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Claude-shaped stdin must deny, got exit $rc"
  [ ! -s "$OUT" ] || fail "Claude deny wrote stdout, which makes Claude ignore the deny: $(cat "$OUT")"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '{"toolName":"Bash","toolInput":{"command":"grep -rn seeded %s/src"},"cwd":"%s"}' "$PROJ" "$PRIMARY" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Grok-shaped stdin must deny, got exit $rc"
  jq -e '.decision == "deny" and (.reason | startswith("[delegate-project-work]"))' "$OUT" >/dev/null 2>&1 \
    || fail "default deny mode must write a Grok decision object on stdout: $(cat "$OUT")"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '{"tool_name":"Bash","tool_input":{"command":"ls bin"},"cwd":"%s"}' "$PRIMARY" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a home-target Bash payload must allow, got exit $rc"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "stdin allow wrote output"
  pass "both stdin transports classify correctly and Claude's deny keeps stdout empty"
}

test_harness_tool_names_and_cursor_rendering() {
  local rc=0
  # Grok's shell tool is run_terminal_command and Cursor's is Shell: the names
  # the tracked sibling seatbelt registrations match. Both must classify.
  : > "$OUT"; : > "$ERR"
  printf '{"toolName":"run_terminal_command","toolInput":{"command":"grep -rn seeded %s/src"},"cwd":"%s"}' "$PROJ" "$PRIMARY" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "a Grok run_terminal_command payload must deny, got exit $rc"
  jq -e '.decision == "deny"' "$OUT" >/dev/null 2>&1 \
    || fail "Grok deny must carry its decision object on stdout: $(cat "$OUT")"

  # Cursor reads the RETURNED object, not the exit status.
  rc=0
  : > "$OUT"; : > "$ERR"
  printf '{"tool_name":"Shell","tool_input":{"command":"grep -rn seeded %s/src"},"cwd":"%s","cursor_version":"2026.08.11-e8db854"}' "$PROJ" "$PRIMARY" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --cursor > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a --cursor deny must exit 0 so Cursor reads the object, got exit $rc"
  jq -e '.permission == "deny" and (.user_message | startswith("[delegate-project-work]"))' "$OUT" >/dev/null 2>&1 \
    || fail "--cursor deny must print Cursor's own decision object: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "--cursor deny wrote stderr: $(cat "$ERR")"

  # Without --cursor the same payload is the Claude-settings duplicate Cursor
  # also loads, already decided by Cursor's own registration.
  rc=0
  : > "$OUT"; : > "$ERR"
  printf '{"tool_name":"Shell","tool_input":{"command":"grep -rn seeded %s/src"},"cwd":"%s","cursor_version":"2026.08.11-e8db854"}' "$PROJ" "$PRIMARY" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "the Claude-settings duplicate of a Cursor payload must stand down, got exit $rc"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "the Cursor duplicate stand-down wrote output"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '{"tool_name":"Shell","tool_input":{"command":"ls bin"},"cwd":"%s","cursor_version":"2026.08.11-e8db854"}' "$PRIMARY" \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --cursor > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a home-target Cursor payload must allow, got exit $rc"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "--cursor allow wrote output"
  pass "Grok and Cursor shell tool names classify, and --cursor renders Cursor's own decision"
}

test_malformed_transport_fails_open() {
  local rc payload
  for payload in '{not-json' '' '{}' '{"tool_name":null}' '{"tool_name":"Read"}'; do
    rc=0
    : > "$OUT"; : > "$ERR"
    printf '%s' "$payload" \
      | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
        "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
    [ "$rc" -eq 0 ] || fail "malformed transport must fail open, payload '$payload' gave exit $rc"
    [ ! -s "$OUT" ] || fail "fail-open path wrote stdout for payload '$payload'"
  done
  pass "malformed, empty, and target-less payloads fail open rather than blocking every tool call"
}

test_other_tools_and_mcp_names_are_out_of_scope() {
  expect_allow "Skill tool" --tool Skill
  expect_allow "WebFetch tool" --tool WebFetch
  expect_allow "MCP tool name" --tool mcp__tracker__read_file --path "$PROJ/src/app.php"
  pass "only the classified tool names are ever evaluated"
}

test_tracked_registration_covers_the_classified_tools() {
  local matcher
  command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
  matcher=$(jq -r '.hooks.PreToolUse[] | select(.hooks[].command | contains("fm-delegate-pretool-check.sh")) | .matcher' "$ROOT/.claude/settings.json")
  [ -n "$matcher" ] || fail "tracked .claude/settings.json must register fm-delegate-pretool-check.sh under PreToolUse"
  local tool
  for tool in Bash Read Grep Glob Edit Write NotebookEdit; do
    printf '%s' "$tool" | grep -Eq "$matcher" || fail "tracked matcher '$matcher' must cover $tool"
  done
  jq -e '.hooks.PreToolUse[] | select(.hooks[].command | contains("fm-delegate-pretool-check.sh")) | .hooks[].command | contains("--claude")' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "the tracked Claude registration must pass --claude so a deny keeps stdout empty"
  pass "the tracked Claude registration covers every classified tool and passes --claude"
}

# A stub guard home: every tracked registration must actually reach the guard
# script with the harness payload, which is what each JSON entry promises.
make_stub_home() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/.codex"
  printf '# fixture\n' > "$dir/AGENTS.md"
  cp "$ROOT/.codex/hooks.json" "$dir/.codex/hooks.json"
  cat > "$dir/bin/fm-delegate-pretool-check.sh" <<'STUB'
#!/usr/bin/env bash
payload=$(cat 2>/dev/null || true)
printf 'args=%s payload=%s
' "$*" "$payload" > "${FM_STUB_LOG:?}"
STUB
  chmod +x "$dir/bin/fm-delegate-pretool-check.sh"
}

test_every_primary_harness_registration_reaches_the_guard() {
  local dir log cmd payload
  command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
  dir="$TMP_ROOT/harness-wiring"
  log="$TMP_ROOT/harness-wiring.log"
  make_stub_home "$dir"
  payload='{"tool_name":"Bash","tool_input":{"command":"grep -rn seeded /proj/src"}}'

  cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(contains("fm-delegate-pretool-check.sh"))' \
    "$ROOT/.grok/hooks/fm-primary-delegate-check.json")
  [ -n "$cmd" ] || fail "tracked .grok/hooks must register the delegate guard on the Bash matcher"
  rm -f "$log"
  printf '%s' "$payload" | env FM_STUB_LOG="$log" GROK_WORKSPACE_ROOT="$dir" bash -c "$cmd" >/dev/null 2>&1
  grep -q "payload=$payload" "$log" 2>/dev/null \
    || fail "the Grok registration did not deliver the payload to the guard: $(cat "$log" 2>/dev/null)"

  cmd=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(contains("fm-delegate-pretool-check.sh"))' \
    "$ROOT/.codex/hooks.json")
  [ -n "$cmd" ] || fail "tracked .codex/hooks.json must register the delegate guard on the Bash matcher"
  rm -f "$log"
  printf '%s' "$payload" | (cd "$dir" && env FM_STUB_LOG="$log" bash -c "$cmd") >/dev/null 2>&1
  grep -q "payload=$payload" "$log" 2>/dev/null \
    || fail "the Codex registration did not deliver the payload to the guard: $(cat "$log" 2>/dev/null)"

  cmd=$(jq -r '.hooks.preToolUse[] | select(.matcher == "Shell") | .command | select(contains("fm-delegate-pretool-check.sh"))' \
    "$ROOT/.cursor/hooks.json")
  [ -n "$cmd" ] || fail "tracked .cursor/hooks.json must register the delegate guard on the Shell matcher"
  rm -f "$log"
  printf '%s' "$payload" | env FM_STUB_LOG="$log" CURSOR_PROJECT_DIR="$dir" bash -c "$cmd" >/dev/null 2>&1
  grep -q 'args=--cursor' "$log" 2>/dev/null \
    || fail "the Cursor registration must pass --cursor: $(cat "$log" 2>/dev/null)"
  pass "the Grok, Codex, and Cursor registrations each reach the guard with the harness payload"
}

test_opencode_plugin_blocks_a_denied_command() {
  local plugin dir out status
  command -v node >/dev/null 2>&1 || fail "test host must provide node"
  plugin="$ROOT/.opencode/plugins/fm-primary-delegate-check.js"
  [ -f "$plugin" ] || fail "tracked OpenCode delegate plugin is missing"
  dir="$TMP_ROOT/opencode-delegate"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/fm-delegate-pretool-check.sh" <<'STUB'
#!/usr/bin/env bash
printf 'tool=%s
' "$2"
printf '[delegate-project-work] refused
' >&2
exit 2
STUB
  chmod +x "$dir/bin/fm-delegate-pretool-check.sh"
  out=$(NODE_NO_WARNINGS=1 PLUGIN="$plugin" WORKTREE="$dir" node 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const hooks = await mod.FmPrimaryDelegateCheck({ worktree: process.env.WORKTREE });
let blocked = "";
try {
  await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "grep -rn seeded /proj/src" } });
} catch (error) {
  blocked = error.message;
}
if (!blocked.includes("[delegate-project-work]")) {
  console.error(`plugin did not surface the guard refusal: ${blocked}`);
  process.exit(1);
}
await hooks["tool.execute.before"]({ tool: "read" }, { args: { command: "grep -rn seeded /proj/src" } });
EOF
)
  status=$?
  [ "$status" -eq 0 ] || fail "OpenCode delegate plugin must block a denied bash command: $out"
  pass "the OpenCode plugin surfaces the guard's refusal and ignores non-bash tools"
}

test_project_reads_are_denied_outright
test_no_state_file_paces_the_guard
test_firstmate_home_clones_are_supervision_not_project_work
test_fleet_scripts_and_axi_tools_always_allowed
test_wrappers_do_not_hide_the_lead_word
test_redirection_targets_are_classified
test_build_run_and_write_shapes_never_pass
test_read_grep_glob_edit_write_tools_are_classified
test_home_and_neutral_paths_stay_free
test_projects_prefix_counts_without_git
test_no_environment_assignment_releases_the_guard
test_project_runtime_verbs_are_refused_without_a_path
test_multi_line_and_heredoc_dispatch_commands_keep_their_release
test_deny_message_names_the_dispatch_path
test_crewmate_worktree_and_non_firstmate_repo_are_inert
test_secondmate_home_is_in_scope
test_stdin_transports_and_output_shapes
test_harness_tool_names_and_cursor_rendering
test_malformed_transport_fails_open
test_other_tools_and_mcp_names_are_out_of_scope
test_tracked_registration_covers_the_classified_tools
test_every_primary_harness_registration_reaches_the_guard
test_opencode_plugin_blocks_a_denied_command
