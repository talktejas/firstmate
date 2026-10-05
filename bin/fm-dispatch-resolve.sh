#!/usr/bin/env bash
# fm-dispatch-resolve.sh - resolve one concrete crewmate or scout dispatch
# profile from a task brief with typesafe.ai's System One model (Jev), opt-in.
#
# Usage:
#   fm-dispatch-resolve.sh <brief-file> [--project <name>]
#
# Opt-in gate: TYPESAFE_API_KEY non-empty in this process environment, else a
#   TYPESAFE_API_KEY= line in $FM_HOME/.env read with fmx_env_get, the same
#   accessor as FMX_PAIRING_TOKEN (bin/fm-env-lib.sh). The environment wins.
#   Absent in both: one "dispatch-resolve: off" line on stderr, nothing on
#   stdout, exit 0, no network call, so firstmate dispatches exactly as today.
#   bin/fm-jev-lib.sh owns the key handling, the request, and the answer
#   validation; this tool owns everything decided from the answer.
#
# What it does when on with at least one rule: one POST to
#   https://api.typesafe.ai/v1/systemone with the project name and the brief's
#   `# Task` section (the whole brief when it has none) as state, carrying the
#   Choice question `rule`, whose options are every rule's `when` from
#   config/crew-dispatch.json plus one fixed generic none option, and, only
#   when some rule declares a `match`, the four small questions fixed in
#   QUESTION_DEFS below (kind, damage, settled, security). A file with no
#   `match` asks `rule` alone. Everything after that is jq:
#   - a none pick at or above the confidence floor stands, with its own
#     confidence;
#   - rules whose `use`, `approval`, and `floor` are the same count as one
#     answer, so their probabilities add up;
#   - only when the rule answer is below the confidence floor, a small answer
#     at or above it drops every rule whose declared `match` excludes it, and
#     the none option once some rule's whole declared `match` is met; an
#     approval-gated rule is never dropped, a rule Jev itself picked being
#     dropped is `ambiguous` instead, and a missing or malformed small answer
#     drops nothing;
#   - a none pick set aside that way passes only to an ungated rule whose own
#     whole `match` is met; when any other rule would win, the none pick
#     stands with its own confidence, which is below the floor;
#   - the confidence floor on what remains, the rule's declared `approval` and
#     `floor`, each profile's declared `provider` and `floor`, the quota rows
#     from ONE quota-axi --json snapshot, and the spendPriority argmax over the
#     eligible candidates.
#   The model never sees quota, catalogs, approvals, `match`, `why`, or `use`.
#   With no rules, it returns a non-clear result so firstmate keeps using the
#   existing intake.
#   docs/configuration.md "Crew dispatch profiles" owns the declared fields and
#   "Typed dispatch resolution" owns this tool's operator contract.
#
# Output (stdout, TOON-style block):
#   dispatch-resolve:
#     status: clear | ambiguous | escalate | error
#     model/latency_ms/tokens, rule (when excerpt) and confidence, probabilities
#     questions: <question>=<answer>(<confidence>) for each small question asked, or <question>=unusable
#     selection: <what counting together or narrowing changed>   (only when it did)
#     reason: <why the status is not clear>
#     candidate: <harness>:<model> provider=.. scope=.. remaining=..% spendPriority=.. runway=.. -> eligible | eligible, unranked: <reason> | not eligible: <reason>
#     profile: --harness <h> [--model <m>] [--effort <e>]     (status clear only)
#   clear     -> pass the profile line to fm-spawn.sh unless you state a reason to override
#   ambiguous -> confidence below the floor, including when the small answers
#                exclude Jev's own rule pick; decide as today from the probabilities
#   escalate  -> the rule requires captain approval, no candidate is rankable, or a genuine tie
#   error     -> API, network, response, or quota-axi failure; decide as today
#   Every outcome exits 0 so an intake is never blocked by this tool.
#   Exit 2 only for a usage or configuration error (unreadable brief, an
#   existing unreadable rules file, malformed rules, or missing jq), which is
#   actionable, never selected around.
#
# Record: every outcome after the gate appends one JSON line (time, project,
#   digest of the state sent or null when no request was made, status, chosen
#   rule, confidence, each answer and its confidence, profile) to $FM_HOME/state/.dispatch-resolve.log, mode 0600,
#   cut back to its newest 1000 lines past 256 KiB. It holds no brief text and
#   no key, and a failed write never changes the outcome.
#
# Environment:
#   TYPESAFE_API_KEY is the only resolver-specific environment setting.
#
# Authority: this tool never replaces firstmate's judgment, quota-array-dispatch,
#   the captain-approval gate, or fm-spawn.sh validation; it publishes one
#   inspectable answer plus every candidate's evidence, in code.
set -u

