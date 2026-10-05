#!/usr/bin/env bash
# Behavioral tests for bin/fm-pr-state.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pr-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-state-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
command -v jq >/dev/null 2>&1 \
  || fail "these tests run the script's own jq programs over API-shaped JSON with the real jq, which was not found"

HEAD=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
OLD_HEAD_1=2710bc5efc936efb70e95b86ca3582e9da7e60f4
OLD_HEAD_2=4dc2291e6969de1bf204fbdb53c9e57a8353d4e2

# The fake gh answers every query with the JSON shape GitHub returns and runs
# the --jq program it received with the real jq, so field selection is what is
# under test. The pull-request object speaks GitHub's own vocabulary: an
# uppercase state with MERGED as its own value, and a null mergeable while
# GitHub is still computing one.
# It evaluates with the local jq, while gh itself embeds gojq; the live guard in
# tests/fm-pr-state-live-e2e.test.sh runs the real engine.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -o pipefail
head=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
serve() {
  case "$*" in
    "pr view "*" --json state,mergedAt,isDraft,headRefOid,author,mergeable,reviewDecision --jq "*)
      jq -n --arg head "$head" --arg state "${FM_TEST_STATE-OPEN}" \
        --arg merged "${FM_TEST_MERGED_AT-}" --arg draft "${FM_TEST_DRAFT-false}" \
        --arg mergeable "${FM_TEST_VIEW_MERGEABLE-MERGEABLE}" \
        --arg decision "${FM_TEST_VIEW_REVIEW_DECISION-APPROVED}" \
        '{state: $state, mergedAt: (if $merged == "" then null else $merged end),
          isDraft: ($draft == "true"), headRefOid: $head,
          author: {login: "prauthor", is_bot: false},
          mergeable: (if $mergeable == "null" then null else $mergeable end),
          reviewDecision: $decision}'
      ;;
    "api /repos/o/r/pulls/7/reviews?per_page=100 --paginate --jq "*)
      printf '%s\n' "${FM_TEST_REVIEWS:-[]}"
      ;;
    "pr checks "*" --required --json name,state,bucket --jq "*)
      if [ -n "${FM_TEST_CHECKS_ERROR-}" ]; then
        printf '%s\n' "$FM_TEST_CHECKS_ERROR" >&2
        exit 1
      fi
      checks='[{"name":"lint","state":"SUCCESS","bucket":"pass","workflow":"ci"},{"name":"optional","state":"SKIPPED","bucket":"skipping","workflow":"ci"}]'
      printf '%s\n' "${FM_TEST_REQUIRED_CHECKS:-$checks}"
      ;;
    "api -X GET /repos/o/r/commits/$head/check-runs -f check_name="*" -f filter=all -f per_page=100 --jq "*)
      printf '%s\n' "${FM_TEST_HEAD_RUNS:-{\"check_runs\":[]\}}"
      ;;
    "run view --job 41 --log-failed -R o/r")
      printf '%s\n' "${FM_TEST_LOG-}"
      ;;
    "pr view "*" --json baseRefName --jq .baseRefName")
      printf '{"baseRefName":"main"}\n'
      ;;
    "api -X GET /repos/o/r/commits/main/check-runs -f check_name="*" --jq "*)
      printf '%s\n' "${FM_TEST_BASE_RUNS:-{\"check_runs\":[]\}}"
      ;;
    *)
      printf 'unexpected gh call: %s\n' "$*" >&2
      exit 91
      ;;
  esac
}
[ -z "${FM_TEST_GH_CALLS-}" ] || printf '%s key=%s\n' "$*" "${TYPESAFE_API_KEY-}" >> "$FM_TEST_GH_CALLS"
prog=
prev=
for arg in "$@"; do
  [ "$prev" != --jq ] || prog=$arg
  prev=$arg
done
if [ -n "$prog" ]; then serve "$@" | jq -r "$prog"; else serve "$@"; fi
SH
chmod +x "$FAKEBIN/gh"

