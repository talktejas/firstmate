#!/usr/bin/env bash
# Live guard for the Claude Stop-hook contract bin/fm-finished-check.sh reads.
#
# The check's verdict depends on what Claude Code itself emits and accepts: a
# Stop payload carrying last_assistant_message, stop_hook_active, and
# background_tasks, and a {"decision":"block"} reply that continues the turn
# and marks the following stop stop_hook_active. A stub can only restate those
# assumptions, so this drives one real `claude -p` turn through the real check.
# Jev is a fake curl that answers yes, so the guard needs no Jev key and spends
# only the two short Claude turns. tests/fm-finished-check.test.sh owns the logic.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_FINISHED_CHECK_LIVE_E2E claude

TMP_ROOT=$(fm_test_tmproot fm-finished-check-live)
ID=fc-live
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
WT="$TMP_ROOT/wt"
VERSION=$(claude --version 2>/dev/null | head -n 1)

mkdir -p "$STATE" "$WT/.claude" "$TMP_ROOT/fakebin"
printf 'TYPESAFE_API_KEY=test-key-live-guard\n' > "$HOME_DIR/.env"
git init -q "$WT"
"$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID" >/dev/null || fail "could not arm the busy record"
cat > "$TMP_ROOT/fakebin/curl" <<'SH'
#!/usr/bin/env bash
out=''
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac
done
key=$(jq -r '.questions | keys[0]')
jq -cn --arg k "$key" '{answers: {($k): {choice: "yes", confidence: 0.9, probabilities: {yes: 0.9, no: 0.1}}}}' > "$out"
printf 200
SH
chmod +x "$TMP_ROOT/fakebin/curl"

# The same shape bin/fm-spawn.sh writes, with each payload and reply recorded.
hook="p=\$(cat); printf '%s\\n' \"\$p\" >> '$TMP_ROOT/payloads'; fm_block=\$(printf '%s' \"\$p\" | PATH='$TMP_ROOT/fakebin':\"\$PATH\" '$ROOT/bin/fm-finished-check.sh' '$HOME_DIR' '$STATE' '$ID' '$WT' 2>/dev/null) || fm_block=; if [ -n \"\$fm_block\" ]; then printf '%s\\n' \"\$fm_block\" | tee -a '$TMP_ROOT/blocks'; else touch '$TMP_ROOT/turn-ended'; fi"
jq -n --arg c "$hook" '{hooks: {Stop: [{hooks: [{type: "command", command: $c}]}]}}' > "$WT/.claude/settings.local.json"

out=$(cd "$WT" && timeout 180 claude -p 'Reply with exactly this text and nothing else: Should I use option A or option B?' \
  --model haiku --dangerously-skip-permissions </dev/null 2>&1) \
  || fail "claude -p failed on $VERSION: $out"

[ -s "$TMP_ROOT/payloads" ] || fail "$VERSION fired no Stop hook"
first=$(sed -n 1p "$TMP_ROOT/payloads")
jq -e '(.last_assistant_message | type) == "string" and (.last_assistant_message | length) > 0
  and .stop_hook_active == false and (.background_tasks | type) == "array"
  and (.transcript_path | type) == "string"' >/dev/null 2>&1 <<<"$first" \
  || fail "$VERSION Stop payload no longer carries the fields the check reads: $first"
[ "$(wc -l < "$TMP_ROOT/blocks" 2>/dev/null | tr -d ' ')" = 1 ] \
  || fail "$VERSION: the check must send the worker back exactly once"
jq -e 'select(.stop_hook_active == true)' "$TMP_ROOT/payloads" >/dev/null 2>&1 \
  || fail "$VERSION did not continue the turn on a block decision and mark the next stop stop_hook_active"
[ -f "$TMP_ROOT/turn-ended" ] || fail "$VERSION: the stop after the send-back did not end the turn"
pass "$VERSION: Stop payload fields, block continuation, and stop_hook_active all hold"
