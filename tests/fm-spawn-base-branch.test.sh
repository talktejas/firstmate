#!/usr/bin/env bash
# Regression test for fm-spawn.sh's task-worktree base branch
# (bin/fm-spawn.sh's ensure_spawn_base_branch, bin/fm-project-mode.sh's base=).
#
# A freshly allocated pool worktree lands on the repo's DEFAULT branch. For a
# project that develops on another branch that is silently the wrong base: task
# jt-style-number-column audited a tree 1036 commits behind origin/develop and
# correctly reported that nothing described in its brief existed. A REUSED slot
# already sits on the right branch, which is why only a cold slot is affected.
#
# The fixtures below build exactly that shape - a main-defaulted clone whose
# work happens on develop, plus a cold worktree detached at main - and assert
# the recorded base is checked out, an unconfirmable base is refused instead of
# launched, and a project with no base= record still spawns as it does today.
#
# The same fixtures cover fm-spawn.sh's per-spawn --base flag, which exists so an
# effort can accumulate on one integration branch without editing the shared
# registry and having to remember to restore it: the flag wins over the registry,
# the registry still governs when the flag is absent, an explicit base that does
# not resolve refuses instead of falling back, and a relaunch reuses the task's
# own recorded base rather than accepting a new one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
MODE="$ROOT/bin/fm-project-mode.sh"
PROJECT_BASE="$ROOT/bin/fm-project-base.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-base-branch)
fm_git_identity

