#!/usr/bin/env bash
# Live driver: reproduces the jt-mfg-module-plan case in an isolated FM_HOME.
# Usage: drive-pruned-calls.sh <firstmate-root>
set -u
SRC=$1
. "$SRC/tests/lib.sh"
ROOT=$SRC
TASKS_AXI_BIN=$(command -v tasks-axi)
T=$(mktemp -d /tmp/fm-drive.XXXXXX)
mk() { local h="$T/$1"; mkdir -p "$h/data" "$h/state" "$h/config" "$h/projects"
  cp "$ROOT/.tasks.toml" "$h/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$h/data/backlog.md"
  fb=$(fm_fakebin "$h"); fm_fake_exit0 "$fb" tmux no-mistakes gh gh-axi; fm_test_fake_treehouse_lease "$fb"; echo "$h"; }
cap() { local h=$1; shift; echo "\$ fm-captain-hold.sh $*"; PATH="$h/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" FM_CONFIG_OVERRIDE="$h/config" "$ROOT/bin/fm-captain-hold.sh" "$@" 2>&1; echo "[exit $?]"; }
td() { local h=$1; echo "\$ fm-teardown.sh $2"; PATH="$h/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" FM_CONFIG_OVERRIDE="$h/config" "$ROOT/bin/fm-teardown.sh" "$2" 2>&1 | tail -3; echo "[exit ${PIPESTATUS[0]}]"; }
tx() { local h=$1; shift; echo "\$ tasks-axi $*"; (cd "$h" && PATH="$h/fakebin:$PATH" FM_HOME="$h" tasks-axi "$@" 2>&1 | head -4); }
scout() { local h=$1 id=$2; mkdir -p "$h/data/$id"
  (cd "$h" && tasks-axi add "$id" "Plan module" --kind scout --repo sample --start >/dev/null)
  fm_write_meta "$h/state/$id.meta" "window=firstmate:fm-$id" "worktree=$h/projects/missing-$id" "project=$h/projects/sample" "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$h/state/$id.status"; printf '# Plan\n\nDone.\n' > "$h/data/$id/report.md"; }
hold() { cap "$1" hold "$2" --title "Decide $2" --reason "captain must choose" --repo sample >/dev/null; }
ans() { printf 'Captain chose option A for %s.\n' "$2" > "$1/ans-$2.txt"; cap "$1" answer "$2" --decision-file "$1/ans-$2.txt"; }
S=jt-mfg-module-plan; P="jt-mfg-karigar-wage-metal jt-mfg-mould-in-house jt-mfg-mould-ownership"; K="jt-mfg-stone-setting jt-mfg-polish-line"

echo "===== SCENARIO 1: three answered calls pruned; verify + teardown ====="
h=$(mk s1); scout "$h" $S; for c in $P $K; do hold "$h" $c; done
cap "$h" complete $S $P $K
for c in $P; do ans "$h" $c; done
tx "$h" prune --keep 0
for c in $P; do tx "$h" show $c; done
for c in $K; do ans "$h" $c; done
grep decision_keys "$h/state/$S.meta" | tail -1
ls "$h/state/captain-hold-resolutions" 2>&1; cat "$h/state/captain-hold-resolutions/jt-mfg-mould-in-house.receipt" 2>&1
cap "$h" verify $S
td "$h" $S

echo; echo "===== SCENARIO 2: id that was never answered (no receipt) still refuses ====="
h=$(mk s2); scout "$h" $S; hold "$h" jt-mfg-real-call
cap "$h" complete $S jt-mfg-real-call; ans "$h" jt-mfg-real-call
printf 'decision_keys=jt-mfg-real-call,jt-mfg-typo-call\n' >> "$h/state/$S.meta"
cap "$h" verify $S
td "$h" $S

echo; echo "===== SCENARIO 3: forged/malformed receipt does not satisfy verify ====="
h=$(mk s3); scout "$h" $S; hold "$h" jt-mfg-a; cap "$h" complete $S jt-mfg-a >/dev/null; ans "$h" jt-mfg-a
mkdir -p "$h/state/captain-hold-resolutions"
printf 'schema=fm-captain-hold-resolution.v1\nid=jt-mfg-other\nmode=answered\ndecision_digest=%064d\n' 0 > "$h/state/captain-hold-resolutions/jt-mfg-forged.receipt"
printf 'schema=fm-captain-hold-resolution.v1\nid=jt-mfg-baddigest\nmode=answered\ndecision_digest=nothex\n' > "$h/state/captain-hold-resolutions/jt-mfg-baddigest.receipt"
printf 'decision_keys=jt-mfg-a,jt-mfg-forged\n' >> "$h/state/$S.meta"; cap "$h" verify $S
printf 'decision_keys=jt-mfg-a,jt-mfg-baddigest\n' >> "$h/state/$S.meta"; cap "$h" verify $S

echo; echo "===== SCENARIO 4: pre-change pruned calls (no receipts) repaired via corrected complete ====="
h=$(mk s4); scout "$h" $S; for c in $P $K; do hold "$h" $c; done
cap "$h" complete $S $P $K >/dev/null; for c in $P; do ans "$h" $c >/dev/null; done
rm -rf "$h/state/captain-hold-resolutions"   # simulate answers recorded before receipts existed
tx "$h" prune --keep 0 >/dev/null; for c in $K; do ans "$h" $c >/dev/null; done
cap "$h" verify $S
cap "$h" complete $S $K
cap "$h" complete $S --repair-reason "answered and pruned before receipts existed" $K
grep -E 'decision_keys|decision_repair' "$h/state/$S.meta" | tail -2
cap "$h" verify $S
td "$h" $S

echo; echo "===== SCENARIO 5: trailing --none after ids is refused, inventory untouched ====="
h=$(mk s5); scout "$h" $S; hold "$h" jt-mfg-x; cap "$h" complete $S jt-mfg-x >/dev/null
cap "$h" complete $S jt-mfg-x --none
cap "$h" complete $S --none jt-mfg-x
grep decision_keys "$h/state/$S.meta" | tail -1

echo; echo "===== SCENARIO 6: re-held call accepts a second different answer ====="
h=$(mk s6); hold "$h" jt-mfg-re; ans "$h" jt-mfg-re
tx "$h" reopen jt-mfg-re >/dev/null; cap "$h" hold jt-mfg-re --reason "choose again" >/dev/null
printf 'Switch to option B.\n' > "$h/b.txt"; cap "$h" answer jt-mfg-re --decision-file "$h/b.txt"
(cd "$h" && tasks-axi show jt-mfg-re --full 2>&1 | grep -E 'state:|option B' | head -3)
cat "$h/state/captain-hold-resolutions/jt-mfg-re.receipt"
rm -rf "$T"
