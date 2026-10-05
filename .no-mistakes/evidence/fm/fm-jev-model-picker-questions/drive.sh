#!/usr/bin/env bash
# Drives bin/fm-dispatch-resolve.sh as an operator would, in a scratch FM_HOME.
# STUB pass: the typesafe.ai reply is canned at the curl boundary, for the cases whose
# exact probabilities cannot be forced from the real model (live pass: live-drive.sh).
set -u
ROOT=$1; T=$(mktemp -d); H=$T/home; B=$T/bin; mkdir -p "$H/config" "$B" "$T/log"
TOOL=$ROOT/bin/fm-dispatch-resolve.sh
cat > "$B/curl" <<'SH'
#!/usr/bin/env bash
out=''; while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2;; *) shift;; esac; done
cat > "$CURL_LOG/body"; : > "$CURL_LOG/called"
cp "$CURL_RESPONSE" "$out"; printf 200
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
export CURL_LOG=$T/log CURL_RESPONSE=$T/resp.json
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
printf '%s\n' '# Task' 'Write the PRD for the loyalty points feature. MARKER-TASK-TEXT' '' '# Setup' 'Create your branch. MARKER-STANDING-TEXT' > "$T/brief.md"
# resp <choice> <conf> <p1> <p2> <p3> <p4> <pd> <kind> <damage> <settled> <security> <small-conf>
resp() {
  jq -n --arg ch "$1" --argjson c "$2" --argjson p1 "$3" --argjson p2 "$4" --argjson p3 "$5" --argjson p4 "$6" --argjson pd "$7" \
    --arg kind "$8" --arg damage "$9" --arg settled "${10}" --arg security "${11}" --argjson sc "${12}" '
    def ans($opts; $pick): {type:"choice", choice:$pick, confidence:$sc,
      probabilities: ($opts | map({key: ., value: (if . == $pick then 1 - ((($opts|length)-1)*0.001) else 0.001 end)}) | from_entries)};
    {model:"jev-1.13.0", usage:{input_tokens:500, output_tokens:80}, answers:{
      rule:{type:"choice", choice:$ch, confidence:$c, probabilities:{rule_1:$p1, rule_2:$p2, rule_3:$p3, rule_4:$p4, default:$pd}},
      kind: ans(["investigate","lookup","design","product_document","review","refactor","feature","bugfix","tests","docs","mechanical","ops"]; $kind),
      damage: ans(["low","medium","high"]; $damage), settled: ans(["settled","partly","open"]; $settled), security: ans(["yes","no"]; $security)}}' > "$CURL_RESPONSE"
}
go() { echo "\$ fm-dispatch-resolve.sh brief.md --project demo"; PATH="$B:$PATH" FM_HOME=$H TYPESAFE_API_KEY=${KEY-scratch-key-not-real} "$TOOL" "$T/brief.md" --project demo 2>&1; echo "[exit $?]"; echo; }
say() { printf '\n=== %s ===\n' "$1"; }

say "S1 no key: off, nothing on stdout, no request, no record"
rm -f "$T/log/called"; echo "\$ fm-dispatch-resolve.sh brief.md   (no TYPESAFE_API_KEY anywhere)"
PATH="$B:$PATH" FM_HOME=$H env -u TYPESAFE_API_KEY "$TOOL" "$T/brief.md" --project demo; echo "[exit $?]"
[ -e "$T/log/called" ] && echo "curl called: YES" || echo "curl called: no"
[ -e "$H/state/.dispatch-resolve.log" ] && echo "record written: YES" || echo "record written: no"

say "S2 PRD brief, rule answer unsure (0.46 on 'no rule applies'), kind=product_document 1.0 -> usable answer"
resp default 0.46 0.4 0.05 0.03 0.02 0.5 product_document low partly no 1
go
echo "questions sent in the single request: $(jq -c '.questions | keys_unsorted' "$T/log/body")"
echo "rule options sent: $(jq -c '.questions.rule.criteria | keys_unsorted' "$T/log/body")"
echo "state sent: $(jq -c .state "$T/log/body")"
echo "request mentions match/use/why/approval/model names: $(grep -c -E '"match"|"use"|"why"|"approval"|opus|sonnet|haiku' "$T/log/body")"

say "S3 confident rule answer (rule_2 0.9) stands; contradicting small answers (kind=bugfix) are not consulted"
resp rule_2 0.9 0.03 0.92 0.02 0.01 0.02 bugfix low settled no 1
go

