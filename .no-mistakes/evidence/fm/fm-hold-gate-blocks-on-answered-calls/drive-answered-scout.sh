#!/usr/bin/env bash
# Live driver: reproduce the jt-mfg-module-plan case against a checkout ($1).
set -u
ROOT=$(cd "$1" && pwd)
. "$ROOT/tests/lib.sh"
TASKS_AXI_BIN=$(command -v tasks-axi)
home=$(mktemp -d /tmp/fm-live-answered.XXXXXX)
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
fakebin=$(fm_fakebin "$home"); fm_fake_exit0 "$fakebin" tmux no-mistakes gh gh-axi
fm_test_fake_treehouse_lease "$fakebin"
env_run() { PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$@"; }
cap() { echo "\$ fm-captain-hold.sh $*"; env_run "$ROOT/bin/fm-captain-hold.sh" "$@" 2>&1; echo "[exit $?]"; }
keys() { echo "  meta: $(grep '^decision_keys=' "$home/state/$id.meta" | tail -1)"; }
id=jt-mfg-module-plan
calls=(jt-mfg-karigar-wage-metal jt-mfg-mould-in-house jt-mfg-mould-ownership jt-mfg-open-one jt-mfg-open-two)
mkdir -p "$home/data/$id"
(cd "$home" && tasks-axi add "$id" "Manufacturing module plan" --kind scout --repo sample --start >/dev/null)
fm_write_meta "$home/state/$id.meta" "window=firstmate:fm-$id" "worktree=$home/projects/missing-$id" \
  "project=$home/projects/sample" harness=codex kind=scout mode=scout "spawn_gen=fixture-$id"
printf 'done: report complete\n' > "$home/state/$id.status"
printf '# Plan\n\nDone.\n' > "$home/data/$id/report.md"
for c in "${calls[@]}"; do env_run "$ROOT/bin/fm-captain-hold.sh" hold "$c" --title "Decide $c" --reason "captain must decide" --repo sample >/dev/null; done
echo "== 1. scout attests its five captain calls"; cap complete "$id" "${calls[@]}"; keys
printf 'Captain decided.\n' > "$home/answer.txt"
echo "== 2. captain answers three of them"
for c in "${calls[@]:0:3}"; do cap answer "$c" --decision-file "$home/answer.txt" | tail -1; done
echo "== 3. verify with three answered + two still held"; cap verify "$id"
echo "== 4. ADVERSARIAL: corrective complete that silently drops a still-open call"; cap complete "$id" jt-mfg-open-one; keys
echo "== 5. ADVERSARIAL: --none while two calls still unanswered"; cap complete "$id" --none; keys
echo "== 6. corrective complete with only the still-open ids"; cap complete "$id" jt-mfg-open-one jt-mfg-open-two; keys
echo "== 7. verify after replacement"; cap verify "$id"
echo "== 8. teardown of the finished scout"
env_run "$ROOT/bin/fm-teardown.sh" "$id" >"$home/td.out" 2>&1; echo "[exit $?]"; tail -5 "$home/td.out"
echo "== 9. held calls survive teardown, still captain-held in backlog"
(cd "$home" && tasks-axi show jt-mfg-open-one 2>&1 | head -8)
rm -rf "$home"
