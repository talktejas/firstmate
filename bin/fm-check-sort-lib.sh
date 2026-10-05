# shellcheck shell=bash
# Advisory sort of a failed required check: code bug, flaky, or environment.
# Usage: . bin/fm-check-sort-lib.sh   (source it before the caller runs any child)
#
# bin/fm-pr-state.sh is the one caller, and only under its
# --sort-failed-checks option. It hands over the required checks it already
# read as failed, and this file prints one extra line per check:
#   FAILED CHECK SORT: <check>: <class> (<why>)
# where <class> is `flaky`, `environment`, `code bug`, or `unknown`. The line is
# a label for the reader. It never re-runs a check, never changes what a check
# reported, and nothing merges, blocks, or discards on it.
#
# The sort runs only when TYPESAFE_API_KEY is available (bin/fm-jev-lib.sh owns
# the key); without it nothing is read and nothing is printed. Fixed rules
# decide first, from GitHub reads alone:
#   1. Another attempt of the same workflow run passed this check on the same
#      head commit, so the same code and the same trigger both passed and
#      failed -> flaky. A pass from a different run does not count, because a
#      check triggered again by a pull request edit saw a different input, and
#      neither does a pass from the same attempt, which is another job that
#      shares the check's name.
#   2. The failed steps' log shows a connection error (FM_CHECK_SORT_MARKERS) and
#      the same check is failing on the base branch, which does not carry this
#      pull request's change -> environment.
# A failure no rule decides goes to Jev as one fixed-choice question over the
# check's name and the log of the job's failed steps. Only the last
# FM_CHECK_SORT_LOG_LINES lines are read; of those, the lines that name a
# failure (FM_CHECK_SORT_EVIDENCE) are sent, or every line when none does, cut
# to the last FM_CHECK_SORT_TAIL_CHARS characters, because a job states its
# failure last and ends in summary lines that say nothing about the cause. A failure log quotes the project's
# code, so it is sent only for a repository fm_jev_code_allowed finds in
# config/jev-code-projects as its exact `<owner>/<repo>`; a bare name there
# never matches a repository. An unlisted repository's unclear failure is
# `unknown` with no call. `unknown` is also the answer for a check with no
# GitHub Actions job log, an unreadable read, a Jev timeout or error, a
# malformed answer, an `unclear` choice, and a confidence under the floor; the
# worker then investigates as it does without the label. `code bug` needs the
# shared FM_JEV_CONFIDENCE_FLOOR. `flaky` and `environment` need the stricter
# FM_CHECK_SORT_AWAY_FLOOR, because those two tell a worker the failure is not
# in its code, and a live call labelled a pull request process failure
# `environment` above the shared floor (docs/verification/failed-check-sort.md).
#
# ponytail: only the first FM_CHECK_SORT_MAX failed checks are sorted, so a
# pull request with many red checks costs a bounded number of reads; each of
# the rest is printed as `unknown (not sorted)` with nothing read.
#
# fm_check_sort <home> <owner/repo> <head-sha> <pr-url>
#   Reads failed check names, one per line, on stdin. Always returns 0.

_FM_CHECK_SORT_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_CHECK_SORT_DIR" != "${BASH_SOURCE[0]}" ] || _FM_CHECK_SORT_DIR=.
# shellcheck source=bin/fm-jev-lib.sh
. "$_FM_CHECK_SORT_DIR/fm-jev-lib.sh"

FM_CHECK_SORT_MAX=3
FM_CHECK_SORT_LOG_LINES=2000
FM_CHECK_SORT_TAIL_CHARS=4000
# A live call labelled a process failure `environment` at 0.65 to 0.73 (docs/verification/failed-check-sort.md).
FM_CHECK_SORT_AWAY_FLOOR=0.8
FM_CHECK_SORT_EVIDENCE='error|fail|not ok|panic|exception|assert|timed out|timeout|refused|denied|killed|cannot|unable'
FM_CHECK_SORT_MARKERS='ECONNREFUSED|ECONNRESET|ETIMEDOUT|EAI_AGAIN|ENOTFOUND|could not resolve host|temporary failure in name resolution|connection (refused|reset|timed out)|TLS handshake timeout|50[234] (bad gateway|service unavailable|gateway time-?out)'
# shellcheck disable=SC2016 # The backticks are literal markup in the question text.
FM_CHECK_SORT_INSTRUCTIONS='An automated check named in `check` failed on a pull request, and `log_tail` holds the last lines of the failed job'"'"'s log that name a failure. Decide from the words of the log why it failed. Choose `unclear` whenever the log does not plainly show one of the other three.'
FM_CHECK_SORT_CRITERIA='{"code_bug":"The log shows the project'"'"'s own code or tests failing on their merits: a compile, type, or lint error, a failed assertion, or a test that fails for a reason in the code.","flaky":"The log shows a failure that depends on timing, ordering, or chance rather than on the code: a race, a timing-dependent assertion, or a test that timed out waiting with no error in the code.","environment":"The log shows the runner or something outside the project failing: a network or connection error, a failed download or dependency install, an unavailable service, a rate limit, a missing credential, or a runner out of disk, memory, or time.","unclear":"The log does not show enough to tell which of the others applies."}'