say "S4 confident 'no rule applies' (0.9) stands even though kind=design meets rule_2's match"
resp default 0.9 0.02 0.04 0.02 0.01 0.91 design low settled no 1
go

say "S5 unsure rule answer and small answers also unsure (0.5) -> ambiguous, no profile, as before"
resp rule_1 0.4 0.45 0.05 0.3 0.02 0.18 product_document low partly no 0.5
go

say "S6 unsure rule answer, small answers meet two rules with different outcomes? no: kind=lookup meets no rule -> ambiguous"
resp rule_1 0.4 0.45 0.05 0.3 0.02 0.18 lookup low settled no 1
go

say "S7 GUARD unsure rule_3, feature+medium meets rule_3 BUT security=yes meets the approval-gated rule_4 -> ambiguous, no profile"
resp rule_3 0.4 0.1 0.05 0.45 0.2 0.2 feature medium settled yes 0.9
go

say "S8 GUARD Jev's own unsure pick is the approval-gated rule_4, feature+medium meets rule_3 -> ambiguous, no profile"
resp rule_4 0.5 0.05 0.05 0.2 0.55 0.15 feature medium settled no 0.9
go

say "S9 GUARD confident pick of the approval-gated rule_4 with security=no -> still stops for captain approval"
resp rule_4 0.9 0.02 0.02 0.02 0.92 0.02 feature medium settled no 0.9
go

say "S10 small answers malformed (kind is a string, damage off-list, settled missing) with confident rule -> not an error"
resp rule_3 0.9 0.02 0.02 0.92 0.02 0.02 bugfix low settled no 0.9
jq '.answers.kind = "x" | .answers.damage.choice = "bogus" | del(.answers.settled)' "$CURL_RESPONSE" > "$T/r2" && mv "$T/r2" "$CURL_RESPONSE"
go
say "S10b same malformed small answers with an UNSURE rule answer -> ambiguous, never error, never a pick"
jq '.answers.rule.confidence = 0.4 | .answers.rule.probabilities = {rule_1:0.1,rule_2:0.1,rule_3:0.5,rule_4:0.1,default:0.2}' "$CURL_RESPONSE" > "$T/r2" && mv "$T/r2" "$CURL_RESPONSE"
go

say "S11 same-outcome rules count as one answer: rule_1 and rule_2 given the same model, split 0.45/0.45"
jq '.rules[1].use = .rules[0].use | del(.rules[].match)' "$T/match.json" > "$H/config/crew-dispatch.json"
jq -n '{model:"jev-1.13.0", usage:{input_tokens:500,output_tokens:60}, answers:{rule:{type:"choice", choice:"rule_1", confidence:0.3,
  probabilities:{rule_1:0.45, rule_2:0.45, rule_3:0.04, rule_4:0.03, default:0.03}}}}' > "$CURL_RESPONSE"
go
echo "S12 (same run) rules file with no match -> questions sent: $(jq -c '.questions | keys_unsorted' "$T/log/body")"
cp "$T/match.json" "$H/config/crew-dispatch.json"

say "S13 Jev down: REAL curl to the REAL api.typesafe.ai with an invalid key -> error, exit 0, decide by hand"
echo "\$ TYPESAFE_API_KEY=<invalid> fm-dispatch-resolve.sh brief.md --project demo"
PATH="$(dirname "$(command -v quota-axi)"):$PATH" FM_HOME=$H TYPESAFE_API_KEY=invalid-key-for-no-mistakes-test "$TOOL" "$T/brief.md" --project demo 2>&1; echo "[exit $?]"

say "S14 malformed match in the rules file -> exit 2 before any request"
jq '.rules[0].match = {kind: ["prd"]}' "$T/match.json" > "$H/config/crew-dispatch.json"; rm -f "$T/log/called"
go
[ -e "$T/log/called" ] && echo "curl called: YES" || echo "curl called: no"
cp "$T/match.json" "$H/config/crew-dispatch.json"

say "S15 the record: one line per outcome above (after the gate), private, no brief text, no key"
L=$H/state/.dispatch-resolve.log
echo "mode: $(stat -c %a "$L")   lines: $(wc -l < "$L")"
echo "\$ jq -r .status state/.dispatch-resolve.log | sort | uniq -c"; jq -r .status "$L" | sort | uniq -c
echo "first line (the S2 PRD decision):"; head -1 "$L" | jq .
echo "brief text in record: $(grep -c 'MARKER\|loyalty' "$L")   key in record: $(grep -c 'scratch-key\|invalid-key' "$L")"
rm -rf "$T"
