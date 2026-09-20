#!/usr/bin/env bash
# tests/fm-classify-status-timestamp.test.sh - a worker append now carries a
# UTC timestamp bracket ("[YYYY-MM-DDTHH:MM:SSZ]") as the first thing after
# the verb's colon, so "how long has this been waiting" can be answered from
# the log itself instead of the file's last-write mtime. This drives the real
# status_line_note/status_line_timestamp/status_open_decisions functions
# (bin/fm-classify-lib.sh) to pin two things: a timestamped line still folds
# and reads exactly like its pre-timestamp shape (an old log keeps parsing),
# and the timestamp itself comes back out cleanly in both the keyed and
# keyless positions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-status-timestamp-tests)

case_dir() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

test_timestamp_round_trips_and_note_stays_clean() {
  local line ts note theverb
  line='done: [2026-09-20T14:32:05Z] fixed the bug'
  ts=$(status_line_timestamp "$line")
  [ "$ts" = "2026-09-20T14:32:05Z" ] || fail "timestamp not recovered: got '$ts'"
  note=$(status_line_note "$line")
  [ "$note" = "fixed the bug" ] || fail "timestamp bracket leaked into the note: got '$note'"
  status_line_verb "$line" theverb
  [ "$theverb" = "done" ] || fail "verb corrupted by a timestamped note: got '$theverb'"
  pass "a timestamped line yields the bare verb, the clean note, and the timestamp"
}

test_timestamp_after_a_before_colon_key() {
  local line ts note
  line='working [key=fix]: [2026-09-20T14:32:05Z] material phase'
  ts=$(status_line_timestamp "$line")
  [ "$ts" = "2026-09-20T14:32:05Z" ] || fail "timestamp not recovered with a keyed line: got '$ts'"
  note=$(status_line_note "$line")
  [ "$note" = "material phase" ] || fail "note not cleaned with a keyed line: got '$note'"
  pass "a timestamp after a before-colon key strips cleanly, leaving the key's own note"
}

test_pre_timestamp_line_still_parses() {
  local line ts note
  line='done: fixed the bug'
  ts=$(status_line_timestamp "$line")
  [ "$ts" = "" ] || fail "an old, untimestamped line reported a timestamp: got '$ts'"
  note=$(status_line_note "$line")
  [ "$note" = "fixed the bug" ] || fail "an old line's note changed: got '$note'"
  pass "a pre-timestamp status line keeps parsing exactly as before"
}

test_bracket_shaped_prose_is_not_mistaken_for_a_timestamp() {
  local line ts note
  line='done: [not-a-timestamp] shipped it'
  ts=$(status_line_timestamp "$line")
  [ "$ts" = "" ] || fail "prose in brackets was read as a timestamp: got '$ts'"
  note=$(status_line_note "$line")
  [ "$note" = "[not-a-timestamp] shipped it" ] || fail "non-timestamp bracket prose was stripped: got '$note'"
  pass "a bracket that is not a UTC timestamp is left as ordinary note prose"
}

test_open_decisions_fold_is_unaffected_by_a_timestamp() {
  local dir expected got
  dir=$(case_dir open-decisions)
  printf 'needs-decision [key=api]: [2026-09-20T14:32:05Z] pick REST or RPC\n' > "$dir/t.status"
  expected=$(printf 'api\tneeds-decision\tpick REST or RPC\n')
  got=$(status_open_decisions "$dir/t.status")
  [ "$got" = "$expected" ] || fail "timestamped needs-decision folded wrong: got '$got' want '$expected'"

  printf 'resolved [key=api]: [2026-09-20T14:40:00Z] answered: REST\n' >> "$dir/t.status"
  got=$(status_open_decisions "$dir/t.status")
  [ "$got" = "" ] || fail "timestamped resolution failed to close the decision: got '$got'"
  pass "a timestamp on a decision-opening or -closing line changes nothing about the open-decisions fold"
}

test_timestamp_round_trips_and_note_stays_clean
test_timestamp_after_a_before_colon_key
test_pre_timestamp_line_still_parses
test_bracket_shaped_prose_is_not_mistaken_for_a_timestamp
test_open_decisions_fold_is_unaffected_by_a_timestamp