# Every run is pinned to a fixture home with no key in the environment, so no
# real key can load and the sort stays off unless a test turns it on.
HOME_OFF="$TMP_ROOT/home-off"
HOME_ON="$TMP_ROOT/home-on"
mkdir -p "$HOME_OFF" "$HOME_ON/config"
printf 'TYPESAFE_API_KEY=fixture-key\n' > "$HOME_ON/.env"
GH_CALLS="$TMP_ROOT/gh-calls"
JEV_CALLS="$TMP_ROOT/jev-calls"
JEV_STATE="$TMP_ROOT/jev-state"
FAILING='[{"name":"CI Status","state":"FAILURE","bucket":"fail","workflow":"ci"},{"name":"slow","state":"IN_PROGRESS","bucket":"pending","workflow":"ci"}]'
RUN_URL=https://github.com/o/r/actions/runs
FAILED_RUN='{"check_runs":[{"id":41,"status":"completed","conclusion":"failure","details_url":"'$RUN_URL'/5/job/41","app":{"slug":"github-actions"}}]}'
passed_too() {  # <run-id of a passing run of the same check>
  jq -c --arg url "$RUN_URL/$1/job/40" '.check_runs += [{id: 40, status: "completed", conclusion: "success", details_url: $url, app: {slug: "github-actions"}}]' <<<"$FAILED_RUN"
}

run_state() {
  env -u TYPESAFE_API_KEY FM_HOME="${FM_TEST_HOME:-$HOME_OFF}" PATH="$FAKEBIN:$PATH" \
    "$SCRIPT" "$@" https://github.com/o/r/pull/7
}

# Runs fm_check_sort over one failed check with fm_jev_choice replaced at the
# library boundary. STUB_CHOICE and STUB_CONF are the answer; STUB_FAIL makes
# the call an error. Each call's state lands in $JEV_STATE.
run_sort() {
  rm -f "$GH_CALLS" "$JEV_CALLS" "$JEV_STATE"
  # shellcheck disable=SC2016 # The inner shell expands its own variables.
  env -u TYPESAFE_API_KEY FM_TEST_GH_CALLS="$GH_CALLS" JEV_CALLS="$JEV_CALLS" JEV_STATE="$JEV_STATE" \
    PATH="$FAKEBIN:$PATH" bash -c '
      set -eu
      # shellcheck source=/dev/null
      . "$1"
      fm_jev_choice() {
        echo "$1" >> "$JEV_CALLS"
        cat "$3" > "$JEV_STATE"
        jq -e "has(\"code_bug\") and has(\"flaky\") and has(\"environment\") and has(\"unclear\") and length == 4" "$4" >/dev/null
        [ -z "${STUB_FAIL:-}" ] || { FM_JEV_STATUS=error; return 1; }
        FM_JEV_ANSWER=$(jq -cn --arg c "${STUB_CHOICE:-code_bug}" --argjson k "${STUB_CONF:-0.9}" "{choice: \$c, confidence: \$k}")
      }
      printf "%s\n" "${FAILED_NAMES:-CI Status}" | fm_check_sort "$2" o/r "$3" https://github.com/o/r/pull/7
    ' _ "$ROOT/bin/fm-check-sort-lib.sh" "${FM_TEST_HOME:-$HOME_ON}" "$HEAD"
}
jev_calls() { [ -f "$JEV_CALLS" ] && wc -l < "$JEV_CALLS" | tr -d ' ' || echo 0; }

# reviews "<login> <state> <commit> <submitted_at>"... prints the JSON array
# GitHub's reviews endpoint returns for those submissions.
reviews() {
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(. != "") | split(" +"; "")
    | {user: {login: .[0], type: .[1]}, state: .[2], commit_id: .[3], submitted_at: .[4]})'
}

test_clean_pr_is_silent_and_ignores_skipped_checks() {
  local out
  out=$(run_state) || fail "clean fixture was refused"
  [ -z "$out" ] || fail "clean fixture should be silent, got: $out"
  pass "a passing required check and a skipped one leave nothing to report"
}

test_terminal_state_is_the_whole_report() {
  local out
  out=$(FM_TEST_STATE=CLOSED FM_TEST_VIEW_MERGEABLE=null run_state) \
    || fail "closed fixture was refused"
  [ "$out" = 'STATE: closed' ] \
    || fail "a closed pull request leaves the author nothing else to read, got: $out"

  out=$(FM_TEST_STATE=MERGED FM_TEST_MERGED_AT=2019-10-04T16:01:04Z \
    FM_TEST_VIEW_MERGEABLE=null FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED run_state) \
    || fail "merged fixture was refused"
  [ "$out" = 'STATE: merged at 2019-10-04T16:01:04Z' ] \
    || fail "a merged pull request says so and reports no blocker after it, got: $out"
  pass "a terminal pull request reports that state and nothing else"
}

