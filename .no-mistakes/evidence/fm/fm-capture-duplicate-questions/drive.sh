#!/usr/bin/env bash
# Live driver: real recorder + real sweep (Stop-hook --from-payload path) on an isolated home.
set -u
ROOT=/home/tds/.no-mistakes/worktrees/3605d2c32b02/01M3K8C5430HFPD1166XW0YM0G
T=$(mktemp -d); H=$T/home; TR=$T/sess-1.jsonl
mkdir -p "$H/data" "$H/state"
printf '# Backlog\n\n## Queued\n- [ ] koin - Koin v1 (repo: koin) (kind: ship) (since 2026-09-27) (hold: encryption call) (hold-kind: captain)\n' > "$H/data/backlog.md"
ts(){ date -u -d "$1 sec" +%Y-%m-%dT%H:%M:%S.000Z; }
rec(){ FM_HOME="$H" "$ROOT/bin/fm-captain-message.sh" --title "$1" --task koin --project koin "${@:3}" "$2"; }
prompt(){ jq -cn --arg at "$1" --arg t "$2" '{type:"user",timestamp:$at,sessionId:"sess-1",message:{role:"user",content:$t}}'; }
call(){ jq -cn --arg id "$1" --arg at "$2" '{type:"assistant",requestId:("q-"+$id),timestamp:$at,sessionId:"sess-1",message:{role:"assistant",stop_reason:"tool_use",content:[{type:"tool_use",id:$id,name:"Bash",input:{command:"bin/fm-captain-message.sh --question --title T -"}}]}}'
        jq -cn --arg id "$1" --arg at "$3" --arg o "$4" '{type:"user",timestamp:$at,sessionId:"sess-1",message:{role:"user",content:[{type:"tool_result",tool_use_id:$id,content:$o}]}}'; }
reply(){ jq -cn --arg r "$1" --arg at "$2" --arg t "$3" '{type:"assistant",requestId:$r,uuid:($r+"-u"),isSidechain:false,timestamp:$at,sessionId:"sess-1",message:{role:"assistant",stop_reason:"end_turn",content:[{type:"text",text:$t}]}}'; }
hook(){ jq -cn --arg p "$TR" '{transcript_path:$p}' | python3 "$ROOT/bin/fm-captain-message-sweep.py" --home "$H" --from-payload --since 2026-01-01T00:00:00Z; }
show(){ echo "--- captain-messages.jsonl ($(wc -l <"$H/data/captain-messages.jsonl") rows)"; jq -c '{id,source:(.source//"hand"),question,question_key,req,text:(.text[0:70])}' "$H/data/captain-messages.jsonl"; }
KOIN="Koin v1 plan is ready - merge it? And one question on encryption: should the Koin store encrypt data at rest, at the cost of about 5 ms per read?"

echo "=== S1: the Koin case - question recorded by hand, same turn's reply reworded/markdown in transcript"
id=$(rec "Koin v1 plan ready - merge it, and one question on encryption" "$KOIN" --question-key koin-encrypt-at-rest); echo "recorder printed id=$id"
{ prompt "$(ts -60)" "plan?"; call c1 "$(ts -30)" "$(ts +1)" "$id"
  reply r-koin "$(ts +6)" "**Koin v1 plan is ready** - merge it?

1. And one question on encryption: should the Koin store encrypt data *at rest*, at the cost of about 5 ms per read?"; } > "$TR"
hook; show
echo "--- rerun hook + delete cursor and rerun (must stay one row)"
hook; rm -f "$H/state/.captain-message-sweep"; hook; show

echo; echo "=== S2: reply adds a new sentence (no numbers/links) -> captured beside the row"
id=$(rec "Merge?" "The review is clean and the build is green. Should I merge it now?" --question)
{ prompt "$(ts +20)" "pr?"; call c2 "$(ts -30)" "$(ts +21)" "$id"
  reply r-more "$(ts +22)" "The review is clean and the build is green. Should I merge it now?
I also paused the billing worker until you answer."; } >> "$TR"
hook; show

echo; echo "=== S3: negation / auxiliary differences -> never folded"
a=$(rec "Ship?" "I can ship the fix tonight. Go?" --question)
b=$(rec "Ship?" "I can't ship the fix tonight. Go?" --question)
c=$(rec "Merge?" "Do not merge Koin now?" --question)
d=$(rec "Merge?" "Should I merge the PR?" --question)
{ prompt "$(ts +30)" "a"; call c3 "$(ts -30)" "$(ts +31)" "$a"; reply r-cant "$(ts +32)" "I can’t ship the fix tonight. Go?"
  prompt "$(ts +33)" "b"; call c4 "$(ts -30)" "$(ts +34)" "$b"; reply r-can "$(ts +35)" "I can ship the fix tonight. Go?"
  prompt "$(ts +36)" "c"; call c5 "$(ts -30)" "$(ts +37)" "$c"; reply r-merge "$(ts +38)" "Merge Koin now?"
  prompt "$(ts +39)" "d"; call c6 "$(ts -30)" "$(ts +40)" "$d"; reply r-did "$(ts +41)" "I did merge the PR."; } >> "$TR"
hook; show

echo; echo "=== S4: recorder output suppressed (no id) - identical text written inside the turn folds; row from before the turn is captured"
e_before=$(rec "Deploy?" "Deploy the Koin API to staging now?" --question)   # written BEFORE the turn's prompt
sleep 1
P=$(ts +0); sleep 1
e=$(rec "Region?" "Which region for Koin: **eu-west** or us-east?" --question)   # written inside the turn
{ prompt "$P" "region?"; call c7 "$(ts -1)" "$(ts +1)" ""; reply r-region "$(ts +2)" "- Which region for Koin: \`eu-west\` or us-east?"
  prompt "$(ts +3)" "deploy?"; call c8 "$(ts +3)" "$(ts +4)" ""; reply r-deploy "$(ts +5)" "Deploy the Koin API to staging now?"; } >> "$TR"
hook; show
echo "S4 region row id=$e (expect no r-region); deploy row id=$e_before (expect r-deploy captured)"

echo; echo "=== S5: pre-existing duplicate rows are left alone"
cp "$H/data/captain-messages.jsonl" "$T/before"
jq -cn '{id:"m-old-hand",at:"2026-09-28T05:14:08Z",title:"old",text:"old dup",question:true}' >> "$H/data/captain-messages.jsonl"
jq -cn '{id:"c-old",at:"2026-09-28T05:14:14Z",title:"old",text:"old dup",source:"transcript",req:"r-old-dup",session:"sess-0"}' >> "$H/data/captain-messages.jsonl"
cp "$H/data/captain-messages.jsonl" "$T/withdups"
hook; rm -f "$H/state/.captain-message-sweep"; hook
cmp "$T/withdups" "$H/data/captain-messages.jsonl" && echo "log byte-identical after two more sweeps: old duplicate rows untouched"
echo "HOME=$H"
