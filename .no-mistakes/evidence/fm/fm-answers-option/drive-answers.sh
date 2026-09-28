#!/usr/bin/env bash
# Live drive of fm-captain-message.sh --answers and the sweep fold, isolated home.
set -u
R=$(pwd); H=$(mktemp -d); T=$(mktemp -d); export FM_HOME=$H
mkdir -p $H/state $H/data; printf 'project=/p/demo\n' > $H/state/cc-live.meta
rec(){ "$R/bin/fm-captain-message.sh" "$@"; }
echo "== captain drops a note via fm-inbox.sh note"
"$R/bin/fm-inbox.sh" note "Reply to message m-123 - \"Colour\": is the footer done?" 2>&1 | tail -2
echo "== fm-inbox.sh list"; "$R/bin/fm-inbox.sh" list
NID=$(ls $H/state/inbox/*.note | head -1 | xargs basename | sed 's/\.note$//'); echo "note id: $NID"
echo "== S1 answer a pending note"; A1=$(rec --title Done --task cc-live --answers "$NID" "Footer is blue now."); echo "rc=$? id=$A1"
jq -c "select(.id==\"$A1\")" $H/data/captain-messages.jsonl
echo "== S2 drain --ack moves note to handled/, answer still accepted"; "$R/bin/fm-inbox.sh" drain --ack "$NID" >/dev/null; ls $H/state/inbox/handled/
A2=$(rec --title Again --general --answers "$NID" "Also the header."); echo "rc=$? id=$A2"
echo "== S3 typo id refused"; rec --title X --general --answers 1-nope "x"; echo "rc=$?"
echo "== S3b msg-id from header refused"; rec --title X --general --answers m-123 "x"; echo "rc=$?"
echo "== S3c traversal refused"; mkdir -p $H/state/evil; : > $H/state/evil/x.note; rec --title X --general --answers ../evil/x "x"; echo "rc=$?"
echo "== S3d empty value (no id)"; rec --title X --general --answers "" "x"; echo "rc=$?"
echo "== S4 no --answers -> no field; --task/--general still required"; A4=$(rec --title Plain --general "plain msg"); jq -c "select(.id==\"$A4\") | {keys:keys, answers}" $H/data/captain-messages.jsonl
rec --title X --answers "$NID" "no task"; echo "rc=$?"
echo "== lines in log before sweep: $(wc -l < $H/data/captain-messages.jsonl)"
echo "== S5 sweep folds the transcript copy of the answer"
now(){ date -u -d "$1 sec" +%Y-%m-%dT%H:%M:%S.000Z; }
{
 jq -cn --arg at "$(now -600)" '{type:"user",timestamp:$at,sessionId:"s",message:{role:"user",content:"is the footer done?"}}'
 jq -cn --arg at "$(now -500)" '{type:"assistant",requestId:"q-c1",timestamp:$at,sessionId:"s",message:{role:"assistant",stop_reason:"tool_use",content:[{type:"tool_use",id:"c1",name:"Bash",input:{command:"bin/fm-captain-message.sh --answers X --title Done -"}}]}}'
 jq -cn --arg at "$(now +30)" --arg out "$A1" '{type:"user",timestamp:$at,sessionId:"s",message:{role:"user",content:[{type:"tool_result",tool_use_id:"c1",content:$out}]}}'
 jq -cn --arg at "$(now +60)" '{type:"assistant",requestId:"r-ans",uuid:"u1",isSidechain:false,timestamp:$at,sessionId:"s",message:{role:"assistant",stop_reason:"end_turn",content:[{type:"text",text:"Footer is **blue** now."}]}}'
 jq -cn --arg at "$(now +120)" '{type:"user",timestamp:$at,sessionId:"s",message:{role:"user",content:"thanks, anything else?"}}'
 jq -cn --arg at "$(now +180)" '{type:"assistant",requestId:"r-other",uuid:"u2",isSidechain:false,timestamp:$at,sessionId:"s",message:{role:"assistant",stop_reason:"end_turn",content:[{type:"text",text:"Nothing else pending."}]}}'
} > $T/s.jsonl
python3 "$R/bin/fm-captain-message-sweep.py" --home $H --transcripts $T --since 2026-01-02T00:00:00Z; echo "sweep rc=$?"
echo "== log after sweep (id/req, answers, text):"; jq -c '{k:(.req//.id), answers, text}' $H/data/captain-messages.jsonl
rm -rf $H $T