# Sourced before anything can start a child: it takes the key out of the
# exported environment. The path is derived with builtins for the same reason.
_fm_dispatch_dir=${BASH_SOURCE[0]%/*}
[ "$_fm_dispatch_dir" != "${BASH_SOURCE[0]}" ] || _fm_dispatch_dir=.
# shellcheck source=bin/fm-jev-lib.sh
. "$_fm_dispatch_dir/fm-jev-lib.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

CONFIDENCE_FLOOR=$FM_JEV_CONFIDENCE_FLOOR
DEFAULT_WHEN="No listed rule applies to this task."
RECORD_LOG="$FM_HOME/state/.dispatch-resolve.log"
RECORD_MAX_BYTES=262144

# The small questions asked beside `rule`. A rule's optional `match` names the
# answers it accepts per question; the keys here are that vocabulary.
IFS= read -r -d '' QUESTION_DEFS <<'JSON' || true
{
  "kind": {
    "instructions": "What kind of work does `task.brief` ask for? Pick the ONE option that names its main deliverable.",
    "criteria": {
      "investigate": "Finding the cause of a problem: diagnosing a failure, hunting a root cause, or reproducing a bug. The result is knowledge, not a change.",
      "lookup": "Answering a direct question by reading a repository: locating where behaviour lives or tracing how something works, with no fault to diagnose.",
      "design": "Deciding the technical shape of a system, module, or architecture before it is built.",
      "product_document": "Writing a product document instead of code: a PRD, a product or feature specification, a plan, a research report, or a study.",
      "review": "Reviewing or auditing a change or existing code and reporting findings.",
      "refactor": "Restructuring, renaming, or migrating existing code across many places without adding new behaviour.",
      "feature": "Building new behaviour or a new capability, including user interface work.",
      "bugfix": "Fixing a known defect whose symptom or cause is already described.",
      "tests": "Writing tests or raising test coverage as the main deliverable.",
      "docs": "Writing or updating documentation that describes existing code.",
      "mechanical": "A trivial or rote edit that needs no judgement (rename, typo, formatting, import or lint fix), or a throwaway script or scratch tool.",
      "ops": "Debugging CI, a build, or infrastructure: a failing pipeline, a broken environment, or opaque logs."
    }
  },
  "damage": {
    "instructions": "How much damage would a wrong result of the work in `task.brief` do before someone notices and undoes it?",
    "criteria": {
      "low": "Little: read-only work, a document, a throwaway, or a small change in one place that is easy to revert.",
      "medium": "Moderate: an ordinary change to familiar code with a contained effect.",
      "high": "A lot: core or unfamiliar code, many files or modules, a migration, stored data, or anything expensive to unwind."
    }
  },
  "settled": {
    "instructions": "How settled are the instructions in `task.brief`?",
    "criteria": {
      "settled": "The decisions are made: the brief says what to produce and what finished looks like.",
      "partly": "The goal is clear, but real choices about approach or scope are left to the worker.",
      "open": "The request is vague or open-ended: working out what to do is part of the task."
    }
  },
  "security": {
    "instructions": "Is the work in `task.brief` security-sensitive?",
    "criteria": {
      "yes": "It changes or reviews authentication, authorization, secrets or credentials, cryptography, permissions, sandboxing, or the handling of untrusted input.",
      "no": "It touches none of those."
    }
  }
}
JSON

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
# record <result-json>: one line per outcome; see "Record" in the header.
record() {
  local line sz
  line=$(jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg project "$PROJECT" \
    --arg digest "$([ -z "${JEV_STATE:-}" ] || fm_custom_check_sha256 "$JEV_STATE" 2>/dev/null)" '
    {ts: $ts, project: $project, digest: (if $digest == "" then null else $digest end), status, reason, rule, confidence,
     rule_answer: (.raw // null), questions: (.questions // null),
     selection: (.selection // null), latency_ms,
     profile: (if .chosen then (.chosen.profile | {harness, model, effort}) else null end)}' <<<"$1" 2>/dev/null) || return 0
  mkdir -p "${RECORD_LOG%/*}" 2>/dev/null || return 0
  ( umask 077; printf '%s\n' "$line" >> "$RECORD_LOG" ) 2>/dev/null || return 0
  sz=$(wc -c < "$RECORD_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$RECORD_MAX_BYTES" ]; then
    ( umask 077; tail -n 1000 "$RECORD_LOG" > "$RECORD_LOG.tmp" ) 2>/dev/null && mv -f "$RECORD_LOG.tmp" "$RECORD_LOG" 2>/dev/null
    rm -f "$RECORD_LOG.tmp" 2>/dev/null || true
  fi
  return 0
}

no_rules() {
  record '{"status": "escalate", "reason": "no rules to match"}'
  printf 'dispatch-resolve:\n  status: escalate\n  reason: no rules to match\n'
  exit 0
}
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

BRIEF='' PROJECT='' RULES_PATH="$CONFIG/crew-dispatch.json" RULES=''
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || die "--project needs a value"; PROJECT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$BRIEF" ] || die "one brief file only"; BRIEF=$1; shift ;;
  esac
done

# ---- opt-in gate ---------------------------------------------------------------
if ! fm_jev_key_load "$FM_HOME"; then
  echo "dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env)" >&2
  exit 0
fi

# ---- inputs --------------------------------------------------------------------
[ -n "$BRIEF" ] || die "brief file required (see --help)"
[ -r "$BRIEF" ] || die "brief file not readable: $BRIEF"
[ -e "$RULES_PATH" ] || [ -L "$RULES_PATH" ] || no_rules
[ -r "$RULES_PATH" ] || die "rules file not readable: $RULES_PATH"
command -v jq >/dev/null 2>&1 || die "jq required"
RULES=$(mktemp) || die "mktemp failed"
trap 'rm -f "$RULES"' EXIT
cp "$RULES_PATH" "$RULES" || die "could not snapshot rules file: $RULES_PATH"
chmod 400 "$RULES" || die "could not protect rules snapshot"
VERIFIED_HARNESSES=$(fm_control_harnesses | jq -Rsc 'split("\n") | map(select(length > 0))')

# The fields this tool consumes must be well formed; bootstrap owns the wider
# schema diagnostic, but an intake never selects around a malformed file.
rules_err=$(jq -r --argjson verified_harnesses "$VERIFIED_HARNESSES" --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" --argjson defs "$QUESTION_DEFS" '
  def match_bad($m):
    ($m | type) != "object" or ($m | length) == 0
    or any($m | to_entries[]; . as $e |
      ($defs | has($e.key) | not) or ($e.value | type) != "array" or ($e.value | length) == 0
      or any($e.value[]; . as $v | ($v | type) != "string" or ($defs[$e.key].criteria | has($v) | not)));
  def verified($h): $verified_harnesses | index($h);
  def provider_id($p): ($p | type) == "string" and ($p | test($provider_re));
  def effort_ok($h; $m; $e):
    if $e == null then true
    elif ($e | type) != "string" then false
    elif $e == "ultra" then (($h == "pi" or $h == "pi-signed") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
    elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "codex" then ((["low","medium","high","xhigh"] | index($e)) != null or ($e == "max" and $m == "gpt-5.6-luna"))
    elif $h == "grok" or $h == "agy" then (["low","medium","high"] | index($e)) != null
    elif $h == "pi" or $h == "pi-signed" or $h == "omp" or $h == "muse" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "rovo" then (["low","medium","high","max"] | index($e)) != null
    elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
    else true end;
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def floor_bad($f; $need_provider):
    ($f | type) != "object"
    or (($f.scope | type) != "string") or (($f.scope | length) == 0)
    or (($f.min_percent | type) != "number") or ($f.min_percent < 0) or ($f.min_percent > 100)
    or (if $need_provider
        then (provider_id($f.provider) | not)
        else ($f | has("provider"))
        end);
  def profile_bad($p):
    ($p | type) != "object"
    or (($p.harness | type) != "string") or (($p.harness | length) == 0)
    or ($p | has("model") and ((.model | type) != "string" or (.model | length) == 0))
    or ($p | has("effort") and ((.effort | type) != "string" or (.effort | length) == 0))
    or ($p | has("provider") and (provider_id(.provider) | not))
    or ($p | has("floor") and floor_bad(.floor; false));
  def duplicate_profiles($items):
    ($items | map([.harness, (.model // null), (.effort // null)] | @json)) as $keys
    | ($keys | length) != ($keys | unique | length);
  if type != "object" then "top-level value must be an object"
  elif has("rules") and (.rules | type) != "array" then "rules must be an array"
  elif any((.rules // [])[]; type != "object") then "each rule must be an object"
  elif any((.rules // [])[]; (.when | type) != "string" or (.when | length) == 0) then "each rule needs non-empty when"
  elif any((.rules // [])[]; (profiles(.use) | length) == 0) then "each rule needs at least one use profile"
  elif any((.rules // [])[]; has("approval") and .approval != "captain") then "approval must be \"captain\" when present"
  elif any((.rules // [])[]; has("match") and match_bad(.match)) then
    "match must map " + ($defs | keys_unsorted | join(", ")) + " to non-empty lists of that question\u0027s own answers"
  elif any((.rules // [])[]; has("select") and ((.select | type) != "string" or (.select | length) == 0)) then "select must be a non-empty string"
  elif any((.rules // [])[]; has("select") and .select != "quota-balanced") then
    "unknown select: " + ([.rules[] | select(has("select") and .select != "quota-balanced") | .select] | unique | join(", "))
  elif any((.rules // [])[]; has("floor") and floor_bad(.floor; true)) then "rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\\z"
  elif any((.rules // [])[] | profiles(.use)[]; profile_bad(.)) then "each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif any((.rules // [])[]; duplicate_profiles(profiles(.use))) then "each rule use must not contain duplicate harness, model, and effort profiles"
  elif any((.rules // [])[] | profiles(.use)[]; (verified(.harness) | not)) then "each use profile must name a verified harness"
  elif any((.rules // [])[] | profiles(.use)[]; (effort_ok(.harness; .model; .effort) | not)) then "each use profile effort must be supported by its harness and model"
  elif has("default") and (profiles(.default) | length) == 0 then "default must be a profile object or non-empty profile array"
  elif has("default") and any(profiles(.default)[]; profile_bad(.)) then "each default profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif has("default") and duplicate_profiles(profiles(.default)) then "default must not contain duplicate harness, model, and effort profiles"
  elif has("default") and any(profiles(.default)[]; (verified(.harness) | not)) then "each default profile must name a verified harness"
  elif has("default") and any(profiles(.default)[]; (effort_ok(.harness; .model; .effort) | not)) then "each default profile effort must be supported by its harness and model"
  else empty end
' "$RULES" 2>/dev/null) || die "malformed rules file: $RULES_PATH (not JSON)"
[ -z "$rules_err" ] || die "malformed rules file: $RULES_PATH - $rules_err"

missing_provider=$(jq -r '
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  ((.rules // [])[] | profiles(.use)[] | select(has("provider") | not) | "use\t\(.harness)"),
  (profiles(.default // null)[] | select(has("provider") | not) | "default\t\(.harness)")
' "$RULES" | while IFS=$'\t' read -r location harness; do
  if ! fm_quota_single_provider_for_harness "$harness" >/dev/null; then
    printf '%s\t%s\n' "$location" "$harness"
    break
  fi
done)
if [ -n "$missing_provider" ]; then
  IFS=$'\t' read -r location harness <<< "$missing_provider"
  die "malformed rules file: $RULES_PATH - $location profiles whose harness lacks one authoritative provider family require provider: $harness"
fi

# ---- harness -> provider map, from the single owner in fm-quota-axi-lib.sh -----
PMAP='{}'
while IFS= read -r h; do
  [ -n "$h" ] || continue
  p=$(fm_quota_single_provider_for_harness "$h" 2>/dev/null) || p=''
  PMAP=$(jq -c --arg h "$h" --arg p "$p" '. + {($h): (if $p == "" then null else $p end)}' <<<"$PMAP")
done < <(jq -r '
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  ([((.rules // [])[]) | profiles(.use)[]] + profiles(.default // null))
  | map(.harness) | unique | .[]' "$RULES")

RULE_COUNT=$(jq -r '(.rules // []) | length' "$RULES")

emit_error() {
  local reason=$1
  record "$(jq -n --arg reason "$reason" --argjson lat "${FM_JEV_LATENCY_MS:-null}" '{status: "error", reason: $reason, latency_ms: $lat}' 2>/dev/null)"
  echo "dispatch-resolve: error ($reason)" >&2
  printf 'dispatch-resolve:\n  status: error\n  reason: %s\n' "$reason"
  exit 0
}

if [ "$RULE_COUNT" -eq 0 ]; then
  no_rules
fi

JEV_STATE=$(mktemp) || die "mktemp failed"
JEV_CRITERIA=$(mktemp) || { rm -f "$JEV_STATE"; die "mktemp failed"; }
QUOTA=$(mktemp) || { rm -f "$JEV_STATE" "$JEV_CRITERIA"; die "mktemp failed"; }
trap 'rm -f "$RULES" "$JEV_STATE" "$JEV_CRITERIA" "$QUOTA"' EXIT
# Only the task part of a scaffolded brief describes the work; the rest is the
# same standing text on every task. A brief with no `# Task` section goes whole.
TASK_TEXT=$(fm_brief_heading_body "$BRIEF" "# Task" 2>/dev/null) || TASK_TEXT=''
case "$TASK_TEXT" in
  *[![:space:]]*) ;;
  *) TASK_TEXT=$(cat "$BRIEF") || emit_error "request could not be built" ;;
esac
jq -n --arg brief "$TASK_TEXT" --arg project "$PROJECT" \
  '{task: {project: $project, brief: $brief}}' > "$JEV_STATE" || emit_error "request could not be built"
jq --arg none_criterion "$DEFAULT_WHEN" --argjson defs "$QUESTION_DEFS" \
  --arg rule_instructions "Which ONE dispatch rule best fits \`task\` (read \`task.brief\` and \`task.project\`)? Each option is the rule's own matching condition; pick \`default\` when no rule's condition is met, including when a rule's own exemption text excludes this task." '
  {rule: {instructions: $rule_instructions, criteria: (
    (.rules | to_entries | map({key: ("rule_" + ((.key + 1) | tostring)), value: .value.when}) | from_entries)
    + {default: $none_criterion})}} + (if any(.rules[]; has("match")) then $defs else {} end)' "$RULES" > "$JEV_CRITERIA" || emit_error "request could not be built"
fm_jev_choices "$JEV_CRITERIA" "$JEV_STATE" rule || emit_error "$FM_JEV_ERROR"
LAT_MS=$FM_JEV_LATENCY_MS

# ---- quota evidence: one quota-axi --json snapshot -----------------------------
command -v quota-axi >/dev/null 2>&1 || emit_error "quota-axi not installed"
quota-axi --json > "$QUOTA" 2>/dev/null || emit_error "quota-axi --json failed"
fm_quota_json_valid < "$QUOTA" || emit_error "quota-axi --json returned an invalid snapshot"

# ---- resolution: declared gates + quota evidence + argmax, all in jq ------------
RESULT=$(jq -n --arg floor "$CONFIDENCE_FLOOR" --argjson lat "$LAT_MS" --arg none_criterion "$DEFAULT_WHEN" --argjson pmap "$PMAP" \
  --argjson jev "$FM_JEV_ANSWERS" --argjson defs "$QUESTION_DEFS" --slurpfile rules "$RULES" --slurpfile quota "$QUOTA" '
  $jev as $r | ($rules[0]) as $cfg | ($quota[0]) as $q | ($jev.answers.rule) as $a |
  ($floor | tonumber) as $fl |
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def prov($p): ([$q.providers[] | select(.provider == $p)] | first) // null;
  def rows($p): (prov($p) | .quotaSemantics.effectiveAvailability // []);
  def bare($m): ($m | split("/") | last);
  def provider_of($c): ($c.provider // $pmap[$c.harness] // null);
  def measured($p):
    (prov($p) != null and (["known", "partial"] | index(prov($p).quotaSemantics.status)) != null);
  def applicable($p; $m):
    (bare($m)) as $bare |
    [rows($p)[] | select(
      .scope == "all_models" or .scope == "all_products" or
      ($m != "" and (.scope == ("model:" + $bare) or .scope == ("product:" + $bare)))
    )];
  def floor_state($f; $p):
    if $f == null then "none"
    elif prov($p) == null or (measured($p) | not) then "unknown"
    else [rows($p)[] | select(.scope == $f.scope)] as $matches
      | if ($matches | length) == 0 or any($matches[]; .status != "known") then "unknown"
        elif any($matches[]; .effectivePercentRemaining < $f.min_percent) then "below"
        else "ok"
        end
    end;
  def evidence($rows):
    $rows | map({scope, status, pct: (.effectivePercentRemaining // null), runway: (.runway.status // null), spendPriority: (.selection.spendPriority // null)});
  def evaluate($c):
    (provider_of($c)) as $p |
    if $p == null then {profile: $c, eligible: false, reason: "no provider family for harness \($c.harness); declare provider on the profile"}
    elif prov($p) == null then {profile: $c, provider: $p, eligible: true, unranked: true, reason: "provider \($p) not in the quota snapshot"}
    else
      (applicable($p; ($c.model // ""))) as $rows |
      (evidence($rows)) as $bounds |
      (floor_state($c.floor; $p)) as $profile_floor_state |
      if any($rows[]; (.runway.status // "") == "exhausted_now") then
        ($rows | map(select((.runway.status // "") == "exhausted_now")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: ($bad.effectivePercentRemaining // null), runway: $bad.runway.status, eligible: false, reason: "runway exhausted_now at \($bad.scope)"}
      elif any($rows[]; .status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0) then
        ($rows | map(select(.status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0)) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: false, reason: "0% remaining at \($bad.scope)"}
      elif $profile_floor_state == "below" then
        ([rows($p)[] | select(
          .scope == $c.floor.scope and
          .effectivePercentRemaining < $c.floor.min_percent
        )] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, scope: ($floor_row.scope // $c.floor.scope), pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: false, reason: "profile floor \($c.floor.scope) below \($c.floor.min_percent)%"}
      elif (measured($p) | not) then
        ($rows | first) as $row |
        {profile: $c, provider: $p, bounds: $bounds, scope: ($row.scope // null), pct: ($row.effectivePercentRemaining // null), runway: ($row.runway.status // null), eligible: true, unranked: true, unknown: true, reason: "provider \($p) unmeasured (\(prov($p).quotaSemantics.status))"}
      elif ($rows | length) == 0 then
        {profile: $c, provider: $p, bounds: $bounds, eligible: true, unranked: true, unknown: true, reason: "no applicable quota row for provider \($p)"}
      elif $profile_floor_state == "unknown" then
        ([rows($p)[] | select(.scope == $c.floor.scope)] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, scope: $c.floor.scope, pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: true, unranked: true, unknown: true, reason: "profile floor \($c.floor.scope) is unverifiable: not rankable"}
      elif any($rows[]; .status != "known") then
        ($rows | map(select(.status != "known")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, eligible: true, unranked: true, unknown: true, reason: "quota row \($bad.scope) unknown: not rankable"}
      elif any($rows[]; (.selection.spendPriority | type) != "number") then
        ($rows | map(select((.selection.spendPriority | type) != "number")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: true, unranked: true, reason: "spendPriority missing or non-numeric at \($bad.scope): not rankable"}
      else
        ($rows | min_by(.selection.spendPriority)) as $limiting |
        {profile: $c, provider: $p, bounds: $bounds, scope: $limiting.scope, pct: $limiting.effectivePercentRemaining,
         spendPriority: $limiting.selection.spendPriority, runway: $limiting.runway.status, eligible: true, reason: "ok"}
      end
    end;
  # ---- selection: which option the answers add up to -------------------------
  def round2: (. * 100 | round) / 100;
  def rule_at($k): if $k == "default" then null else $cfg.rules[($k | ltrimstr("rule_") | tonumber) - 1] end;
  # The small answers that cleared the floor; a rule is judged only on these.
  ([$defs | keys_unsorted[] | select($jev.answers[.] != null and $jev.answers[.].confidence >= $fl) | {key: ., value: $jev.answers[.].choice}] | from_entries) as $facts |
  ($a.confidence >= $fl) as $sure |
  def accepts($r): all(($r.match // {}) | to_entries[]; . as $m | ($facts | has($m.key) | not) or ($m.value | index($facts[$m.key])) != null);
  def met($r): (($r.match // {}) | length) > 0 and all($r.match | to_entries[]; . as $m | ($facts | has($m.key)) and ($m.value | index($facts[$m.key])) != null);
  ($a.probabilities | has($a.choice)) as $raw_valid |
  (if $raw_valid | not then [] else
    [$a.probabilities | to_entries[] | {k: .key, p: .value, r: rule_at(.key)}
     | . + {gated: ((.r.approval // "") == "captain"), accepted: (.r != null and accepts(.r)), met: (.r != null and met(.r)),
            outcome: (if .r == null then "default" else {use: (profiles(.r.use) | sort), approval: (.r.approval // null), floor: (.r.floor // null)} end)}]
   end) as $opts |
  # Only an unsure rule answer is narrowed. A rule whose whole declared match is
  # met claims the task, which outranks the generic none option; an
  # approval-gated rule is never dropped.
  (any($opts[]; .met and (.gated | not))) as $claimed |
  ([$opts[] | select($sure or (if .r == null then ($claimed | not) else (.gated or .accepted) end))]) as $kept |
  (($kept | length) < ($opts | length)) as $narrowing |
  ($narrowing and $a.choice != "default" and (any($kept[]; .k == $a.choice) | not)) as $disagree |
  (if $narrowing and ($disagree | not) and (($kept | map(.p) | add) > 0) then $kept else $opts end) as $set |
  ($set | group_by(.outcome) | map({p: (map(.p) | add), top: max_by(.p), claim: (map(select(.met and (.gated | not))) | max_by(.p)), members: map(.k)})) as $groups |
  ($groups | max_by(.p)) as $best_group |
  (($groups | length) < ($opts | length)) as $recount |
  # A none pick set aside by a met match can pass only to a rule that met its own.
  ($a.choice == "default" and ($set | length) > 0 and (any($set[]; .r == null) | not)) as $none_dropped |
  (if $sure and $a.choice == "default" then {choice: $a.choice, confidence: $a.confidence}
   elif $none_dropped and $best_group.claim == null then {choice: $a.choice, confidence: $a.confidence}
   elif $disagree then
     {choice: $a.choice, confidence: $a.confidence,
      disagree: "small answers (\([$facts | to_entries[] | "\(.key)=\(.value)"] | join(", "))) exclude the rule pick \($a.choice)"}
   elif $recount then
     ($groups | length) as $n | ($best_group.p / ($set | map(.p) | add)) as $p |
     (($best_group.members | index($a.choice)) != null) as $raw_in_best |
     {choice: (if $raw_in_best then $a.choice elif $none_dropped then $best_group.claim.k else $best_group.top.k end),
      # Fewer answers raise the even-split baseline, so the confidence of the
      # rule answer stands whenever recounting would only lower it.
      confidence: ([(if $n < 2 then $p else ($p - 1 / $n) / (1 - 1 / $n) end | round2),
                    (if $raw_in_best then $a.confidence else 0 end)] | max),
      selection: ([
        (if ($best_group.members | length) > 1 then "\($best_group.members | join("+")) counted as one answer" else empty end),
        (if ($set | length) < ($opts | length) then
           "small answers left \([$set[] | select(.r != null)] | length) of \(($opts | length) - 1) rules"
           + (if any($set[]; .r == null) then "" else " and ruled out the none option" end)
         else empty end),
        "rule answer alone \($a.choice) \($a.confidence)"] | join("; "))}
   else {choice: $a.choice, confidence: $a.confidence} end) as $pick |
  ($pick.choice) as $choice |
  (if ($choice | test("^rule_[1-9][0-9]*$"))
   then ($choice | ltrimstr("rule_") | tonumber)
   else null end) as $rule_number |
  (if $choice == "default" then null
   elif $rule_number != null and $rule_number <= (($cfg.rules // []) | length) then $cfg.rules[$rule_number - 1]
   else null end) as $rule |
  (if $rule == null then "none" else floor_state($rule.floor; $rule.floor.provider) end) as $rule_floor_state |
  (if $choice != "default" and $rule == null then []
   elif $rule == null then profiles($cfg.default // null)
   else profiles($rule.use)
   end) as $answer_use |
  (if $choice != "default" and $rule == null then {invalid: "rule \($choice) is not in the rules file"}
   elif $rule == null then {source: "default", use: profiles($cfg.default // null), note: "no rule matched"}
   elif ($rule.approval // "") == "captain" then {source: $choice, escalate: "rule requires the captain'"'"'s explicit approval before dispatch"}
   elif $rule_floor_state == "unknown" then {source: $choice, escalate: "rule \($choice) floor \($rule.floor.provider)/\($rule.floor.scope) is unverifiable"}
   elif $rule_floor_state == "below"
     then {source: "default", use: profiles($cfg.default // null), note: "rule \($choice) floor \($rule.floor.scope) below \($rule.floor.min_percent)%: fall through to default"}
   else {source: $choice, use: profiles($rule.use), note: "rule matched"} end) as $sel |
  {
    model: $r.model, latency_ms: $lat, tokens: ($r.usage // null),
    rule: $choice,
    rule_when: (if $rule == null then $none_criterion else $rule.when end | .[0:60]),
    confidence: $pick.confidence, probabilities: $a.probabilities,
    raw: ($a | {choice, confidence}),
    questions: ($defs | with_entries(.key as $k | select($jev.answers | has($k)) | .value = ($jev.answers[$k] | if . == null then null else {choice, confidence} end)) | if length == 0 then null else . end),
    selection: ($pick.selection // null)
  } as $ev |
  if $sel.invalid then $ev + {status: "error", reason: $sel.invalid}
  elif $pick.disagree then
    $ev + {status: "ambiguous", reason: $pick.disagree, candidates: ($answer_use | map(evaluate(.)))}
  elif $pick.confidence < $fl then
    $ev + {status: "ambiguous", reason: "confidence \($pick.confidence) below floor \($floor)", candidates: ($answer_use | map(evaluate(.)))}
  elif $sel.escalate then
    $ev + {status: "escalate", reason: $sel.escalate, candidates: ($answer_use | map(evaluate(.)))}
  elif ($sel.use | length) == 0 then $ev + {status: "escalate", reason: "no profiles configured for \($sel.source)", note: $sel.note, candidates: []}
  else
    ($sel.use | map(evaluate(.))) as $cands |
    ([$cands[] | select(.eligible and ((.unranked // false) | not))]) as $elig |
    ([$cands[] | select(.unranked)]) as $unranked |
    if ($elig | length) == 0 then $ev + {status: "escalate", reason: "no rankable eligible candidate", note: $sel.note, candidates: $cands}
    else
      ($elig | max_by(.spendPriority)) as $best |
      ([$elig[] | select(.spendPriority == $best.spendPriority)] | length) as $ties |
      if $ties > 1 then $ev + {status: "escalate", reason: "genuine spendPriority tie", note: $sel.note, candidates: $cands}
      else $ev + {status: "clear", note: $sel.note, candidates: $cands, chosen: $best}
        + (if ($unranked | length) > 0 then
             {unranked_note: "\($unranked | length) eligible candidate(s) unranked (\([$unranked[].provider] | unique | join(", ")))"}
           else {} end)
      end
    end
  end') || emit_error "resolution failed"

TEXT=$(jq -r '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($value): ($value // "-") | flat;
  def shell_arg: flat | @sh;
  "dispatch-resolve:",
  "  status: \(.status | flat)",
  "  model: \(show(.model))   latency_ms: \(show(.latency_ms))   tokens: \(show(.tokens.input_tokens))/\(show(.tokens.output_tokens))",
  "  rule: \(.rule | flat) (\(.rule_when | flat))   confidence: \(.confidence | flat)",
  "  probabilities: \([.probabilities | to_entries[] | "\(.key | flat)=\(.value | flat)"] | join(" "))",
  (if .questions then "  questions: \([.questions | to_entries[] | "\(.key | flat)=" + (if .value == null then "unusable" else "\(.value.choice | flat)(\(.value.confidence | flat))" end)] | join(" "))" else empty end),
  (if .selection then "  selection: \(.selection | flat)" else empty end),
  (if .reason then "  reason: \(.reason | flat)" else empty end),
  (if .note then "  note: \(.note | flat)" else empty end),
  (if .unranked_note then "  note: \(.unranked_note | flat)" else empty end),
  (.candidates[]? | "  candidate: \(.profile.harness | flat):\(show(.profile.model))"
      + (if .provider then "  provider=\(.provider | flat)" else "" end)
      + (if .scope then "  scope=\(.scope | flat)  remaining=\(show(.pct))%  spendPriority=\(show(.spendPriority))  runway=\(show(.runway))" else "" end)
      + (if (.bounds // [] | length) > 1 then "  bounds=" + ([.bounds[] | "\(.scope | flat):\(show(.pct))%/\((.runway // .status) | flat)"] | join(",")) else "" end)
      + "  -> " + (if .unranked then "eligible, unranked: \(.reason | flat): disclosed uncertainty" elif .eligible then "eligible" else "not eligible: \(.reason | flat)" end)),
  (if .chosen then "  profile: --harness \(.chosen.profile.harness | shell_arg)"
      + (if .chosen.profile.model then " --model \(.chosen.profile.model | shell_arg)" else "" end)
      + (if .chosen.profile.effort then " --effort \(.chosen.profile.effort | shell_arg)" else "" end) else empty end)' <<<"$RESULT") || emit_error "output rendering failed"
record "$RESULT"
printf '%s\n' "$TEXT"
exit 0
