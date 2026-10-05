#!/usr/bin/env bash
# Drives bin/fm-dispatch-resolve.sh against the REAL api.typesafe.ai (jev-latest).
# The key is read by the tool itself from the scratch home's .env (a symlink);
# this script never reads, prints, or copies it. curl is the real curl behind a
# pass-through that keeps a copy of the request BODY only (never the header on
# fd 3). quota-axi is a fixed snapshot so the quota step cannot vary.
# Rules and briefs are synthetic, written for this run.
set -u
ROOT=$1; ENVFILE=$2; T=$(mktemp -d); H=$T/home; B=$T/bin; mkdir -p "$H/config" "$B" "$T/log" "$T/briefs"
TOOL=$ROOT/bin/fm-dispatch-resolve.sh
ln -s "$ENVFILE" "$H/.env"
REAL_CURL=$(command -v curl)
cat > "$B/curl" <<SH
#!/usr/bin/env bash
cat > "\$CURL_LOG/body"; n=\$(cat "\$CURL_LOG/n" 2>/dev/null || echo 0); echo \$((n+1)) > "\$CURL_LOG/n"
exec "$REAL_CURL" "\$@" < "\$CURL_LOG/body"
SH
cat > "$B/quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"generatedAt":"2030-01-01T00:00:00Z","schemaVersion":5,"providers":[
 {"provider":"claude","state":{"status":"fresh"},"quotaSemantics":{"status":"known","effectiveAvailability":[
  {"scope":"all_models","status":"known","effectivePercentRemaining":79,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.4}}]}}]}
JSON
SH
chmod +x "$B/curl" "$B/quota-axi"
export CURL_LOG=$T/log
cat > "$T/match.json" <<'JSON'
{ "rules": [
  { "when": "Ambiguous investigation, or writing a plan or spec from a vague request.",
    "match": { "kind": ["investigate", "product_document"] },
    "use": { "harness": "claude", "model": "opus", "effort": "high" } },
  { "when": "Architecture or system design.", "match": { "kind": ["design"] },
    "use": { "harness": "claude", "model": "opus", "effort": "xhigh" } },
  { "when": "A small bug fix or familiar feature work.",
    "match": { "kind": ["bugfix", "feature"], "damage": ["low", "medium"] },
    "use": { "harness": "claude", "model": "sonnet", "effort": "medium" } },
  { "when": "The change is security-sensitive.", "approval": "captain",
    "match": { "security": ["yes"] },
    "use": { "harness": "claude", "model": "opus", "effort": "medium" } } ],
  "default": { "harness": "claude", "model": "haiku" } }
JSON
cp "$T/match.json" "$H/config/crew-dispatch.json"
brief() { printf '%s\n' '# Task' "$2" '' '# Setup' 'Create your branch and report when done. MARKER-STANDING-TEXT' > "$T/briefs/$1.md"; }
brief study     'Produce a study of how customers use the export feature, as a written report.'
brief market    'Write a market study of loyalty programmes in grocery retail.'
brief compare   'Write a comparison report of three payment providers for the finance team.'
brief survey    'Write a user survey report from the attached results.'
brief widget    'Build the new onboarding checklist widget for the dashboard.'
brief summary   'Summarise last quarter'"'"'s support tickets into a report for the product team.'
brief prd       'Write the PRD for the loyalty points feature.'
brief research  'Research competing products and write a report comparing them with ours.'
brief design    'Design the architecture of a new service that stores and rotates customer API keys.'
brief reset     'Change how password reset tokens are generated and validated.'
brief tidy      'Tidy up the checkout code.'
brief settings  'Update the settings page.'
brief rounding  'Find where the invoice total is rounded. Change nothing.'
brief bugfix    'Fix the off-by-one error in the pagination helper: page 2 repeats the last row of page 1.'
brief rename    'Rename the function getUser to fetchUser everywhere in the repository.'
go() {  # <brief-name>
  echo "\$ FM_HOME=<scratch home> fm-dispatch-resolve.sh $1.md --project demo     # task: $(sed -n 2p "$T/briefs/$1.md")"
  PATH="$B:$PATH" FM_HOME=$H env -u TYPESAFE_API_KEY "$TOOL" "$T/briefs/$1.md" --project demo 2>&1; echo "[exit $?]"; echo
}
say() { printf '\n=== %s ===\n' "$1"; }
shape() {
  echo "questions in the one request: $(jq -c '.questions | keys_unsorted' "$T/log/body")"
  echo "rule options: $(jq -c '.questions.rule.criteria | keys_unsorted' "$T/log/body")"
  echo "top-level request keys: $(jq -c 'keys_unsorted' "$T/log/body")"
  echo "state sent: $(jq -c .state "$T/log/body")"
  echo "body mentions standing text / match / use / why / approval / model names: $(grep -c -E 'MARKER-STANDING|"match"|"use"|"why"|"approval"|opus|sonnet|haiku|captain' "$T/log/body")"
}

