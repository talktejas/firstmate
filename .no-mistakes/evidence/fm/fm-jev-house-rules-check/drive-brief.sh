#!/usr/bin/env bash
# Drives bin/fm-brief.sh and bin/fm-promote.sh in throwaway homes, then runs the
# exact command the generated brief hands a worker. Reuses the scratch dir and
# fake curl from drive-check.sh (only the network edge is replaced).
set -u
WT=/home/tds/.no-mistakes/worktrees/3605d2c32b02/01M46J2PSMGGGB0MBZ2671F1AN
T=$1; export HR_T=$T
unset TYPESAFE_API_KEY FM_HOME FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE
KEY=drive-key-4411-not-real
say() { printf '\n===== %s =====\n' "$*"; }
tidy() { sed "s#$WT/##g; s#$WT#<worktree>#g; s#$T#\$T#g"; }
dod() { sed -n '/^# Definition of done/,/^# /p' "$1" | sed '$d'; }

BASE=$T/base-f6a10db; mkdir -p $BASE
git -C $WT archive f6a10dba31dccd723224f4c7aefc24a9359a517b | tar -x -C $BASE

say "B1 shipped default (no config/house-rules.json, key present): brief identical to the base commit's"
for mode in no-mistakes direct-PR local-only; do
  rm -rf $T/home-keyonly/data $T/home-base/data; mkdir -p $T/home-base; cp $T/home-keyonly/.env $T/home-base/.env
  FM_HOME=$T/home-keyonly $WT/bin/fm-brief.sh t-$mode shop --mode $mode >/dev/null 2>&1 || echo "HEAD brief failed"
  FM_HOME=$T/home-base $BASE/bin/fm-brief.sh t-$mode shop --mode $mode >/dev/null 2>&1 || echo "base brief failed"
  a=$(sed "s#$WT#ROOT#g; s#$T/home-keyonly#HOME#g" $T/home-keyonly/data/t-$mode/brief.md | sha256sum | cut -c1-16)
  b=$(sed "s#$BASE#ROOT#g; s#$T/home-base#HOME#g" $T/home-base/data/t-$mode/brief.md | sha256sum | cut -c1-16)
  [ "$a" = "$b" ] && r=IDENTICAL || r=DIFFERENT
  printf '%-12s HEAD %s  base %s  %s  (house-rules mentions in HEAD brief: %s)\n' $mode $a $b $r "$(grep -c 'house-rule' $T/home-keyonly/data/t-$mode/brief.md)"
done

say "B2 opted-in project with key: each ship mode's definition of done gains the step"
for mode in no-mistakes direct-PR local-only; do
  FM_HOME=$T/home-on $WT/bin/fm-brief.sh on-$mode shop --mode $mode >/dev/null 2>&1 || echo "brief failed"
  echo "--- $mode ---"; dod $T/home-on/data/on-$mode/brief.md | tidy
done

say "B3 same home, other cases: no step"
FM_HOME=$T/home-on $WT/bin/fm-brief.sh other-1 not-shop --mode direct-PR >/dev/null 2>&1
echo "project not in list:      $(grep -c 'house-rule' $T/home-on/data/other-1/brief.md) mentions"
FM_HOME=$T/home-opted-nokey $WT/bin/fm-brief.sh nokey-1 shop --mode direct-PR >/dev/null 2>&1
echo "opted in, no key:         $(grep -c 'house-rule' $T/home-opted-nokey/data/nokey-1/brief.md) mentions"
FM_HOME=$T/home-on $WT/bin/fm-brief.sh scout-1 shop --scout >/dev/null 2>&1
echo "scout brief (opted in):   $(grep -c 'house-rule' $T/home-on/data/scout-1/brief.md) mentions"

say "B4 a worker pastes the brief's command in the task worktree"
cmd=$(grep -o 'run `FM_HOME=[^`]*`' $T/home-on/data/on-direct-PR/brief.md | sed 's/^run `//; s/`$//')
printf '$ %s\n' "$cmd" | tidy
rm -rf "$T/log"; mkdir -p "$T/log"
(cd $T/shop && PATH="$T/fakebin:$PATH" bash -c "$cmd"; echo "[exit $?]") 2>&1 | tidy

say "B5 adversarial: a home whose path has a space and a quote"
H="$T/my home's dir"; mkdir -p "$H/config"; printf 'TYPESAFE_API_KEY=%s\n' $KEY > "$H/.env"; echo '{"projects": ["shop"]}' > "$H/config/house-rules.json"
FM_HOME="$H" $WT/bin/fm-brief.sh sp-1 shop --mode local-only >/dev/null 2>&1 || echo "brief failed"
cmd=$(grep -o 'run `FM_HOME=[^`]*`' "$H/data/sp-1/brief.md" | sed 's/^run `//; s/`$//')
printf '$ %s\n' "$cmd" | tidy
rm -rf "$T/log"; mkdir -p "$T/log"
(cd $T/shop && PATH="$T/fakebin:$PATH" bash -c "$cmd"; echo "[exit $?]") 2>&1 | tidy

say "B6 promoting a scout: ship instructions carry the step, matched by the recorded project path's name"
promote() {  # <home> <id> <project-path>
  local home=$1 id=$2 brief content
  mkdir -p "$home/state"
  FM_HOME="$home" $WT/bin/fm-brief.sh "$id" shop --scout >/dev/null 2>&1
  brief="$home/data/$id/brief.md"; content=$(cat "$brief")
  content=${content//'{TASK}'/'Investigate the commission rate.'}; content=${content//'{FIRSTMATE_SPEC}'/'Report findings only.'}
  printf '%s\n' "$content" > "$brief"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt-%s\nproject=%s\n' "$id" "$id" "$3" > "$home/state/$id.meta"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" $WT/bin/fm-promote.sh "$id" --mode direct-PR --yolo off >/dev/null 2>&1 || echo "promote failed"
}
promote $T/home-on pr-1 /srv/projects/shop
echo "--- opted in (project=/srv/projects/shop) ---"; dod $T/home-on/data/pr-1/ship-instructions.md | tidy
promote $T/home-on pr-2 /srv/projects/not-shop
echo "--- not opted in (project=/srv/projects/not-shop): $(grep -c 'house-rule' $T/home-on/data/pr-2/ship-instructions.md) mentions"
promote $T/home-keyonly pr-3 /srv/projects/shop
echo "--- key alone (no config): $(grep -c 'house-rule' $T/home-keyonly/data/pr-3/ship-instructions.md) mentions"
