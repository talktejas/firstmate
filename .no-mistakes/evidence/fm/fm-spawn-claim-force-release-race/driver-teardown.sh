#!/usr/bin/env bash
# Drive the 2026-09-20 deadlock: two task records naming one pool copy.
# Usage: drive-teardown.sh <repo-root> <label>
set -u
REPO=$1; LABEL=$2
cut=$(grep -n '^test_[a-z0-9_]*$' "$REPO/tests/fm-teardown.test.sh" | head -1 | cut -d: -f1)
rdir=/tmp/fmdrive/root-$LABEL
rm -rf "$rdir"; mkdir -p "$rdir"
cp -r "$REPO/tests" "$rdir/tests"
ln -s "$REPO/bin" "$rdir/bin"
mkdir -p "$rdir/state"
helpers=$rdir/tests/helpers.sh
sed -n "1,$((cut - 1))p" "$REPO/tests/fm-teardown.test.sh" > "$helpers"
. "$helpers"
TEARDOWN="$rdir/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot "fmdrive-td-$LABEL")

run_td() {  # <case-dir> <task-id>
  local case_dir=$1 id=$2; shift 2
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" "$TEARDOWN" "$id" "$@" 2>&1
}

case_dir=$(make_case deadlock)
mkdir -p "$case_dir/pool/slot-1"
printf '{}\n' > "$case_dir/pool/treehouse-state.json"
WT="$case_dir/pool/slot-1/copy"
git -C "$case_dir/project" worktree add -q -b fm/deadlock "$WT" main
for t in task-x1 task-x2; do
  fm_write_meta "$case_dir/state/$t.meta" \
    "window=firstmate:fm-$t" "endpoint_task_id=$t" "worktree=$WT" \
    "project=$case_dir/project" "kind=ship" "mode=no-mistakes" "spawn_gen=drive-$t"
done
# The pool slot's own owner claim names task-x2: task-x2 is the task that
# actually took the slot, so task-x1's record is the stale one.
printf 'task=%s\nhome=%s\n' task-x2 "$case_dir" > "$case_dir/pool/slot-1/.fm-slot-owner"
printf '%s\n' "work belonging to the slot's real owner" > "$WT/feature.txt"

echo "=== records before ==="; ls "$case_dir/state"
echo; echo "=== teardown task-x1 (the record the slot claim disowns) ==="
out=$(run_td "$case_dir" task-x1); rc=$?
printf '%s\n' "$out"; echo "[drive] exit=$rc"
echo "[drive] records now: $(ls "$case_dir/state" | tr '\n' ' ')"
echo "[drive] owner's uncommitted file still present: $([ -f "$WT/feature.txt" ] && echo yes || echo NO)"

# The owner has since landed its work; clear the copy so the second teardown
# is judged only on the collision, not on the ordinary unlanded-work guard.
rm -f "$WT/feature.txt"
echo; echo "=== teardown task-x2 (the slot's real owner), after x1 retired ==="
out=$(run_td "$case_dir" task-x2); rc=$?
printf '%s\n' "$out"; echo "[drive] exit=$rc"
echo "[drive] records now: [$(ls "$case_dir/state" | tr '\n' ' ')]"