say "L0 environment: TYPESAFE_API_KEY in this process environment? ${TYPESAFE_API_KEY:+YES}${TYPESAFE_API_KEY:-no}; home .env is a symlink the tool reads itself"

say "L1 four-rule file WITH match, fifteen briefs, real Jev"
for b in market compare survey widget summary study prd research design reset tidy settings rounding bugfix rename; do
  go $b
  [ $b = market ] && { echo "--- request captured for the market-study brief ---"; shape; echo; }
done
echo "requests made so far (one per call): $(cat "$T/log/n")"

say "L2 same briefs that were unsure above, second run (stability)"
for b in market compare survey widget tidy settings rounding; do go $b; done

say "L3 rules file with NO match: only the rule question is asked"
jq 'del(.rules[].match)' "$T/match.json" > "$H/config/crew-dispatch.json"
go market; shape; echo
go compare; go survey; go widget; go prd

say "L4 same-outcome rules count as one answer: rules 1 and 3 given one outcome, no match"
jq 'del(.rules[].match) | .rules[2].use = .rules[0].use' "$T/match.json" > "$H/config/crew-dispatch.json"
go settings; go tidy
cp "$T/match.json" "$H/config/crew-dispatch.json"

say "L5 the record after the live calls"
L=$H/state/.dispatch-resolve.log
echo "mode: $(stat -c %a "$L")   lines: $(wc -l < "$L")   requests made: $(cat "$T/log/n")"
echo "\$ jq -r .status state/.dispatch-resolve.log | sort | uniq -c"; jq -r .status "$L" | sort | uniq -c
echo "clear only through the small answers or counting (selection set):"; jq -c 'select(.selection != null) | {status, rule, confidence, rule_answer, selection, profile}' "$L"
echo "first record line:"; head -1 "$L" | jq .
echo "brief text in record: $(grep -c -i 'MARKER\|study\|loyalty\|password\|checkout\|survey\|payment' "$L")"
KV=$(sed -n 's/^TYPESAFE_API_KEY=//p' "$ENVFILE" | tr -d '"'"'"'\r' | head -1)
echo "key value found in record: $(grep -c -F -- "$KV" "$L")   in last captured request body: $(grep -c -F -- "$KV" "$T/log/body")"
unset KV

say "L6 Jev down or unsure: nothing changes for the operator"
echo "\$ TYPESAFE_API_KEY=<invalid> fm-dispatch-resolve.sh prd.md --project demo     (real API rejects the key)"
PATH="$B:$PATH" FM_HOME=$H TYPESAFE_API_KEY=invalid-key-for-no-mistakes-test "$TOOL" "$T/briefs/prd.md" --project demo 2>&1; echo "[exit $?]"
echo
echo "\$ FM_HOME=<home with no .env> fm-dispatch-resolve.sh prd.md     (no key anywhere)"
mkdir -p "$T/nokey/config"; cp "$T/match.json" "$T/nokey/config/crew-dispatch.json"; n0=$(cat "$T/log/n")
PATH="$B:$PATH" FM_HOME=$T/nokey env -u TYPESAFE_API_KEY "$TOOL" "$T/briefs/prd.md" --project demo 2>&1 | sed "s#$T#<scratch>#"; echo "[exit ${PIPESTATUS[0]}]"
echo "request made: $([ "$(cat "$T/log/n")" = "$n0" ] && echo no || echo YES)   record written: $([ -e "$T/nokey/state/.dispatch-resolve.log" ] && echo YES || echo no)"

say "L7 a match naming an answer that is not on the question's list: refused before any request"
jq '.rules[0].match = {kind: ["prd"]}' "$T/match.json" > "$H/config/crew-dispatch.json"; n0=$(cat "$T/log/n")
PATH="$B:$PATH" FM_HOME=$H env -u TYPESAFE_API_KEY "$TOOL" "$T/briefs/prd.md" --project demo 2>&1 | sed "s#$T#<scratch>#"; echo "[exit ${PIPESTATUS[0]}]"
echo "request made: $([ "$(cat "$T/log/n")" = "$n0" ] && echo no || echo YES)"
rm -rf "$T"
