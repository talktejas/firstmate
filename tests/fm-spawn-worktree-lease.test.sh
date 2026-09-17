#!/usr/bin/env bash
# Regression test for the worktree claim fm-spawn.sh takes on a pool slot
# (bin/fm-spawn.sh, the `treehouse get --lease` branch).
#
# Treehouse counts a slot as in use only while a process runs inside it, so a
# task whose agent has exited - paused, crashed, or between turns - leaves its
# own working copy looking free, and the next spawn was handed that copy and
# reset it (observed 2026-08-19, silently, with no refusal). fm-spawn therefore
# takes the pool's own durable claim on the slot instead of relying on the
# pane's subshell to hold it, and labels the lease with the task record that
# owns it so a lease outliving its task can be identified and released.
#
# The three things that must hold: the claim is taken and labelled, an aborted
# spawn gives it straight back, and a live claim really does keep the pool from
# handing the same copy to the next get.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-lease)
SEP=$'\x1f'

# make_lease_case <name> <id> -> case record; leaves LEASE_* globals set.
make_lease_case() {
  local name=$1 id=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  LEASE_HOME="$case_dir/home"
  LEASE_PROJ="$case_dir/project"
  LEASE_WT="$case_dir/slot"
  LEASE_LOG="$case_dir/treehouse.log"
  mkdir -p "$case_dir"
  LEASE_FAKEBIN=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_fake_sleep_noop "$LEASE_FAKEBIN"
  fm_test_spawn_home "$LEASE_HOME" codex
  fm_git_worktree "$LEASE_PROJ" "$LEASE_WT" "slot-$name"
  fm_test_spawn_brief "$LEASE_HOME" "$id" "Exercise the pool claim for $id."
  : > "$LEASE_LOG"
}

run_lease_spawn() {  # <id> <pane-path>
  local id=$1 pane=$2
  FM_TREEHOUSE_LOG="$LEASE_LOG" FM_FAKE_LEASE_PATH="$LEASE_WT" \
    fm_test_run_spawn "$LEASE_HOME" "$pane" "$LEASE_FAKEBIN" \
    "$id" "$LEASE_PROJ" --mode no-mistakes --yolo off
}

# The claim itself: a durable lease, labelled with the task record that owns it
# so the label alone says which record to look for when a lease outlives its
# task.
test_spawn_claims_the_slot_with_a_labelled_lease() {
  local id out status
  id=lease-claim-w1
  make_lease_case lease-claim "$id"

  out=$(run_lease_spawn "$id" "$LEASE_WT")
  status=$?
  expect_code 0 "$status" "spawn should succeed"$'\n'"$out"
  assert_grep "worktree=$LEASE_WT" "$LEASE_HOME/state/$id.meta" \
    "meta did not record the leased worktree"
  assert_contains "$(cat "$LEASE_LOG")" \
    "treehouse${SEP}get${SEP}--lease${SEP}--lease-holder${SEP}fm:$id@$LEASE_HOME/state" \
    "spawn did not take a durable lease labelled with the owning task record"
  assert_not_contains "$(cat "$LEASE_LOG")" "return" \
    "a successful spawn returned the slot it had just claimed"
  pass "a spawn claims its pool slot with a lease labelled by the owning task record"
}

# The claim must not outlive a spawn that never published a record to point at
# it, and the return must be holder-matched so it can never take back a slot
# some later allocation already owns.
test_aborted_spawn_returns_its_claim() {
  local id out status log
  id=lease-abort-w2
  make_lease_case lease-abort "$id"

  # The pane never arrives in the leased copy, so the spawn refuses at the
  # deadline - after the lease was taken and before any record names it.
  out=$(run_lease_spawn "$id" "$LEASE_PROJ")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never entered the leased worktree"$'\n'"$out"
  [ ! -e "$LEASE_HOME/state/$id.meta" ] || fail "refused spawn published task metadata"
  log=$(cat "$LEASE_LOG")
  assert_contains "$log" \
    "treehouse${SEP}return${SEP}--force${SEP}--if-lease-holder${SEP}fm:$id@$LEASE_HOME/state${SEP}$LEASE_WT" \
    "an aborted spawn left its pool claim behind"
  pass "an aborted spawn returns its claim, matched on the holder that took it"
}

# The guarantee the whole fix rests on, checked against the real pool rather
# than assumed: a leased slot is not handed to a later `treehouse get`, with no
# process running inside it.
test_real_pool_does_not_hand_out_a_leased_slot() {
  local repo leased handed
  if ! command -v treehouse >/dev/null 2>&1; then
    echo "skip: treehouse not installed - cannot check the real pool's lease guarantee"
    return 0
  fi
  repo="$TMP_ROOT/real-pool/repo"
  fm_git_init_commit "$repo"
  printf 'max_trees = 16\nroot = "./"\n' > "$repo/treehouse.toml"
  git -C "$repo" add treehouse.toml
  git -C "$repo" -c user.email=fm@test -c user.name=fm commit -qm 'pool config'
  leased=$(cd "$repo" && treehouse get --lease --lease-holder 'fm:pool-guarantee@state' 2>/dev/null) \
    || fail "real treehouse could not lease a worktree"
  [ -n "$leased" ] || fail "real treehouse leased no worktree"
  # Nothing is running inside the leased slot, which is exactly the state that
  # made a live task's copy look free before it was claimed. The pool lives
  # under the fixture repo, so it is removed with the temp root.
  handed=$(cd "$repo" && printf 'pwd -P\nexit\n' | treehouse get 2>/dev/null | grep '^/' | tail -1)
  [ -n "$handed" ] || fail "real treehouse handed out no worktree at all"
  [ "$handed" != "$leased" ] || fail "real treehouse handed out the leased, idle slot"
  pass "the real pool does not hand out a leased slot that has no process inside it"
}

test_spawn_claims_the_slot_with_a_labelled_lease
test_aborted_spawn_returns_its_claim
test_real_pool_does_not_hand_out_a_leased_slot

echo "# all fm-spawn-worktree-lease tests passed"
