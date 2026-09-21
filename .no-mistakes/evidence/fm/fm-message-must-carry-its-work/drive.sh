#!/usr/bin/env bash
# Live driver: isolated FM_HOME, real bin/ scripts.
set -u
ROOT=/home/tds/.no-mistakes/worktrees/3605d2c32b02/01M31FJKN7BGB68R73FKE7QJET
T=$(mktemp -d /tmp/fmcc-live.XXXX); H=$T/home; mkdir -p $H/state $H/data
export CLAUDE_CONFIG_DIR=$T/claude
LOG=$H/data/captain-messages.jsonl
REC="env FM_HOME=$H FM_ROOT_OVERRIDE=$ROOT $ROOT/bin/fm-captain-message.sh"
for n in alpha beta; do git init -q $T/wt-$n; git -C $T/wt-$n checkout -q -b fm/$n-fix; done
printf 'project=/home/captain/p/alpha\nworktree=%s\n' $T/wt-alpha > $H/state/cc-alpha.meta
printf 'project=/home/captain/p/beta\nworktree=%s\n'  $T/wt-beta  > $H/state/cc-beta.meta
echo "### S1 hand record with neither --task nor --general"
$REC --title "Status" "About some work."; echo "exit=$?"
echo "### S2 hand record --task with no state/<id>.meta (typo)"
$REC --title "Status" --task cc-alpah "About alpha."; echo "exit=$?"
echo "### S3 hand record --task and --general together"
$REC --title "Status" --task cc-alpha --general "x"; echo "exit=$?"
echo "log lines after refusals: $(cat $LOG 2>/dev/null | wc -l)"
echo "### S4 hand record --task cc-alpha"
$REC --title "Alpha PR up" --task cc-alpha "The alpha fix PR is up."; echo "exit=$?"
echo "### S5 hand record --general"
$REC --title "Morning" --general "Good morning, nothing waiting."; echo "exit=$?"
jq -c '{title,task,project,worktree,branch}' $LOG
# transcript: 4 turns
TD=$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$H" | sed 's/[^A-Za-z0-9]/-/g'); mkdir -p $TD; TR=$TD/sess.jsonl
P='{"type":"user","sessionId":"s","message":{"role":"user","content":"hi"}}'
tu(){ jq -cn --arg r "$1" --arg c "$2" '{type:"assistant",requestId:$r,sessionId:"s",timestamp:"2026-09-21T10:00:00Z",message:{role:"assistant",stop_reason:"tool_use",content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}'; }
fin(){ jq -cn --arg r "$1" --arg t "$2" '{type:"assistant",requestId:$r,sessionId:"s",timestamp:"2026-09-21T10:00:01Z",message:{role:"assistant",model:"claude",stop_reason:"end_turn",content:[{type:"text",text:$t}]}}'; }
{ echo "$P"; tu x1 "cat state/cc-alpha.status"; fin r-one "Alpha is green, merging."
  echo "$P"; tu x2 "cat state/cc-alpha.meta state/cc-beta.meta"; fin r-two "Both look fine."
  echo "$P"; fin r-none "Nothing touched."
  echo "$P"; fin r-prose "About state/cc-beta.meta and the beta project."; } > $TR
echo "### S6 Stop-hook sweep (--from-payload) of the turn that just ended"
jq -cn --arg p $TR '{transcript_path:$p}' | python3 $ROOT/bin/fm-captain-message-sweep.py --home $H --from-payload --since 2026-09-21T00:00:00Z; echo "exit=$?"
jq -c 'select(.source=="transcript")|{req,task,project,worktree,branch}' $LOG
echo "### S7 backfill of older rows (strip context from captured rows, add legacy task-keyed row)"
jq -c 'if .source=="transcript" then .task=null|.project=null|.worktree=null|.branch=null else . end' $LOG > $LOG.tmp && mv $LOG.tmp $LOG
echo '{"id":"legacy","title":"old","text":"old","task":"cc-beta","project":null,"worktree":null,"branch":null}' >> $LOG
echo '{"id":"gone","title":"old","text":"old","task":"cc-torndown","project":null,"worktree":null,"branch":null}' >> $LOG
echo 'this is {torn' >> $LOG
python3 $ROOT/bin/fm-captain-message-backfill.py --home $H; echo "exit=$?"
jq -Rc 'fromjson? | {id:(.req//.id),task,project,worktree,branch}' $LOG
echo "### S8 backfill re-run converges"
cp $LOG $T/before; python3 $ROOT/bin/fm-captain-message-backfill.py --home $H; cmp $LOG $T/before && echo "log byte-identical after rerun"
echo "### S9 concurrent hand record while backfill holds the lock"
python3 - $H/state/.captain-message-sweep.lock <<'PY' &
import fcntl,sys,time
l=open(sys.argv[1],"w"); fcntl.flock(l,fcntl.LOCK_EX); time.sleep(3)
PY
sleep 0.5
python3 $ROOT/bin/fm-captain-message-backfill.py --home $H; echo "backfill while locked exit=$?"
t0=$(date +%s.%N); $REC --title "During lock" --task cc-beta "written while locked" >/dev/null; echo "recorder waited $(echo "$(date +%s.%N)-$t0"|bc)s then exit=$?"
wait; grep -c '"During lock"' $LOG
# race: run backfill and 20 recorder appends concurrently
for i in $(seq 1 20); do $REC --title "race $i" --general "r$i" >/dev/null & python3 $ROOT/bin/fm-captain-message-backfill.py --home $H >/dev/null & done; wait
echo "race rows present: $(grep -c '"race ' $LOG)/20"
echo "T=$T"
