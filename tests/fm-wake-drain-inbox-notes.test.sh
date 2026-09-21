#!/usr/bin/env bash
# tests/fm-wake-drain-inbox-notes.test.sh - a captain note (bin/fm-inbox.sh,
# state/inbox/) must keep surfacing on every drain until it is actually read,
# independent of whether its own one-time wake was ever acknowledged. This is
# a portable tests/ regression for the incident: six notes queued while
# firstmate worked, their wakes were drained and acknowledged in the ordinary
# course of handling other work, and the notes themselves sat unread with
# nothing left to remind anyone - until the captain noticed himself.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
INBOX="$ROOT/bin/fm-inbox.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-inbox-notes-tests)

# <dir> is the test case root make_case returns (holding <dir>/state); passing
# only FM_HOME lets fm-inbox.sh resolve its own STATE default (FM_HOME/state),
# the same directory these tests' own $state variable already names.
queue_note() {  # <dir> <text>
  FM_HOME="$1" "$INBOX" note "$2" >/dev/null
}

note_id() {  # <dir>
  FM_HOME="$1" "$INBOX" unread | cut -f1
}

ack_note() {  # <dir> <id>
  FM_HOME="$1" "$INBOX" drain --ack "$2" >/dev/null
}

test_a_wake_acknowledgement_never_clears_an_unread_note() {
  local dir state out id
  dir=$(make_case wake-ack-does-not-clear-note)
  state="$dir/state"
  out="$dir/drain.out"
  queue_note "$dir" "resolve it now"
  id=$(note_id "$dir")

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>"$dir/drain.err" \
    || fail "first drain failed"
  grep -F 'CAPTAIN INBOX NOTES' "$out" >/dev/null \
    || fail "the note's own wake did not surface the CAPTAIN INBOX NOTES section: $(cat "$out")"
  grep -F "$id waiting" "$out" >/dev/null \
    || fail "the note itself was not named in the section: $(cat "$out")"

  ack_drain_err "$state" "$dir/drain.err" \
    || fail "acknowledging the queued wake failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "second drain (after the wake was acked) failed"
  grep -F 'CAPTAIN INBOX NOTES' "$out" >/dev/null \
    || fail "the note vanished once its one-time wake was acknowledged: $(cat "$out")"
  grep -F "$id waiting" "$out" >/dev/null \
    || fail "the unread note itself was dropped after its wake was acked: $(cat "$out")"
  pass "an unhandled note keeps surfacing after its own wake is acknowledged"
}

test_reading_the_note_is_the_only_thing_that_clears_it() {
  local dir state out id
  dir=$(make_case reading-clears-note)
  state="$dir/state"
  out="$dir/drain.out"
  queue_note "$dir" "second thought"
  id=$(note_id "$dir")

  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>"$dir/drain.err" \
    || fail "first drain failed"
  ack_drain_err "$state" "$dir/drain.err" || fail "acking the wake failed"

  ack_note "$dir" "$id"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain after reading the note failed"
  if grep -F 'CAPTAIN INBOX NOTES' "$out" >/dev/null; then
    fail "an actually-read note still printed the unread section: $(cat "$out")"
  fi
  pass "moving a note into handled/ is what actually clears it, nothing else"
}

test_a_note_still_unread_past_the_threshold_grows_louder() {
  local dir state out id old
  dir=$(make_case note-grows-louder)
  state="$dir/state"
  out="$dir/drain.out"
  queue_note "$dir" "getting old"
  id=$(note_id "$dir")
  # Rewrite the note file with an id whose embedded epoch is well past the
  # STILL UNREAD threshold, the way a note genuinely left unread for a while
  # would look - queue_note mints "<epoch>-<random>", and the epoch IS the id.
  old=$(( $(date +%s) - 3600 ))
  mv "$state/inbox/$id.note" "$state/inbox/$old-aged.note"

  FM_STATE_OVERRIDE="$state" FM_INBOX_STALE_SECS=900 "$DRAIN" > "$out" 2>/dev/null \
    || fail "drain over an aged note failed"
  grep -F "STILL UNREAD $old-aged waiting" "$out" >/dev/null \
    || fail "a note past the stale threshold did not grow louder: $(cat "$out")"
  pass "a note still unread past the threshold is marked STILL UNREAD, not shown quietly"
}

test_no_inbox_directory_is_silent() {
  local dir state out
  dir=$(make_case no-inbox-dir)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with no inbox at all"
  if grep -F 'CAPTAIN INBOX NOTES' "$out" >/dev/null; then
    fail "a home with no state/inbox/ directory still printed the notes section: $(cat "$out")"
  fi
  pass "a home with no captain notes at all stays silent on the section"
}

test_an_unreadable_inbox_fails_loudly() {
  local dir state out rc=0
  if [ "$(id -u)" -eq 0 ]; then
    pass "SKIP: root reads a chmod 000 inbox anyway"
    return
  fi
  dir=$(make_case unreadable-inbox)
  state="$dir/state"
  out="$dir/drain.out"
  queue_note "$dir" "resolve it now"
  chmod 000 "$state/inbox"
  FM_HOME="$dir" "$INBOX" unread >/dev/null 2>&1 || rc=$?
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null
  chmod 755 "$state/inbox"
  [ "$rc" -ne 0 ] || fail "fm-inbox.sh unread reported an unreadable inbox as empty"
  grep -F 'CAPTAIN INBOX NOTES INCOMPLETE' "$out" >/dev/null \
    || fail "an unreadable inbox was drained silently: $(cat "$out")"
  pass "an unreadable inbox is a loud failure, never an empty one"
}

test_a_wake_acknowledgement_never_clears_an_unread_note
test_an_unreadable_inbox_fails_loudly
test_reading_the_note_is_the_only_thing_that_clears_it
test_a_note_still_unread_past_the_threshold_grows_louder
test_no_inbox_directory_is_silent