test_draft_is_a_blocker() {
  local out
  out=$(FM_TEST_DRAFT=true run_state) || fail "draft fixture was refused"
  assert_contains "$out" 'DRAFT: pull request is not ready for review' \
    "a draft pull request leaves the author something to do"
  pass "draft state blocks readiness"
}

test_stale_blocking_reviews_explain_a_blocking_decision() {
  local out history expected
  history=$(reviews \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_1 2026-09-01T00:15:44Z" \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_2 2026-09-01T23:02:13Z" \
    "commenter User COMMENTED $OLD_HEAD_2 2026-09-01T23:10:00Z" \
    "alice User APPROVED $OLD_HEAD_2 2026-09-01T23:11:00Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "voided-review fixture was refused"
  expected=$(printf 'REVIEW DECISION: CHANGES_REQUESTED\nSTALE BLOCKING REVIEW: coderabbitai[bot] CHANGES_REQUESTED at %s' "$OLD_HEAD_2")
  [ "$out" = "$expected" ] \
    || fail "a stale verdict names the commit it was left at and no head this reading was not verified against, got: $out"
  assert_not_contains "$out" "$OLD_HEAD_1" \
    "a verdict the same reviewer later superseded is history, not a blocker"
  assert_not_contains "$out" 'commenter' \
    "a stale COMMENTED review is informational noise"
  assert_not_contains "$out" 'alice' \
    "a stale approval is not a concrete blocker"
  pass "stale changes-requested verdicts explain a blocking review decision"
}

test_approved_pr_with_only_stale_changes_requested_is_silent() {
  local out history
  history=$(reviews \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_1 2026-09-01T00:15:44Z" \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z" \
    "coderabbitai[bot] Bot APPROVED $HEAD 2026-09-02T14:05:42Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=APPROVED FM_TEST_REVIEWS=$history run_state) \
    || fail "approved stale-review fixture was refused"
  [ -z "$out" ] || fail "an approved PR with only stale review history should be silent, got: $out"
  pass "approved PR ignores stale changes-requested history"
}

test_current_changes_requested_review_is_a_blocker() {
  local out history
  history=$(reviews "coderabbitai[bot] Bot CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "current-review fixture was refused"
  [ "$out" = $'REVIEW DECISION: CHANGES_REQUESTED\nREVIEW: coderabbitai[bot] CHANGES_REQUESTED' ] \
    || fail "a verdict left at the head under review blocks readiness and names no head, got: $out"
  pass "current changes-requested review blocks readiness"
}

test_changes_requested_decision_is_never_silent() {
  local out history
  history=$(reviews \
    "bob User CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z" \
    "bob User COMMENTED $HEAD 2026-09-02T14:05:42Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "comment-after-changes fixture was refused"
  [ "$out" = $'REVIEW DECISION: CHANGES_REQUESTED\nREVIEW: bob CHANGES_REQUESTED' ] \
    || fail "a later COMMENTED review does not clear the reviewer's change request, got: $out"

  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED run_state) \
    || fail "decision-only fixture was refused"
  [ "$out" = 'REVIEW DECISION: CHANGES_REQUESTED' ] \
    || fail "GitHub's blocking decision must be printed even without an explaining review, got: $out"
  pass "a CHANGES_REQUESTED decision is always reported"
}

test_authors_own_changes_requested_review_is_not_a_blocker() {
  local out history
  history=$(reviews "prauthor User CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "self-review fixture was refused"
  assert_not_contains "$out" 'REVIEW: prauthor' \
    "the author's own verdict is not a reviewer blocking them"
  pass "the author's own review is never listed as a blocker"
}

test_pending_approval_is_not_a_blocker() {
  local out
  out=$(FM_TEST_VIEW_REVIEW_DECISION=REVIEW_REQUIRED run_state) \
    || fail "review-required fixture was refused"
  [ -z "$out" ] || fail "awaiting approval is not a blocker this command reports, got: $out"
  pass "a pending approval is not reported as a blocker"
}

test_required_failure_is_a_blocker() {
  local out
  out=$(FM_TEST_REQUIRED_CHECKS='[{"name":"CI Status","state":"FAILURE","bucket":"fail","workflow":"ci"},{"name":"lint","state":"SUCCESS","bucket":"pass","workflow":"ci"}]' run_state) \
    || fail "blocked fixture was refused"
  assert_contains "$out" 'REQUIRED CHECK: CI Status (FAILURE)' \
    "required failure was not reported"
  assert_not_contains "$out" 'lint' \
    "a passing required check is not a blocker"
  pass "required failure blocks readiness"
}

test_failed_check_sort_is_off_unless_asked_for() {
  local out
  rm -f "$GH_CALLS" "$TMP_ROOT/curl-calls"
  cat > "$FAKEBIN/curl" <<'SH'
#!/bin/sh
echo called >> "$FM_TEST_CURL_CALLS"
exit 7
SH
  chmod +x "$FAKEBIN/curl"
  printf 'o/r\n' > "$HOME_ON/config/jev-code-projects"
  out=$(FM_TEST_HOME="$HOME_ON" FM_TEST_REQUIRED_CHECKS=$FAILING FM_TEST_HEAD_RUNS=$FAILED_RUN \
    FM_TEST_LOG='assert failed' FM_TEST_GH_CALLS="$GH_CALLS" FM_TEST_CURL_CALLS="$TMP_ROOT/curl-calls" run_state) \
    || fail "blocked fixture was refused"
  rm -f "$FAKEBIN/curl" "$HOME_ON/config/jev-code-projects"
  [ "$out" = "$(printf 'REQUIRED CHECK: CI Status (FAILURE)\nREQUIRED CHECK: slow (IN_PROGRESS)')" ] \
    || fail "without the option the report is exactly the blocker lines, got: $out"
  assert_no_grep 'check-runs' "$GH_CALLS" "without the option no check run is read"
  assert_no_grep 'log-failed' "$GH_CALLS" "without the option no job log is downloaded"
  [ ! -e "$TMP_ROOT/curl-calls" ] || fail "without the option the model is never asked"
  pass "the default call reads and prints what it does without the sort, key and listed repository present"
}

test_failed_check_sort_is_off_without_a_key() {
  local out
  rm -f "$GH_CALLS"
  out=$(FM_TEST_REQUIRED_CHECKS=$FAILING FM_TEST_GH_CALLS="$GH_CALLS" run_state --sort-failed-checks) \
    || fail "blocked fixture was refused"
  [ "$out" = "$(printf 'REQUIRED CHECK: CI Status (FAILURE)\nREQUIRED CHECK: slow (IN_PROGRESS)')" ] \
    || fail "without a key the report is exactly the blocker lines, got: $out"
  ! grep -q 'check-runs\|log-failed' "$GH_CALLS" || fail "without a key nothing more is read from GitHub"
  out=$(FM_TEST_HOME="$HOME_OFF" FM_TEST_HEAD_RUNS=$FAILED_RUN FM_TEST_LOG='boom' run_sort)
  [ -z "$out" ] || fail "without a key the sort prints nothing, got: $out"
  [ "$(jev_calls)" = 0 ] || fail "without a key the model is never asked"
  pass "without a key the report and the GitHub reads are unchanged"
}

test_failed_check_sort_rules_decide_first() {
  local out
  out=$(FM_TEST_HEAD_RUNS=$(passed_too 5) run_sort)
  [ "$out" = 'FAILED CHECK SORT: CI Status: flaky (rule: another attempt of the same run passed)' ] \
    || fail "a check that passed on another attempt of its run is flaky, got: $out"
  assert_no_grep '--log-failed' "$GH_CALLS" "a flaky verdict needs no log"
  out=$(FM_TEST_HEAD_RUNS=$(passed_too 6) FM_TEST_LOG='boom' run_sort)
  [ "$out" = 'FAILED CHECK SORT: CI Status: unknown' ] \
    || fail "a pass from a different run, such as one a pull request edit triggered, is not a retry, got: $out"

  printf 'o/r\n' > "$HOME_ON/config/jev-code-projects"
  out=$(FM_TEST_HEAD_RUNS=$FAILED_RUN \
    FM_TEST_LOG=$(printf 'build\tinstall\t2026-10-06T10:00:00.1234567Z curl: (6) Could not resolve host: registry.example') \
    FM_TEST_BASE_RUNS='{"check_runs":[{"id":9,"status":"completed","conclusion":"failure"}]}' run_sort)
  [ "$out" = 'FAILED CHECK SORT: CI Status: environment (rule: connection error in its log, and it fails on the base branch too)' ] \
    || fail "a connection error on a check the base branch fails too is environment, got: $out"
  [ "$(jev_calls)" = 0 ] || fail "a failure a rule decides is never sent to the model"
  rm -f "$HOME_ON/config/jev-code-projects"
  pass "fixed rules label flaky and environment failures without asking the model"
}

test_failed_check_sort_asks_only_for_a_listed_project() {
  local out log i=0
  log=$(printf 'build\ttest\t2026-10-06T10:00:00.0000000Z not ok - early failure\n'
    while [ "$i" -lt 400 ]; do i=$((i + 1)); printf 'build\ttest\t2026-10-06T10:00:00.0000000Z ok - passing line %s of a long job log\n' "$i"; done
    printf '2026-10-06T10:00:01.0000000Z ECONNRESET\n2026-10-06T10:00:02.0000000Z assertion: expected 2 but got 3 THE-END\n')

  rm -f "$HOME_ON/config/jev-code-projects"
  out=$(FM_TEST_HEAD_RUNS=$FAILED_RUN FM_TEST_LOG=$log run_sort)
  [ "$out" = 'FAILED CHECK SORT: CI Status: unknown' ] \
    || fail "an unclear failure in an unlisted repository is unknown, got: $out"
  [ "$(jev_calls)" = 0 ] || fail "an unlisted repository's log is never sent"

  printf '# o/r\n' > "$HOME_ON/config/jev-code-projects"
  FM_TEST_HEAD_RUNS=$FAILED_RUN FM_TEST_LOG=$log run_sort >/dev/null
  [ "$(jev_calls)" = 0 ] || fail "a commented-out entry does not list the repository"

  printf 'r\no\nother/r\no/r2\n' > "$HOME_ON/config/jev-code-projects"
  out=$(FM_TEST_HEAD_RUNS=$FAILED_RUN FM_TEST_LOG=$log run_sort)
  [ "$out" = 'FAILED CHECK SORT: CI Status: unknown' ] \
    || fail "a bare name or a same-named repository under another owner does not list this one, got: $out"
  [ "$(jev_calls)" = 0 ] || fail "only the exact owner/repo entry lets a repository's log be sent"

  printf '# listed\no/r\n' > "$HOME_ON/config/jev-code-projects"
  out=$(FM_TEST_HEAD_RUNS=$FAILED_RUN FM_TEST_LOG=$log run_sort)
  [ "$out" = 'FAILED CHECK SORT: CI Status: code bug (jev, confidence 0.9)' ] \
    || fail "a confident answer labels the check, got: $out"
  [ "$(jev_calls)" = 1 ] || fail "one unclear failure is one question"
  [ "$(jq -r .check "$JEV_STATE")" = 'CI Status' ] || fail "the state names the check"
  [ "$(jq -r .log_tail "$JEV_STATE")" = "$(printf 'not ok - early failure\nassertion: expected 2 but got 3 THE-END')" ] \
    || fail "only the lines naming a failure are sent, without the job, step, and timestamp columns, got: $(cat "$JEV_STATE")"
  FM_TEST_HEAD_RUNS=$FAILED_RUN FM_TEST_LOG=$(i=0; while [ "$i" -lt 400 ]; do i=$((i + 1)); printf 'error number %s\n' "$i"; done) run_sort >/dev/null
  jq -e '.log_tail | length == 4000 and endswith("error number 400")' "$JEV_STATE" >/dev/null \
    || fail "long evidence is cut to its bound and keeps its end"
  FM_TEST_HEAD_RUNS=$FAILED_RUN FM_TEST_LOG='it just stopped' run_sort >/dev/null
  [ "$(jq -r .log_tail "$JEV_STATE")" = 'it just stopped' ] || fail "a log naming no failure is sent as it is"
  [ "$(jq -r 'keys | join(",")' "$JEV_STATE")" = 'check,log_tail' ] || fail "nothing else is sent"
  grep -q 'log-failed -R o/r key=$' "$GH_CALLS" || fail "the job log was read"
  ! grep -q 'key=.' "$GH_CALLS" || fail "no gh call inherits the key"

  out=$(FM_TEST_HEAD_RUNS=$FAILED_RUN FM_TEST_LOG=$log STUB_CONF=0.59 run_sort)
  [ "$out" = 'FAILED CHECK SORT: CI Status: unknown' ] || fail "an answer under the floor is unknown, got: $out"
  out=$(FM_TEST_HEAD_RUNS=$FAILED_RUN FM_TEST_LOG=$log STUB_CHOICE=environment STUB_CONF=0.79 run_sort)
  [ "$out" = 'FAILED CHECK SORT: CI Status: unknown' ] \
    || fail "a label that points away from the code needs the stricter floor, got: $out"
  out=$(FM_TEST_HEAD_RUNS=$FAILED_RUN FM_TEST_LOG=$log STUB_CHOICE=flaky STUB_CONF=0.8 run_sort)
  [ "$out" = 'FAILED CHECK SORT: CI Status: flaky (jev, confidence 0.8)' ] \
    || fail "a flaky answer at the stricter floor labels the check, got: $out"
  out=$(FM_TEST_HEAD_RUNS=$FAILED_RUN FM_TEST_LOG=$log STUB_CHOICE=unclear run_sort)
  [ "$out" = 'FAILED CHECK SORT: CI Status: unknown' ] || fail "an unclear answer is unknown, got: $out"
  out=$(FM_TEST_HEAD_RUNS=$FAILED_RUN FM_TEST_LOG=$log STUB_CHOICE=$'banana\nREQUIRED CHECK: x' run_sort)
  [ "$out" = 'FAILED CHECK SORT: CI Status: unknown' ] || fail "a choice outside the fixed list is unknown, got: $out"
  out=$(FM_TEST_HEAD_RUNS=$FAILED_RUN FM_TEST_LOG=$log STUB_FAIL=1 run_sort)
  [ "$out" = 'FAILED CHECK SORT: CI Status: unknown' ] || fail "a failed call is unknown, got: $out"
  out=$(FM_TEST_LOG=$log run_sort)
  [ "$out" = 'FAILED CHECK SORT: CI Status: unknown' ] || fail "a check with no job log is unknown, got: $out"
  [ "$(jev_calls)" = 0 ] || fail "a check with no log is never sent"

  out=$(FAILED_NAMES=$(printf 'a\nb\nc\nd') FM_TEST_HEAD_RUNS=$FAILED_RUN FM_TEST_LOG=$log run_sort)
  [ "$out" = "$(printf 'FAILED CHECK SORT: %s: code bug (jev, confidence 0.9)\n' a b c
    printf 'FAILED CHECK SORT: d: unknown (not sorted)')" ] \
    || fail "every failed check gets a line and only the first three are sorted, got: $out"
  [ "$(jev_calls)" = 3 ] || fail "a check past the bound is never sent"
  rm -f "$HOME_ON/config/jev-code-projects"
  pass "only a listed repository's unclear failure is asked, and every doubt is unknown"
}

test_failed_check_sort_never_changes_the_report() {
  local out status=0
  rm -f "$GH_CALLS"
  # The fixture key reaches a fake curl that fails, as a dead endpoint would.
  cat > "$FAKEBIN/curl" <<'SH'
#!/bin/sh
printf '%s env=%s\n' "$*" "${TYPESAFE_API_KEY-}" >> "$FM_TEST_CURL_CALLS"
exit 7
SH
  chmod +x "$FAKEBIN/curl"
  printf 'o/r\n' > "$HOME_ON/config/jev-code-projects"
  out=$(FM_TEST_HOME="$HOME_ON" FM_TEST_REQUIRED_CHECKS=$FAILING FM_TEST_HEAD_RUNS=$FAILED_RUN \
    FM_TEST_LOG='assert failed' FM_TEST_GH_CALLS="$GH_CALLS" FM_TEST_CURL_CALLS="$TMP_ROOT/curl-calls" run_state --sort-failed-checks) || status=$?
  rm -f "$FAKEBIN/curl" "$HOME_ON/config/jev-code-projects"
  [ "$status" -eq 0 ] || fail "a failed model call must not change the exit status"
  [ "$out" = "$(printf 'REQUIRED CHECK: CI Status (FAILURE)\nREQUIRED CHECK: slow (IN_PROGRESS)\nFAILED CHECK SORT: CI Status: unknown')" ] \
    || fail "the blocker lines stay and only the failed check gains a label, got: $out"
  assert_present "$TMP_ROOT/curl-calls" "the model was asked through the shared caller"
  assert_no_grep 'fixture-key' "$TMP_ROOT/curl-calls" "the key reaches neither curl's argv nor its environment"
  assert_no_grep 'fixture-key' "$GH_CALLS" "the key reaches no gh call"
  pass "with the model down the blocker lines are intact and the check is unknown"
}

# The next two cases supply gh's own "nothing reported" sentences through
# FM_TEST_CHECKS_ERROR, so they prove the behaviour GIVEN those strings and
# nothing about the strings themselves. A gh reword is invisible to this
# hermetic suite; only a run against a real gh would catch one.
test_unreported_required_checks_are_unconfirmed() {
  local out status
  out=$(FM_TEST_CHECKS_ERROR="no required checks reported on the 'fm/fixture' branch" run_state) \
    || fail "a head without reported required checks was refused"
  [ "$out" = 'CHECKS: no required check has reported; readiness unconfirmed' ] \
    || fail "a head where nothing required has reported must not pass silently as ready, got: $out"
  # This asserts the branch taken for that sentence, not that gh still says it.

  status=0
  FM_TEST_CHECKS_ERROR='HTTP 502: Bad Gateway' run_state >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "a real check lookup failure must still refuse"
  pass "given gh's sentence, an unreported required check is unconfirmed, other check lookup failures refuse"
}

test_no_reported_checks_is_unverified() {
  local out
  out=$(FM_TEST_CHECKS_ERROR="no checks reported on the 'fm/fixture' branch" run_state) \
    || fail "a head without reported checks was refused"
  [ "$out" = 'CHECKS: none reported yet' ] \
    || fail "a head with no reported checks must read as unverified, not ready, got: $out"
  # This asserts the branch taken for that sentence, not that gh still says it.
  pass "given gh's sentence, a head with no reported checks is unverified rather than ready"
}

test_help_states_what_silence_means_and_what_is_out_of_scope() {
  local out
  out=$("$SCRIPT" --help) || fail "help was refused"
  assert_contains "$out" 'it does not mean the pull request is ready to merge' \
    "help must not let empty output read as a verdict that the pull request can merge"
  assert_contains "$out" 'is absent from what this command reads' \
    "help must name the limit: a required context that never reported is absent from what is read"
  assert_contains "$out" "Unresolved review-thread state is out of this command's scope" \
    "help must state the thread-resolution boundary without inventing a reason for it"
  pass "help states what empty output means and what is out of scope"
}

test_unknown_mergeability_is_a_blocker() {
  local out
  out=$(FM_TEST_VIEW_MERGEABLE=null run_state) \
    || fail "unknown-mergeability fixture was refused"
  assert_contains "$out" 'MERGEABILITY: unknown' \
    "null mergeability must not be treated as clean"

  out=$(FM_TEST_VIEW_MERGEABLE=CONFLICTING run_state) \
    || fail "conflicting fixture was refused"
  assert_contains "$out" 'MERGEABILITY: conflicting' \
    "a conflicting merge state must be reported"
  pass "unknown and conflicting mergeability block readiness"
}

test_refusals_exit_nonzero() {
  local status=0
  PATH="$FAKEBIN:$PATH" "$SCRIPT" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "missing argument refusal exited zero"

  status=0
  PATH="$FAKEBIN:$PATH" "$SCRIPT" not-a-pr >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "lookup refusal exited zero"

  local out
  status=0
  out=$(PATH="$FAKEBIN:$PATH" "$SCRIPT" 7 2>&1) || status=$?
  [ "$status" -ne 0 ] \
    || fail "a bare number resolves against the ambient repository and is not an address"
  assert_contains "$out" 'expected a GitHub pull-request URL' \
    "a bare number must be refused as an address, not attempted as a lookup"
  pass "argument and lookup refusals exit nonzero"
}

test_clean_pr_is_silent_and_ignores_skipped_checks
test_terminal_state_is_the_whole_report
test_draft_is_a_blocker
test_stale_blocking_reviews_explain_a_blocking_decision
test_approved_pr_with_only_stale_changes_requested_is_silent
test_current_changes_requested_review_is_a_blocker
test_changes_requested_decision_is_never_silent
test_authors_own_changes_requested_review_is_not_a_blocker
test_pending_approval_is_not_a_blocker
test_required_failure_is_a_blocker
test_failed_check_sort_is_off_unless_asked_for
test_failed_check_sort_is_off_without_a_key
test_failed_check_sort_rules_decide_first
test_failed_check_sort_asks_only_for_a_listed_project
test_failed_check_sort_never_changes_the_report
test_unreported_required_checks_are_unconfirmed
test_no_reported_checks_is_unverified
test_help_states_what_silence_means_and_what_is_out_of_scope
test_unknown_mergeability_is_a_blocker
test_refusals_exit_nonzero
