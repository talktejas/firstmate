#!/usr/bin/env bash
# Drives the real bin/fm-finished-check.sh; Jev is a fake curl on PATH that logs each request body.
R=$1; T=$(mktemp -d); H=$T/home; S=$H/state; W=$T/wt; ID=t1; FB=$T/fakebin
mkdir -p "$S" "$FB" "$T/nokey/state"; git init -q "$W"
GIT_COMMITTER_DATE=2020-01-01T00:00:00Z git -C "$W" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m base --date 2020-01-01T00:00:00Z
printf 'TYPESAFE_API_KEY=fake-key-for-drive\n' > "$H/.env"
"$R/bin/fm-busy-event.sh" arm "$S" $ID >/dev/null
cat > "$FB/curl" <<SH
#!/usr/bin/env bash
out=''; while [ \$# -gt 0 ]; do case "\$1" in -o) out=\$2; shift 2;; *) shift;; esac; done
body=\$(cat); printf '%s\n' "\$body" >> "$T/requests"
key=\$(jq -r '.questions|keys[0]' <<<"\$body")
case "\${JEV_MODE:-ok}" in
  down) exit 28 ;;
  http500) echo '{"error":"x"}' > "\$out"; printf 500; exit 0 ;;
  garbage) echo 'not json' > "\$out"; printf 200; exit 0 ;;
  offlist) jq -cn --arg k "\$key" '{answers:{(\$k):{choice:"maybe",confidence:0.9,probabilities:{maybe:0.9,no:0.1}}}}' > "\$out"; printf 200; exit 0 ;;
esac
c=no; case " \${JEV_YES:-} " in *" \$key "*) c=yes;; esac
p=\${JEV_CONF:-0.95}; [ \$c = yes ] && y=\$p || y=\$(jq -n "1-\$p")
jq -cn --arg k "\$key" --arg c \$c --argjson p \$p --argjson y \$y '{answers:{(\$k):{choice:\$c,confidence:\$p,probabilities:{yes:\$y,no:(1-\$y)}}}}' > "\$out"; printf 200
SH
chmod +x "$FB/curl"
tr() { # transcript with the given Bash commands this turn
  { jq -cn '{type:"user",message:{content:"old prompt"}}'
    jq -cn '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:"npm test"}}]}}'
    jq -cn '{type:"user",message:{content:"do the task; token=SECRET-IN-PROMPT"}}'
    for c in "$@"; do jq -cn --arg c "$c" '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}'
      jq -cn '{type:"user",message:{content:[{type:"tool_result",content:"ok"}]}}'; done; } > "$T/transcript.jsonl"; }
