#!/usr/bin/env bash
# Manual end-to-end drive of the spawn refusal + teardown deadlock scenarios.
# Usage: drive.sh <repo-root> <label> <outdir>
set -u
REPO=$1; LABEL=$2; OUT=$3
mkdir -p "$OUT"
. "$REPO/tests/fixtures.sh"
ROOT=$REPO
TMP_ROOT=$(fm_test_tmproot "fmdrive-$LABEL")

banner() { printf '\n===== %s =====\n' "$1"; }

# ---------- S1: a claim force-released while the record is live ----------
s1() {
  local id=drive-s1 case_dir home proj wt log fakebin out status
  case_dir="$TMP_ROOT/s1"; home="$case_dir/home"; proj="$case_dir/project"
  wt="$case_dir/slot"; log="$case_dir/treehouse.log"
  mkdir -p "$case_dir"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_fake_sleep_noop "$fakebin"
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" slot-s1
  fm_test_spawn_brief "$home" "$id" "drive s1"
  : > "$log"
  # The live neighbour: it still names this copy AND holds its own pool claim,
  # which an operator then force-released with the printed recovery command.
  fm_write_meta "$home/state/neighbour-s1.meta" \
    "worktree=$wt" "project=$proj" "kind=ship" "backend=tmux" \
    "worktree_lease=fm:neighbour-s1@$home/state"
  out=$(FM_TREEHOUSE_LOG="$log" FM_FAKE_LEASE_PATH="$wt" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
  status=$?
  banner "S1 force-released claim: spawn exit=$status"
  printf '%s\n' "$out"
  if [ -e "$home/state/$id.meta" ]; then
    echo "[drive] OUTCOME: spawn LAUNCHED into the copy neighbour-s1 still names (record published)"
  else
    echo "[drive] OUTCOME: spawn refused; no record published for $id"
  fi
}

# ---------- S2: the live record lives in another local Firstmate home ----------
s2() {
  local id=drive-s2 case_dir home proj wt log fakebin out status parent
  case_dir="$TMP_ROOT/s2"; home="$case_dir/home"; proj="$case_dir/project"
  wt="$case_dir/slot"; log="$case_dir/treehouse.log"
  mkdir -p "$case_dir"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_fake_sleep_noop "$fakebin"
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" slot-s2
  fm_test_spawn_brief "$home" "$id" "drive s2"
  : > "$log"
  parent="$case_dir/parent-home"
  mkdir -p "$parent/state" "$parent/data"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$home/.fm-secondmate-parent"
  printf -- '- mate - fixture (home: %s; scope: fixture; projects: sample; added 2026-09-20)\n' \
    "$home" > "$parent/data/secondmates.md"
  fm_write_meta "$parent/state/neighbour-s2.meta" \
    "worktree=$wt" "project=$proj" "kind=ship" "backend=tmux"
  out=$(FM_TREEHOUSE_LOG="$log" FM_FAKE_LEASE_PATH="$wt" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
  status=$?
  banner "S2 record in another local home: spawn exit=$status"
  printf '%s\n' "$out"
  if [ -e "$home/state/$id.meta" ]; then
    echo "[drive] OUTCOME: spawn LAUNCHED into the copy the parent home's record still names"
  else
    echo "[drive] OUTCOME: spawn refused; no record published for $id"
  fi
}

# ---------- S3: a registered home that cannot be read (fail-closed) ----------
s3() {
  local id=drive-s3 case_dir home proj wt log fakebin out status
  case_dir="$TMP_ROOT/s3"; home="$case_dir/home"; proj="$case_dir/project"
  wt="$case_dir/slot"; log="$case_dir/treehouse.log"
  mkdir -p "$case_dir"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_fake_sleep_noop "$fakebin"
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" slot-s3
  fm_test_spawn_brief "$home" "$id" "drive s3"
  : > "$log"
  printf -- '- ghost - fixture (home: %s; scope: fixture; projects: sample; added 2026-09-20)\n' \
    "$home/gone" > "$home/data/secondmates.md"
  out=$(FM_TREEHOUSE_LOG="$log" FM_FAKE_LEASE_PATH="$wt" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
  status=$?
  banner "S3 unreadable registered home: spawn exit=$status"
  printf '%s\n' "$out"
  echo "--- treehouse log (tabs shown as | ) ---"
  tr '\037' '|' < "$log"
  if [ -e "$home/state/$id.meta" ]; then
    echo "[drive] OUTCOME: spawn LAUNCHED despite an unreadable registered home"
  else
    echo "[drive] OUTCOME: spawn refused; no record published for $id"
  fi
}

case "${DRIVE_ONLY:-all}" in
  s1) s1 ;;
  s2) s2 ;;
  s3) s3 ;;
  *) s1; s2; s3 ;;
esac