# make_base_fakebin <dir>: fake tmux reporting the cold worktree as the pane's
# cwd (standing in for treehouse get), plus a no-op treehouse.
make_base_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_base_case <name> <id> <primary-branch> [registry-line]: build a home plus
# a project clone whose default branch is main and whose develop branch is three
# commits ahead, with a COLD worktree detached at main. <primary-branch> is the
# branch the project clone itself sits on; a registry line is written only when
# one is given (its absence is the unregistered-project case).
make_base_case() {
  local name=$1 id=$2 primary=$3 reg_line=${4:-}
  local case_dir home src bare proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  src="$case_dir/src"
  bare="$case_dir/remote.git"
  proj="$case_dir/projects/$name"
  wt="$case_dir/cold-slot"
  fakebin=$(make_base_fakebin "$case_dir/fake")

  fm_git_init_commit "$src"
  git -C "$src" branch -M main
  git -C "$src" checkout -q -b develop
  local i
  for i in 1 2 3; do
    printf 'develop work %s\n' "$i" > "$src/dev-$i.txt"
    git -C "$src" add "dev-$i.txt"
    git -C "$src" commit -qm "develop $i"
  done
  git -C "$src" checkout -q main
  git clone --quiet --bare "$src" "$bare"
  mkdir -p "$case_dir/projects"
  git clone --quiet "$bare" "$proj"
  git -C "$proj" checkout -q "$primary"
  # The cold slot: a brand-new worktree off the DEFAULT branch, exactly what a
  # freshly allocated pool slot hands over.
  git -C "$proj" worktree add --quiet --detach "$wt" main

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  cat > "$home/data/$id/brief.md" <<BRIEF
# Task

## Captain's intent

base branch regression fixture

## Firstmate spec

no build work; the spawn path itself is what is under test
BRIEF
  touch "$home/state/.last-watcher-beat"
  if [ -n "$reg_line" ]; then
    printf '# Projects\n%s\n' "$reg_line" > "$home/data/projects.md"
  fi

  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

read_base_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# Upstream requires an explicit --mode/--yolo at spawn: firstmate resolves them
# at intake rather than the spawn re-reading the registry, so the caller says so.
run_base_spawn() {
  local id=$1 mode=${2:-no-mistakes} kind=${3:-ship}
  local -a kindargs
  shift $(( $# < 3 ? $# : 3 ))
  if [ "$kind" = scout ]; then
    kindargs=(--scout)
  else
    kindargs=(--mode "$mode" --yolo off)
  fi
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "${kindargs[@]}" "$@" 2>&1
}

head_sha() { git -C "$1" rev-parse HEAD; }

# A cold slot for a develop-based project starts the worker on develop, not on
# the default branch the slot was allocated from.
test_recorded_base_is_checked_out() {
  local rec id out status
  id=base-recorded-b1
  rec=$(make_base_case base-recorded "$id" main \
    '- base-recorded [no-mistakes base=develop] - develop-based (added 2026-07-28)')
  read_base_record "$rec"

  out=$(run_base_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed with a recorded base branch: $out"
  [ "$(head_sha "$WT_DIR")" = "$(git -C "$PROJ_DIR" rev-parse origin/develop)" ] \
    || fail "cold slot was not moved to the recorded base branch (HEAD $(head_sha "$WT_DIR"))"
  pass "a cold slot for a develop-based project starts the worker on develop"
}

# With no base record the repo default branch is the base, exactly as before:
# the recorded-base lookup is additive and never changes the unrecorded case.
test_unconfirmable_base_is_refused() {
  local rec id out status
  id=base-stale-b2
  rec=$(make_base_case base-stale "$id" develop \
    '- base-stale [no-mistakes] - no base record (added 2026-07-28)')
  read_base_record "$rec"

  out=$(run_base_spawn "$id")
  status=$?
  expect_code 0 "$status" "an unrecorded project should still launch from the repo default: $out"
  [ "$(head_sha "$WT_DIR")" = "$(git -C "$PROJ_DIR" rev-parse origin/main)" ] \
    || fail "an unrecorded project did not land on the repo default branch (HEAD $(head_sha "$WT_DIR"))"
  pass "a project with no base record still starts from the repo default branch"
}

# The assertion passes when the default branch IS the right base: no record, and
# the project develops on its default branch.
test_default_base_passes_assertion() {
  local rec id out status
  id=base-default-b3
  rec=$(make_base_case base-default "$id" main \
    '- base-default [direct-PR] - main-based (added 2026-07-28)')
  read_base_record "$rec"

  out=$(run_base_spawn "$id" direct-PR)
  status=$?
  expect_code 0 "$status" "spawn should succeed when the default branch is the right base: $out"
  [ "$(head_sha "$WT_DIR")" = "$(git -C "$PROJ_DIR" rev-parse origin/main)" ] \
    || fail "worker was not left on the default branch"
  assert_grep "mode=direct-PR" "$HOME_DIR/state/$id.meta" "delivery mode was not recorded"
  pass "a project whose default branch is the right base passes the assertion"
}

# An unregistered project - no registry at all - spawns exactly as it does today.
test_unregistered_project_spawns_as_today() {
  local rec id out status
  id=base-unregistered-b4
  rec=$(make_base_case base-unregistered "$id" main)
  read_base_record "$rec"
  [ -f "$HOME_DIR/data/projects.md" ] && fail "fixture should have no registry"

  out=$(run_base_spawn "$id")
  status=$?
  expect_code 0 "$status" "an unregistered project must still spawn: $out"
  [ "$(head_sha "$WT_DIR")" = "$(git -C "$PROJ_DIR" rev-parse origin/main)" ] \
    || fail "unregistered project did not fall back to the repo default branch"
  assert_grep "mode=no-mistakes" "$HOME_DIR/state/$id.meta" "unregistered fallback mode changed"
  pass "an unregistered project falls back to the default branch and spawns as today"
}

# A base= record naming a branch this repo does not have is refused rather than
# silently ignored back to the default branch.
test_missing_base_branch_is_refused() {
  local rec id out status
  id=base-typo-b5
  rec=$(make_base_case base-typo "$id" main \
    '- base-typo [no-mistakes base=develp] - typo in the base record (added 2026-07-28)')
  read_base_record "$rec"

  out=$(run_base_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a base= record naming a missing branch should be refused: $out"
  assert_contains "$out" "develp" "refusal did not name the missing base branch"
  assert_contains "$out" "refusing to launch" "refusal did not say it was refusing to launch"
  pass "a base= record naming a branch the repo does not have is refused"
}

# A local-only project lands work with bin/fm-merge-local.sh, which fast-forwards
# the LOCAL default branch and never pushes, so origin/main is the stale ref
# there and the worker must start from the local branch instead.
test_local_only_prefers_local_branch() {
  local rec id out status
  id=base-localonly-b6
  rec=$(make_base_case base-localonly "$id" main \
    '- base-localonly [local-only] - merged locally, never pushed (added 2026-07-28)')
  read_base_record "$rec"
  printf 'landed locally\n' > "$PROJ_DIR/landed.txt"
  git -C "$PROJ_DIR" add landed.txt
  git -C "$PROJ_DIR" commit -qm "landed locally"

  out=$(run_base_spawn "$id" local-only)
  status=$?
  expect_code 0 "$status" "a local-only project must still spawn: $out"
  [ "$(head_sha "$WT_DIR")" = "$(git -C "$PROJ_DIR" rev-parse main)" ] \
    || fail "local-only worker did not start from the local default branch (HEAD $(head_sha "$WT_DIR"))"
  [ "$(head_sha "$WT_DIR")" != "$(git -C "$PROJ_DIR" rev-parse origin/main)" ] \
    || fail "local-only worker started from the stale origin/main"
  pass "a local-only project starts the worker from the local default branch"
}

# A scout audits the same tree a ship would build on, so the recorded base must
# apply to it too. It regressed once because the project name was resolved only
# on the ship path.
test_scout_also_starts_from_the_recorded_base() {
  local rec id out status
  id=base-scout-b7
  rec=$(make_base_case base-scout "$id" main \
    '- base-scout [no-mistakes base=develop] - develop-based (added 2026-09-10)')
  read_base_record "$rec"

  out=$(run_base_spawn "$id" no-mistakes scout)
  status=$?
  expect_code 0 "$status" "a scout should spawn on a develop-based project: $out"
  [ "$(head_sha "$WT_DIR")" = "$(git -C "$PROJ_DIR" rev-parse origin/develop)" ] \
    || fail "scout did not start from the recorded base branch (HEAD $(head_sha "$WT_DIR"))"
  pass "a scout also starts from the project's recorded base branch"
}

# The registry parse: base= is readable alongside the delivery mode, and every
# pre-existing line shape keeps parsing to exactly the same two words.
test_registry_parse_is_backward_compatible() {
  local dir out
  dir="$TMP_ROOT/parse/data"
  mkdir -p "$dir"
  cat > "$dir/projects.md" <<'EOF'
# Projects
- legacy - plain line (added 2026-01-01)
- moded [direct-PR] - mode only (added 2026-01-01)
- yolod [local-only +yolo] - mode and yolo (added 2026-01-01)
- based [no-mistakes base=develop] - base record (added 2026-01-01)
- everything [direct-PR +yolo base=develop] - all tokens (added 2026-01-01)
- reordered [direct-PR base=develop +yolo] - unordered tokens (added 2026-01-01)
- baseonly [base=develop] - base without a mode (added 2026-01-01)
EOF

  local name want
  while IFS='|' read -r name want; do
    [ -n "$name" ] || continue
    out=$(FM_DATA_OVERRIDE="$dir" "$MODE" "$name" 2>/dev/null)
    [ "$out" = "$want" ] \
      || fail "delivery-mode parse changed for $name: got '$out', want '$want'"
  done <<'EOF'
legacy|no-mistakes off
moded|direct-PR off
yolod|local-only on
based|no-mistakes off
everything|direct-PR on
reordered|direct-PR on
baseonly|no-mistakes off
EOF

  for name in based everything reordered baseonly; do
    out=$(FM_DATA_OVERRIDE="$dir" "$MODE" --base "$name" 2>/dev/null)
    [ "$out" = develop ] || fail "--base did not read base= for $name: got '$out'"
  done
  for name in legacy moded yolod absent; do
    out=$(FM_DATA_OVERRIDE="$dir" "$MODE" --base "$name" 2>/dev/null)
    [ -z "$out" ] || fail "--base invented a base branch for $name: got '$out'"
  done
  out=$(FM_DATA_OVERRIDE="$TMP_ROOT/parse/absent" "$MODE" --base anything 2>/dev/null)
  [ -z "$out" ] || fail "--base against a missing registry should print nothing: got '$out'"

  pass "base= parses alongside the delivery mode without changing any existing line's mode"
}

# --- bin/fm-project-base.sh: the declaration lives IN THE REPO ---------------
# A base kept only in one home's private data/projects.md tells no other home
# anything: a second mate that owns a project found its base unset for exactly
# that reason. The committed .firstmate-base file is what every clone can read,
# including the typical shape where it is landed on develop and the abandoned
# default branch never receives it.
make_declared_clone() {  # <name> <branch-carrying-the-file> [file-content]
  local name=$1 on=$2 content=${3:-develop}
  local dir src bare clone
  dir="$TMP_ROOT/declared/$name"
  src="$dir/src"
  bare="$dir/remote.git"
  clone="$dir/clone"
  mkdir -p "$dir"
  git init -q "$src"
  git -C "$src" symbolic-ref HEAD refs/heads/main
  echo seed > "$src/file.txt"
  git -C "$src" add file.txt
  git -C "$src" commit -qm C0
  if [ "$on" != main ]; then
    git -C "$src" checkout -q -b "$on"
  fi
  printf '%s\n' "$content" > "$src/.firstmate-base"
  git -C "$src" add .firstmate-base
  git -C "$src" commit -qm declare
  git -C "$src" checkout -q main
  git clone -q --bare "$src" "$bare"
  git -C "$src" remote add origin "file://$(cd "$bare" && pwd)"
  git -C "$src" push -q origin --all
  git clone -q "file://$(cd "$bare" && pwd)" "$clone"
  printf '%s\n' "$clone"
}

test_declaration_is_read_from_the_branch_that_carries_it() {
  local clone out
  clone=$(make_declared_clone carried develop)
  [ "$(git -C "$clone" symbolic-ref --short HEAD)" = main ] \
    || fail "fixture clone should sit on main, the branch WITHOUT the declaration"
  out=$("$PROJECT_BASE" "$clone")
  [ "$out" = develop ] \
    || fail "declaration on develop was not found from a clone checked out on main: got '$out'"
  pass "a declaration landed only on the development branch is still read by a clone on the default branch"
}

test_declaration_beats_the_private_registry() {
  local clone reg out
  clone=$(make_declared_clone beats develop)
  reg="$TMP_ROOT/declared/beats/data"
  mkdir -p "$reg"
  printf -- '- beats [no-mistakes base=stale-from-registry] - x (added 2026-01-01)\n' > "$reg/projects.md"
  out=$(FM_DATA_OVERRIDE="$reg" "$PROJECT_BASE" "$clone" beats)
  [ "$out" = develop ] \
    || fail "the committed declaration must win over this home's private registry: got '$out'"
  pass "the repository's own declaration wins over a home-private registry record"
}

test_registry_is_the_fallback_when_nothing_is_declared() {
  local clone reg out
  clone=$(make_declared_clone fallback develop)
  git -C "$clone" push -q origin --delete develop
  git -C "$clone" fetch -q --prune origin
  reg="$TMP_ROOT/declared/fallback/data"
  mkdir -p "$reg"
  printf -- '- fallback [no-mistakes base=from-registry] - x (added 2026-01-01)\n' > "$reg/projects.md"
  out=$(FM_DATA_OVERRIDE="$reg" "$PROJECT_BASE" "$clone" fallback)
  [ "$out" = from-registry ] \
    || fail "an undeclared project should fall back to its registry record: got '$out'"
  out=$(FM_DATA_OVERRIDE="$TMP_ROOT/declared/fallback/absent" "$PROJECT_BASE" "$clone" fallback)
  [ -z "$out" ] \
    || fail "with no declaration and no registry the resolver must print nothing: got '$out'"
  pass "the private registry remains the fallback for a project that has not adopted the file"
}

test_malformed_declaration_never_reaches_git() {
  local clone out name
  for name in dashed spaced; do
    clone=$(make_declared_clone "$name" main)
    case $name in
      dashed) printf -- '--upload-pack=touch /tmp/pwn\n' > "$clone/.firstmate-base" ;;
      spaced) printf 'develop; rm -rf /\n' > "$clone/.firstmate-base" ;;
    esac
    out=$("$PROJECT_BASE" "$clone")
    [ "$out" = develop ] \
      || fail "the malformed value should be skipped for the committed develop for $name: got '$out'"
    [ "$out" != "$(cat "$clone/.firstmate-base")" ] \
      || fail "a malformed declaration was passed through for $name: got '$out'"
    case $out in
      *' '*|-*) fail "resolver emitted an unusable branch name for $name: '$out'" ;;
    esac
  done
  pass "a malformed declaration is rejected rather than handed to git"
}

# Stock macOS /bin/bash is 3.2, and the ref scan is the tier that finds a
# declaration landed only on the development branch. A bash-4-only builtin there
# fails at runtime, resolves nothing, and every caller silently falls back to the
# stale repository default - the exact fault this change removes. CI runs this
# one test under real /bin/bash 3.2 via FM_TEST_ONLY.
test_declaration_resolves_under_stock_bash() {
  local clone out
  [ -x /bin/bash ] || { pass "resolver under /bin/bash skipped without /bin/bash"; return 0; }
  clone=$(make_declared_clone stockbash develop)
  [ "$(git -C "$clone" symbolic-ref --short HEAD)" = main ] \
    || fail "fixture clone should sit on main, the branch WITHOUT the declaration"
  out=$(/bin/bash "$PROJECT_BASE" "$clone")
  [ "$out" = develop ] \
    || fail "the resolver did not read the declaration under /bin/bash: got '$out'"
  pass "the resolver reads a declaration from an unchecked-out branch under stock /bin/bash"
}

# The per-spawn flag wins over the project's registry record. This is the whole
# point of the flag: an effort that must accumulate on one integration branch
# says so at dispatch instead of editing shared state it then has to restore.
test_explicit_base_beats_the_registry() {
  local rec id out status
  id=base-explicit-b8
  rec=$(make_base_case base-explicit "$id" main \
    '- base-explicit [no-mistakes base=main] - registry says main (added 2026-09-17)')
  read_base_record "$rec"

  out=$(run_base_spawn "$id" no-mistakes ship --base develop)
  status=$?
  expect_code 0 "$status" "an explicit --base should spawn: $out"
  [ "$(head_sha "$WT_DIR")" = "$(git -C "$PROJ_DIR" rev-parse origin/develop)" ] \
    || fail "explicit --base did not win over the registry record (HEAD $(head_sha "$WT_DIR"))"
  assert_grep "base=develop" "$HOME_DIR/state/$id.meta" "resolved base was not recorded"
  pass "an explicit --base wins over the project's registry base record"
}

# The flag governs its own spawn only: nothing is written back to the registry,
# so the next unrelated task still reads the captain's standing base.
test_explicit_base_is_not_written_back() {
  local rec id out status before
  id=base-noleak-b9
  rec=$(make_base_case base-noleak "$id" main \
    '- base-noleak [no-mistakes base=main] - registry says main (added 2026-09-17)')
  read_base_record "$rec"
  before=$(cat "$HOME_DIR/data/projects.md")

  out=$(run_base_spawn "$id" no-mistakes ship --base develop)
  status=$?
  expect_code 0 "$status" "an explicit --base should spawn: $out"
  [ "$(cat "$HOME_DIR/data/projects.md")" = "$before" ] \
    || fail "an explicit --base rewrote the shared project registry"
  pass "an explicit --base is never written back to the shared registry"
}

# Precedence below the flag is unchanged: with no --base the registry still wins.
test_registry_base_applies_without_the_flag() {
  local rec id out status
  id=base-noflag-b10
  rec=$(make_base_case base-noflag "$id" main \
    '- base-noflag [no-mistakes base=develop] - develop-based (added 2026-09-17)')
  read_base_record "$rec"

  out=$(run_base_spawn "$id")
  status=$?
  expect_code 0 "$status" "a spawn with no --base should still use the registry: $out"
  [ "$(head_sha "$WT_DIR")" = "$(git -C "$PROJ_DIR" rev-parse origin/develop)" ] \
    || fail "the registry base stopped applying when --base was absent"
  assert_no_grep "base=develop" "$HOME_DIR/state/$id.meta" \
    "a spawn that named no base still recorded one, freezing its landing target"
  pass "the registry base still applies when --base is absent"
}

# The fail-closed half. A base the project cannot resolve must stop the spawn
# naming the branch, never quietly fall back to the registry value: a worker
# silently based on the wrong branch is exactly the failure the flag prevents.
test_unresolvable_explicit_base_refuses() {
  local rec id out status
  id=base-badflag-b11
  rec=$(make_base_case base-badflag "$id" main \
    '- base-badflag [no-mistakes base=develop] - develop-based (added 2026-09-17)')
  read_base_record "$rec"

  out=$(run_base_spawn "$id" no-mistakes ship --base integration/never-created)
  status=$?
  [ "$status" -ne 0 ] || fail "an unresolvable --base should refuse the spawn: $out"
  assert_contains "$out" "integration/never-created" "refusal did not name the requested base branch"
  assert_contains "$out" "refusing to launch" "refusal did not say it was refusing to launch"
  [ "$(head_sha "$WT_DIR")" != "$(git -C "$PROJ_DIR" rev-parse origin/develop)" ] \
    || fail "an unresolvable --base silently fell back to the registry base"
  pass "an explicit base the project cannot resolve refuses instead of falling back"
}

# A scout audits the tree a ship would build on, so it takes the flag too.
test_scout_accepts_an_explicit_base() {
  local rec id out status
  id=base-scoutflag-b12
  rec=$(make_base_case base-scoutflag "$id" main \
    '- base-scoutflag [no-mistakes base=main] - registry says main (added 2026-09-17)')
  read_base_record "$rec"

  out=$(run_base_spawn "$id" no-mistakes scout --base develop)
  status=$?
  expect_code 0 "$status" "a scout should accept an explicit base: $out"
  [ "$(head_sha "$WT_DIR")" = "$(git -C "$PROJ_DIR" rev-parse origin/develop)" ] \
    || fail "scout did not start from the explicit base (HEAD $(head_sha "$WT_DIR"))"
  pass "a scout also starts from an explicit --base"
}

# A scout is refused --mode by design, so its local-vs-origin choice has to come
# from the project's registered posture: a local-only project lands with
# bin/fm-merge-local.sh and never pushes, so origin/<base> is the stale ref and a
# scout resolving against it would audit an old tree.
test_scout_on_a_local_only_project_uses_the_local_branch() {
  local rec id out status
  id=base-scoutlocal-b15
  rec=$(make_base_case base-scoutlocal "$id" main \
    '- base-scoutlocal [local-only] - merged locally, never pushed (added 2026-09-17)')
  read_base_record "$rec"
  git -C "$PROJ_DIR" checkout -q -b integration/x origin/main
  printf 'landed locally\n' > "$PROJ_DIR/landed.txt"
  git -C "$PROJ_DIR" add landed.txt
  git -C "$PROJ_DIR" commit -qm "landed locally on the integration branch"
  git -C "$PROJ_DIR" checkout -q main

  out=$(run_base_spawn "$id" no-mistakes scout --base integration/x)
  status=$?
  expect_code 0 "$status" "a scout on a local-only project should spawn: $out"
  [ "$(head_sha "$WT_DIR")" = "$(git -C "$PROJ_DIR" rev-parse integration/x)" ] \
    || fail "scout did not start from the local integration branch (HEAD $(head_sha "$WT_DIR"))"
  pass "a scout on a local-only project starts from the local base branch"
}

# A relaunch keeps every identity axis the task was created with, and the base is
# one of them: a replacement worker must not be handed a different branch.
test_relaunch_refuses_an_explicit_base() {
  local rec id out status
  id=base-relaunch-b13
  rec=$(make_base_case base-relaunch "$id" main \
    '- base-relaunch [no-mistakes base=develop] - develop-based (added 2026-09-17)')
  read_base_record "$rec"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" --relaunch --base develop 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "--relaunch should refuse --base: $out"
  assert_contains "$out" "--base" "refusal did not name the rejected flag"
  pass "--relaunch refuses --base and keeps the task's own recorded base"
}

# A secondmate launches in its own home, not a task worktree, so it has no base.
test_secondmate_refuses_an_explicit_base() {
  local rec out status
  rec=$(make_base_case base-secondmate sm-base-b14 main \
    '- base-secondmate [no-mistakes] - secondmate refusal fixture (added 2026-09-17)')
  read_base_record "$rec"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" sm-base-b14 --secondmate --base develop 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "--secondmate should refuse --base: $out"
  assert_contains "$out" "--base" "refusal did not name the rejected flag"
  pass "--secondmate refuses --base"
}

# --- the recorded base governs landing and cleanup too ----------------------
# Recording base= would be theatre if the landing path ignored it: a local-only
# task dispatched against an integration branch would have bin/fm-merge-local.sh
# fast-forward the project's STANDING branch over every commit the effort has
# accumulated, which is precisely the one-merge-checked-as-a-whole rule the flag
# exists to keep.
# make_landing_case <name> <id> <branch-the-task-was-built-on> [base=<branch>]:
# a local-only project with main plus an integration branch, a task worktree
# holding one commit on top of <branch-the-task-was-built-on>, and the project
# checkout left on that branch so the landing can fast-forward it. Extra args
# are appended to the task's meta. Prints home|project|worktree.
make_landing_case() {
  local name=$1 id=$2 on=$3
  shift 3
  local dir home proj wt
  dir="$TMP_ROOT/landing/$name"
  home="$dir/home"
  proj="$dir/projects/$name"
  wt="$dir/projects/$id"
  mkdir -p "$home/state" "$home/data" "$home/config" "$dir/projects"
  fm_git_init_commit "$proj"
  git -C "$proj" branch integration/x main
  git -C "$proj" worktree add --quiet -b "fm/$id" "$wt" "$on"
  printf 'effort work\n' > "$wt/effort.txt"
  git -C "$wt" add effort.txt
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'effort work'
  git -C "$proj" checkout -q "$on"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$proj" "kind=ship" "mode=local-only" "spawn_gen=fixture-$id" "$@"
  printf '%s|%s|%s\n' "$home" "$proj" "$wt"
}

run_local_merge() {  # <home> <id>
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    FM_DATA_OVERRIDE="$1/data" FM_CONFIG_OVERRIDE="$1/config" \
    "$ROOT/bin/fm-merge-local.sh" "$2" 2>&1
}

test_local_merge_lands_on_the_tasks_recorded_base() {
  local rec home proj wt id out status main_before
  id=base-landing-b16
  rec=$(make_landing_case base-landing "$id" integration/x "base=integration/x")
  IFS='|' read -r home proj wt <<EOF
$rec
EOF
  main_before=$(git -C "$proj" rev-parse main)

  out=$(run_local_merge "$home" "$id")
  status=$?
  expect_code 0 "$status" "the local landing should fast-forward the task's recorded base: $out"
  [ "$(git -C "$proj" rev-parse integration/x)" = "$(git -C "$wt" rev-parse HEAD)" ] \
    || fail "the task's recorded base branch did not receive the work"
  [ "$(git -C "$proj" rev-parse main)" = "$main_before" ] \
    || fail "the landing moved the project's standing branch instead of the task's base"
  pass "a local-only task lands on the base it was created against, not the standing one"
}

# A task dispatched without --base owns no base, so its landing keeps resolving
# the project's CURRENT declaration - which is free to change under an in-flight
# task. Freezing the target at spawn time would leave such a task landable only
# by hand-editing its record.
test_local_merge_without_a_recorded_base_follows_the_declaration() {
  local rec home proj wt id out status
  id=base-nolanding-b17
  rec=$(make_landing_case base-nolanding "$id" integration/x)
  IFS='|' read -r home proj wt <<EOF
$rec
EOF
  # The project adopts the branch the task happens to sit on, after the task was
  # dispatched: the landing must follow that, not anything recorded at spawn.
  git -C "$proj" checkout -q main
  printf 'integration/x\n' > "$proj/.firstmate-base"
  git -C "$proj" add .firstmate-base
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'declare integration/x'
  git -C "$proj" checkout -q integration/x

  out=$(run_local_merge "$home" "$id")
  status=$?
  expect_code 0 "$status" "a task with no recorded base should land on the project's current declaration: $out"
  [ "$(git -C "$proj" rev-parse integration/x)" = "$(git -C "$wt" rev-parse HEAD)" ] \
    || fail "the declared branch did not receive the work"
  pass "a task dispatched without --base lands on the project's current declaration"
}

# A recorded branch that has since disappeared is a reason to fall back to the
# project's current declaration, not to refuse forever: refusing there strands
# the work with no command that lands it.
test_local_merge_falls_back_when_the_recorded_base_is_gone() {
  local rec home proj wt id out status
  id=base-gonebase-b18
  rec=$(make_landing_case base-gonebase "$id" main "base=integration/gone")
  IFS='|' read -r home proj wt <<EOF
$rec
EOF

  out=$(run_local_merge "$home" "$id")
  status=$?
  expect_code 0 "$status" "a vanished recorded base should fall back to the standing one: $out"
  [ "$(git -C "$proj" rev-parse main)" = "$(git -C "$wt" rev-parse HEAD)" ] \
    || fail "the standing branch did not receive the work after the recorded base vanished"
  pass "a landing whose recorded base has vanished falls back to the project's standing base"
}

# CI's stock macOS Bash lane sets FM_TEST_ONLY to run just the resolver's
# bash-3.2 regression. The rest of this file is not a 3.2 snapshot suite.
if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

test_registry_parse_is_backward_compatible
test_recorded_base_is_checked_out
test_unconfirmable_base_is_refused
test_default_base_passes_assertion
test_unregistered_project_spawns_as_today
test_missing_base_branch_is_refused
test_local_only_prefers_local_branch
test_scout_also_starts_from_the_recorded_base
test_explicit_base_beats_the_registry
test_explicit_base_is_not_written_back
test_registry_base_applies_without_the_flag
test_unresolvable_explicit_base_refuses
test_scout_accepts_an_explicit_base
test_scout_on_a_local_only_project_uses_the_local_branch
test_relaunch_refuses_an_explicit_base
test_secondmate_refuses_an_explicit_base
test_local_merge_lands_on_the_tasks_recorded_base
test_local_merge_without_a_recorded_base_follows_the_declaration
test_local_merge_falls_back_when_the_recorded_base_is_gone

test_declaration_is_read_from_the_branch_that_carries_it
test_declaration_beats_the_private_registry
test_registry_is_the_fallback_when_nothing_is_declared
test_malformed_declaration_never_reaches_git
test_declaration_resolves_under_stock_bash

echo "# all fm-spawn-base-branch tests passed"
