#!/usr/bin/env bash
# Live drive of the captain-message resolution against an isolated FM_HOME that
# mirrors the captain's report: a second mate "koin" whose home is a firstmate
# working copy (basename "firstmate") and who owns project koin (branch develop).
set -u
W=${W:?}; L=$(mktemp -d /tmp/nm-live.XXXX)
H=$L/home; M=$L/treehouse/firstmate-b19abf/2/firstmate
mkdir -p "$H/data" "$H/state" "$M/projects"
git init -q "$M"; git init -q "$M/projects/koin"; echo develop > "$M/projects/koin/.firstmate-base"
cat > "$H/data/projects.md" <<P
# Projects
- koin [no-mistakes base=develop] - expense tracker (talktejas/koin) (added 2026-09-01)
- ledger [no-mistakes base=trunk] - books (added 2026-09-01)
P
cat > "$H/data/secondmates.md" <<S
- koin - expenses (home: $M; scope: koin; projects: koin; added 2026-09-01)
- b2b - commerce (home: $M; scope: b2b; projects: b2becom, interact; added 2026-09-01)
- books - ledger (home: $L/nowhere/firstmate; scope: books; projects: ledger; added 2026-09-01)
- far - remote (host: far.example; root: /srv/firstmate; home: /srv/fm-homes/far; scope: far; projects: koin; added 2026-09-01)
S
mk() { printf 'window=w\nworktree=%s\nproject=%s\nkind=secondmate\nmode=secondmate\nhome=%s\nprojects=%s\n' "$2" "$3" "$4" "$5" > "$H/state/$1.meta"; }
mk koin "$M" "$M" "$M" koin
mk b2b "$M" "$M" "$M" "b2becom, interact"
mk books "$L/nowhere/firstmate" "$L/nowhere/firstmate" "$L/nowhere/firstmate" ledger   # no clone anywhere -> registry
mk far /srv/fm-homes/far /srv/firstmate /srv/fm-homes/far koin
git init -q "$L/wt"; git -C "$L/wt" checkout -q -b fm/colour
printf 'project=/home/captain/p/demo\nworktree=%s\n' "$L/wt" > "$H/state/cc-live.meta"
R="$W/bin/fm-captain-message.sh"; row() { tail -1 "$H/data/captain-messages.jsonl" | jq -c '{task,project,worktree,branch}'; }
echo "== S1 recorder: --task koin (the captain's case)"; FM_HOME=$H "$R" --title Koin --task koin "The Koin stack is ready" >/dev/null; row
echo "== S3 recorder: --task b2b (mate owning two projects)"; FM_HOME=$H "$R" --title B2B --task b2b "Two projects moved" >/dev/null; row
echo "== S4 recorder: --task books (no clone anywhere, branch only in data/projects.md)"; FM_HOME=$H "$R" --title Books --task books "Ledger ok" >/dev/null; row
echo "== S4b recorder: --task far (remote mate, home on another host)"; FM_HOME=$H "$R" --title Far --task far "Remote ok" >/dev/null; row
echo "== S6 recorder: --task cc-live (ordinary worker, unchanged behaviour)"; FM_HOME=$H "$R" --title Worker --task cc-live "Blue or green?" >/dev/null; row
echo "== S7 recorder: --task koin with explicit --project/--branch overrides"; FM_HOME=$H "$R" --title Ovr --task koin --project koin-web --branch fm/x "override" >/dev/null; row
echo "== S2 sweep: transcript turn that read state/koin.meta (catch-up and Stop-hook payload)"
T=$L/tx/sess.jsonl; mkdir -p "$L/tx"
{ echo '{"type":"user","sessionId":"sess-k","message":{"role":"user","content":"go"}}'
  jq -cn '{type:"assistant",requestId:"t1",sessionId:"sess-k",timestamp:"2026-09-20T10:00:00.000Z",message:{role:"assistant",stop_reason:"tool_use",content:[{type:"tool_use",name:"Bash",input:{command:"cat state/koin.meta"}}]}}'
  jq -cn '{type:"assistant",requestId:"r-koin",uuid:"u1",isSidechain:false,sessionId:"sess-k",timestamp:"2026-09-20T10:00:01.000Z",gitBranch:"main",message:{role:"assistant",stop_reason:"end_turn",content:[{type:"text",text:"Koin expense tracker: the stack is ready on develop."}]}}'
  echo '{"type":"user","sessionId":"sess-k","message":{"role":"user","content":"and b2b?"}}'
  jq -cn '{type:"assistant",requestId:"t2",sessionId:"sess-k",timestamp:"2026-09-20T10:01:00.000Z",message:{role:"assistant",stop_reason:"tool_use",content:[{type:"tool_use",name:"Bash",input:{command:"cat state/b2b.meta"}}]}}'
  jq -cn '{type:"assistant",requestId:"r-b2b",uuid:"u2",isSidechain:false,sessionId:"sess-k",timestamp:"2026-09-20T10:01:01.000Z",gitBranch:"main",message:{role:"assistant",stop_reason:"end_turn",content:[{type:"text",text:"B2B mate moved both projects."}]}}'
} > "$T"
H2=$L/home-sweep; cp -r "$H" "$H2"; rm -f "$H2/data/captain-messages.jsonl"
python3 "$W/bin/fm-captain-message-sweep.py" --home "$H2" --transcripts "$L/tx" --since 2026-09-01T00:00:00Z
echo "-- catch-up:"; jq -c '{req,task,project,worktree,branch}' "$H2/data/captain-messages.jsonl"
H3=$L/home-hook; cp -r "$H" "$H3"; rm -f "$H3/data/captain-messages.jsonl"
jq -cn --arg p "$T" '{transcript_path:$p}' | python3 "$W/bin/fm-captain-message-sweep.py" --home "$H3" --from-payload --since 2026-09-01T00:00:00Z
echo "-- stop-hook payload:"; jq -c '{req,task,project,worktree,branch}' "$H3/data/captain-messages.jsonl"
echo "== S5 backfill: the exact pre-fix row the captain saw, plus adversarial rows"
H4=$L/home-backfill; cp -r "$H" "$H4"; mk stray "$M" "$M" "$M" koin; cp "$H/state/stray.meta" "$H4/state/"
cat > "$H4/data/captain-messages.jsonl" <<J
{"id":"captain-saw","at":"2026-09-20T10:00:01Z","title":"Koin stack","text":"The Koin stack is ready","task":"koin","project":"firstmate","worktree":"$M","branch":null,"source":"transcript","session":"sess-k","req":"r-koin"}
{"id":"remote-old","task":"far","project":"firstmate","worktree":"/srv/fm-homes/far","branch":null}
{"id":"b2b-old","task":"b2b","project":"firstmate","worktree":"$M","branch":null}
{"id":"unregistered-mate","task":"stray","project":"firstmate","worktree":"$M","branch":null}
{"id":"not-mate-home","task":"koin","project":"firstmate","worktree":"/some/other/home","branch":null}
{"id":"wrong-project","task":"koin","project":"koin-typo","worktree":"$M","branch":null}
{"id":"worker","task":"cc-live","project":"demo","worktree":"$L/wt","branch":"fm/colour"}
J
cp "$H4/data/captain-messages.jsonl" "$L/before.jsonl"
echo "-- first run:"; FM_HOME=$H4 "$W/bin/fm-captain-message-backfill.py"; echo
jq -c '{id,project,worktree,branch}' "$H4/data/captain-messages.jsonl"
echo "-- unchanged fields of captain-saw (all except project/worktree/branch):"
diff <(jq -S 'select(.id=="captain-saw")|del(.project,.worktree,.branch)' "$L/before.jsonl") <(jq -S 'select(.id=="captain-saw")|del(.project,.worktree,.branch)' "$H4/data/captain-messages.jsonl") && echo identical
echo "-- untouched rows byte-identical:"; for id in unregistered-mate not-mate-home wrong-project worker; do cmp -s <(grep "\"$id\"" "$L/before.jsonl") <(grep "\"$id\"" "$H4/data/captain-messages.jsonl") && echo "$id identical" || echo "$id CHANGED"; done
cp "$H4/data/captain-messages.jsonl" "$L/after1.jsonl"
echo "-- second run:"; FM_HOME=$H4 "$W/bin/fm-captain-message-backfill.py"; echo
cmp -s "$L/after1.jsonl" "$H4/data/captain-messages.jsonl" && echo "log byte-identical after rerun (converged)"
echo "LIVE_ROOT=$L"
