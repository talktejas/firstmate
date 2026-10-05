#!/usr/bin/env bash
# Live driver: real bin/fm-crew-state.sh against an isolated home whose task
# "worker" has real records, read with override settings inherited from another
# command's scope. Usage: drive-crew-state.sh <checkout-root> <label>
set -u
ROOT=$1; LABEL=$2
D=$(mktemp -d /tmp/fm-crew-live.XXXXXX); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/state" "$D/wt" "$D/capture" "$D/other"
git -C "$D/wt" init -q -b fm/no-gate; git -C "$D/wt" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m init
printf 'window=fm:fm-worker\nworktree=%s\nkind=ship\nharness=claude\n' "$D/wt" > "$D/state/worker.meta"
printf 'working: implementation continues\n' > "$D/state/worker.status"
cp "$D/state/worker.meta" "$D/capture/worker.meta"; printf 'working: captured generation\n' > "$D/capture/worker.status"
cp "$D/state/worker.meta" "$D/other/b2b.meta"; printf 'working: some other task\n' > "$D/other/b2b.status"
run() {  # <title> [NAME=value...]
  local title=$1; shift
  echo "-- $title"
  ( for a in "$@"; do export "${a?}"; done
    FM_STATE_OVERRIDE="$D/state" timeout 60 "$ROOT/bin/fm-crew-state.sh" worker 2>"$D/err" | sed 's/^/   stdout: /'
    sed "s|$D|<home>|g; s/^/   stderr: /" "$D/err" )
}
echo "== [$LABEL] fm-crew-state.sh worker"
run "clean environment"
run "inherited pair naming another task in a snapshot dir that is gone (the reported shape)" \
  FM_CREW_STATE_META_OVERRIDE=/tmp/fm-fleet-tasks.gone/b2b.meta FM_CREW_STATE_STATUS_OVERRIDE=/tmp/fm-fleet-tasks.gone/b2b.status
run "adversarial: inherited pair naming another task whose files EXIST" \
  FM_CREW_STATE_META_OVERRIDE="$D/other/b2b.meta" FM_CREW_STATE_STATUS_OVERRIDE="$D/other/b2b.status"
run "adversarial: only the metadata half inherited, for this task" FM_CREW_STATE_META_OVERRIDE="$D/capture/worker.meta"
run "adversarial: only the status half inherited" FM_CREW_STATE_STATUS_OVERRIDE=/tmp/fm-fleet-tasks.gone/b2b.status
run "fleet snapshot's own captured pair for this task (must still be honored)" \
  FM_CREW_STATE_META_OVERRIDE="$D/capture/worker.meta" FM_CREW_STATE_STATUS_OVERRIDE="$D/capture/worker.status"