# Prints "<class> (<why>)" or "unknown" for one failed check.
_fm_check_sort_one() {  # <listed:0|1> <owner/repo> <head-sha> <pr-url> <check-name>
  local listed=$1 repo=$2 head=$3 url=$4 name=$5 runs run passed job log evidence base base_state
  # shellcheck disable=SC2016  # jq variables are literal filter syntax.
  runs=$(gh api -X GET "/repos/$repo/commits/$head/check-runs" \
    -f check_name="$name" -f filter=all -f per_page=100 --jq '
    def run: (.details_url // "") | split("/job/") | .[0] // "";
    ([.check_runs[] | select(.app.slug == "github-actions" and .status == "completed" and .conclusion != "success")]
      | max_by(.id)) as $failed
    | (($failed // {}) | run) as $run
    | ($run | split("/") | last // ""),
      (($failed.id // "") | tostring),
      ([.check_runs[] | select($run != "" and .conclusion == "success" and run == $run) | .id | tostring] | join(" "))' \
    2>/dev/null) || { echo unknown; return 0; }
  {
    IFS= read -r run
    IFS= read -r job
    IFS= read -r passed
  } <<EOF
$runs
EOF
  case "$job" in ''|*[!0-9]*) echo unknown; return 0 ;; esac
  case "$run$passed" in
    ''|*[!0-9\ ]*) ;;
    *)
      if [ -n "$passed" ] && gh api -X GET "/repos/$repo/actions/runs/$run/jobs" -f filter=all -f per_page=100 \
        --jq '.jobs[] | "\(.id) \(.run_attempt)"' 2>/dev/null \
        | awk -v job="$job" -v passed=" $passed " '
          { attempt[$1] = $2 }
          END {
            if (attempt[job] == "") exit 1
            for (id in attempt) if (index(passed, " " id " ") && attempt[id] != "" && attempt[id] != attempt[job]) exit 0
            exit 1
          }'; then
        echo 'flaky (rule: another attempt of the same run passed)'
        return 0
      fi ;;
  esac
  # Each line is "<job>\t<step>\t<timestamp> <text>"; only the text is kept.
  log=$(gh run view --job "$job" --log-failed -R "$repo" 2>/dev/null \
    | tail -n "$FM_CHECK_SORT_LOG_LINES" | cut -f 3- | sed -E 's/^[0-9]{4}-[0-9T:.-]+Z //') || true
  [ -n "$log" ] || { echo unknown; return 0; }
  if printf '%s\n' "$log" | grep -Eiq -- "$FM_CHECK_SORT_MARKERS"; then
    base=$(gh pr view "$url" --json baseRefName --jq .baseRefName 2>/dev/null) || base=
    base_state=
    [ -z "$base" ] || base_state=$(gh api -X GET "/repos/$repo/commits/$base/check-runs" \
      -f check_name="$name" --jq '
      [.check_runs[] | select(.status == "completed")] | max_by(.id) | .conclusion // ""' 2>/dev/null) || base_state=
    case "$base_state" in
      failure|timed_out)
        echo 'environment (rule: connection error in its log, and it fails on the base branch too)'
        return 0 ;;
    esac
  fi
  [ "$listed" -eq 1 ] || { echo unknown; return 0; }
  evidence=$(printf '%s\n' "$log" | grep -Ei -- "$FM_CHECK_SORT_EVIDENCE") || evidence=$log
  fm_jev_choice failed_check "$FM_CHECK_SORT_INSTRUCTIONS" \
    <(printf '%s' "$evidence" | tail -c "$FM_CHECK_SORT_TAIL_CHARS" | jq -Rsc --arg check "$name" '{check: $check, log_tail: .}') \
    <(printf '%s' "$FM_CHECK_SORT_CRITERIA") || { echo unknown; return 0; }
  jq -r --argjson floor "$FM_JEV_CONFIDENCE_FLOOR" --argjson away "$FM_CHECK_SORT_AWAY_FLOOR" '
    if (.choice | IN("code_bug", "flaky", "environment")) and .confidence >= (if .choice == "code_bug" then $floor else $away end)
    then "\(.choice | sub("_"; " ")) (jev, confidence \(.confidence))" else "unknown" end' \
    <<<"$FM_JEV_ANSWER" 2>/dev/null || echo unknown
}

fm_check_sort() {  # <home> <owner/repo> <head-sha> <pr-url>; failed check names on stdin
  local home=$1 repo=$2 head=$3 url=$4 listed=0 name names=() n=0
  while IFS= read -r name; do
    [ -z "$name" ] || names+=("$name")
  done
  [ "${#names[@]}" -gt 0 ] || return 0
  fm_jev_key_load "$home" || return 0
  command -v jq >/dev/null 2>&1 || return 0
  ! FM_HOME=$home fm_jev_code_allowed "$repo" || listed=1
  for name in "${names[@]}"; do
    n=$((n + 1))
    if [ "$n" -gt "$FM_CHECK_SORT_MAX" ]; then
      printf 'FAILED CHECK SORT: %s: unknown (not sorted)\n' "$name"
      continue
    fi
    printf 'FAILED CHECK SORT: %s: %s\n' "$name" \
      "$(_fm_check_sort_one "$listed" "$repo" "$head" "$url" "$name" </dev/null)" || true
  done
  return 0
}