run() { # <name> <home> <status-line|-> <dirty 0|1> <closing message> [extra json]
  local name=$1 home=$2 st=$3 dirty=$4 msg=$5 extra=${6:-{\}}
  : > "$T/requests"; rm -f "$S/$ID.status" "$W/dirty"; touch -t 202601010000 "$S/$ID.busy-state"
  [ "$st" = - ] || { printf '%s\n' "$st" > "$S/$ID.status"; touch -t 202601010001 "$S/$ID.status"; }
  [ "$dirty" = 0 ] || : > "$W/dirty"
  echo "=== $name"
  echo "    status line this turn: $st | files changed: $dirty | JEV_MODE=${JEV_MODE:-ok} JEV_YES='${JEV_YES:-}' JEV_CONF=${JEV_CONF:-0.95}"
  echo "    closing message: $msg"
  out=$(jq -cn --arg m "$msg" --arg t "$T/transcript.jsonl" --argjson x "$extra" '{stop_hook_active:false,background_tasks:[],last_assistant_message:$m,transcript_path:$t}+$x' \
    | PATH="$FB:$PATH" "$R/bin/fm-finished-check.sh" "$home" "$S" $ID "$W"); rc=$?
  echo "    exit=$rc hook stdout: ${out:-<empty: turn ends as today>}"
  echo "    Jev asked: $(jq -r '.questions|keys[0]' "$T/requests" | paste -sd, -)"
  echo "    state sent to Jev (top-level keys, all calls): $(jq -c '.state|keys' "$T/requests" | sort -u | paste -sd' ' -)"
  grep -q -e 'SECRET' -e 'curl -H' "$T/requests" && echo "    !! LEAK: a shell command or prompt reached Jev" || echo "    no shell command or prompt text in any request"
}
Q='I found two ways to store the setting. Which one do you want me to use?'
tr 'git status'
JEV_YES=asks_question run "1 question, nobody told -> sent back" "$H" - 0 "$Q"
JEV_YES=asks_question run "2 same question but needs-decision: reported -> nothing asked" "$H" 'needs-decision: column or row?' 0 "$Q"
JEV_YES="asks_question partial_or_blocked claims_finished claims_checks_passed" run "3 no key -> off, no call" "$T/nokey" - 1 "$Q"
JEV_MODE=down JEV_YES=asks_question run "4a Jev down (curl timeout)" "$H" - 0 "$Q"
JEV_MODE=http500 run "4b Jev HTTP 500" "$H" - 0 "$Q"
JEV_MODE=garbage run "4c Jev returns non-JSON" "$H" - 0 "$Q"
JEV_MODE=offlist run "4d Jev picks a choice off the fixed list" "$H" - 0 "$Q"
JEV_YES=asks_question JEV_CONF=0.55 run "5 Jev unsure (yes at 0.55, floor 0.6)" "$H" - 0 "$Q"
JEV_YES=asks_question run "6 stop after a send-back (stop_hook_active) -> no loop" "$H" - 0 "$Q" '{"stop_hook_active":true}'
JEV_YES=asks_question run "7 background task still running" "$H" - 0 "$Q" '{"background_tasks":[{"id":"b1"}]}'
tr 'git add -A' "curl -H 'Authorization: Bearer SECRET-TOKEN' https://x.invalid" 'git commit -m fix'
JEV_YES=claims_checks_passed run "8 claims tests pass, no check command this turn (npm test was a PREVIOUS turn) -> sent back" "$H" 'done: PR opened' 1 'Fixed and committed. All tests pass and lint is clean.'
tr 'git add -A' 'cargo clippy --all-targets' 'git commit -m fix'
JEV_YES=claims_checks_passed run "9 claims checks pass and cargo clippy ran -> not sent back" "$H" 'done: PR opened' 1 'Fixed and committed. clippy is clean.'
c=(); for i in $(seq 1 60); do c+=("git log -$i"); done
tr "cd /some/very/long/path/$(printf 'x%.0s' $(seq 1 300)) && npm test" "${c[@]}"
JEV_YES=claims_checks_passed run "10 test ran past char 200 and >40 commands ago -> not sent back" "$H" 'done: PR opened' 1 'All tests pass.'
tr 'git status'
JEV_YES=partial_or_blocked run "11 reported done: but message says partial -> sent back" "$H" 'done: PR opened' 1 'I updated the parser but the migration is not done; the DB would not start.'
JEV_YES=claims_finished run "12 says finished, files changed, no state -> sent back" "$H" - 1 'The work is complete and committed.'
JEV_YES=claims_finished run "13 says finished, NO files changed, no state -> fact missing, Jev alone cannot block" "$H" - 0 'The work is complete.'
JEV_YES= run "14 plain status message, Jev says no to all -> turn ends" "$H" - 1 'The current branch is fm/x and the last commit is 08a3a5cd.'
: > "$T/requests"; echo "=== 15 malformed hook stdin"; out=$(echo 'not json' | PATH="$FB:$PATH" "$R/bin/fm-finished-check.sh" "$H" "$S" $ID "$W"); echo "    exit=$? stdout: ${out:-<empty>} requests: $(wc -l < "$T/requests")"
echo "=== 16 wrong arg count"; out=$("$R/bin/fm-finished-check.sh" a b 2>&1 </dev/null); echo "    exit=$? output: $out"
rm -rf "$T"
