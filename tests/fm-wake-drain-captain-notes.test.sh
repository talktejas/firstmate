#!/usr/bin/env bash
# tests/fm-wake-drain-captain-notes.test.sh - a note from the captain must reach
# firstmate even when its wake does not. The drain lists every note still
# unacknowledged, read from the notes themselves, with how long each has waited;
# a wake acknowledgement never consumes a waiting note's row and ends by naming
# every waiting note; only bin/fm-inbox.sh drain --ack <id> clears one.
#
# The incident this pins: supervision read the drain through a filter that kept
# only the WAKE_ACK_REQUIRED line, then acknowledged through the printed sequence,
# which consumed eight captain-note wakes nobody had read while the notes stayed
# unacknowledged in state/inbox/ for hours with nothing surfacing them again.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
INBOX_CLI="$ROOT/bin/fm-inbox.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-captain-notes-tests)

queue_note() {  # <state> <text> -> prints the new note id
  FM_STATE_OVERRIDE="$1" "$INBOX_CLI" note "$2" | sed -n 's/^queued //p'
}

# A note exactly as fm-inbox.sh writes one, sent <age> seconds ago and with no
# wake at all: what an older acknowledgement or a failed wake append leaves.
write_old_note() {  # <state> <age-seconds> <suffix> <body> -> prints the id
  local state=$1 epoch id
  epoch=$(( $(date +%s) - $2 ))
  id="$epoch-$3"
  mkdir -p "$state/inbox"
  printf 'id=%s\nat=2026-01-01T00:00:00Z\nsource=text\n--\n%s\n' "$id" "$4" > "$state/inbox/$id.note"
  printf '%s\n' "$id"
}

# Run the printed acknowledgement from a drain's stderr; prints its combined output.
ack_printed() {  # <state> <drain-stderr-file>
  local through generation
  through=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$2" | tail -1)
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$2" | tail -1)
  [ -n "$through" ] && [ -n "$generation" ] || fail "drain printed no acknowledgement: $(cat "$2")"
  FM_STATE_OVERRIDE="$1" "$DRAIN" --ack-through "$through" --recovery-generation "$generation" 2>&1
}

queued_inbox_rows() {  # <state>
  awk -F '\t' '$3 == "check" && $4 ~ /^inbox:/ { print $4 }' "$1/.wake-queue" 2>/dev/null
}

test_note_with_no_wake_is_listed() {
  local dir state out id
  dir=$(make_case no-wake)
  state="$dir/state"
  out="$dir/drain.out"
  id=$(write_old_note "$state" 7210 NoWake "the page shows the wrong total")

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>&1 || fail "drain failed with a wakeless note"

  [ -z "$(queued_inbox_rows "$state")" ] || fail "setup error: the wakeless note has a queued wake"
  grep -F 'CAPTAIN NOTES WAITING (1 from the captain' "$out" >/dev/null \
    || fail "a note with no wake was not listed: $(cat "$out")"
  grep -E "^$id waiting 2h0[0-9]m: the page shows the wrong total$" "$out" >/dev/null \
    || fail "the listing did not state the note and how long it has waited: $(cat "$out")"
  [ "$(tail -1 "$out" | cut -c1-21)" = 'CAPTAIN NOTES WAITING' ] \
    || fail "the listing is not the last thing the drain prints: $(cat "$out")"
  [ -f "$state/inbox/$id.note" ] || fail "presenting the note acknowledged it"
  pass "a note with no wake at all is listed from the note itself with how long it waited"
}

test_filtered_drain_cannot_acknowledge_a_note() {
  local dir state err ack id
  dir=$(make_case filtered-incident)
  state="$dir/state"
  err="$dir/drain.err"
  append_wake "$state" signal "$state/task1.status" "signal: $state/task1.status" \
    || fail "could not queue the unrelated wake"
  id=$(queue_note "$state" "why do you keep ignoring my messages")
  [ -n "$id" ] || fail "fm-inbox.sh note queued nothing"
  [ "$(queued_inbox_rows "$state")" = "inbox:$id" ] || fail "setup error: the note queued no wake"

  # The incident: the drain's whole output is thrown away except the ack line.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > /dev/null 2> "$err" || fail "presentation drain failed"
  ack=$(ack_printed "$state" "$err") || fail "acknowledgement failed: $ack"

  [ "$(queued_inbox_rows "$state")" = "inbox:$id" ] \
    || fail "the acknowledgement consumed the unread note's wake: $(cat "$state/.wake-queue")"
  if grep -F "$state/task1.status" "$state/.wake-queue" >/dev/null; then
    fail "the unrelated wake was not acknowledged alongside the held note"
  fi
  case "$(printf '%s\n' "$ack" | tail -1)" in
    "CAPTAIN NOTES HELD: 1 note(s)"*"$id (waiting "*"bin/fm-inbox.sh drain --ack <id>") ;;
    *) fail "the acknowledgement's last line does not name the held note: $ack" ;;
  esac
  [ -f "$state/inbox/$id.note" ] || fail "a wake acknowledgement acknowledged the captain's note"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/again.out" 2>&1 || fail "second drain failed"
  grep -F "inbox:$id" "$dir/again.out" >/dev/null \
    || fail "the held note's wake was not presented again: $(cat "$dir/again.out")"
  grep -F "$id waiting" "$dir/again.out" >/dev/null \
    || fail "the held note was not listed again: $(cat "$dir/again.out")"
  pass "a drain whose output is discarded cannot acknowledge a captain note, and says so on the ack's last line"
}

test_note_whose_wake_was_already_acknowledged() {
  local dir state err ack id
  dir=$(make_case wake-already-acked)
  state="$dir/state"
  err="$dir/drain.err"
  id=$(queue_note "$state" "store it as 12.34")
  # What the acknowledgement did before this fix: the wake row is gone while
  # the note is still unacknowledged.
  : > "$state/.wake-queue"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2>&1 || fail "empty-queue drain failed"
  grep -F "$id waiting" "$dir/drain.out" >/dev/null \
    || fail "a note whose wake was already consumed was not listed: $(cat "$dir/drain.out")"

  append_wake "$state" signal "$state/task2.status" "signal: $state/task2.status" \
    || fail "could not queue the unrelated wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/next.out" 2> "$err" || fail "next drain failed"
  grep -F "$id waiting" "$dir/next.out" >/dev/null \
    || fail "the note was not listed beside an unrelated wake: $(cat "$dir/next.out")"
  ack=$(ack_printed "$state" "$err") || fail "acknowledgement failed: $ack"
  case "$(printf '%s\n' "$ack" | tail -1)" in
    "CAPTAIN NOTES HELD: 1 note(s)"*"$id (waiting "*) ;;
    *) fail "the acknowledgement did not name the note it cannot clear: $ack" ;;
  esac
  [ -f "$state/inbox/$id.note" ] || fail "the note was acknowledged by an unrelated wake acknowledgement"
  pass "a note whose wake was already acknowledged is still listed and still named at every acknowledgement"
}

test_notes_of_different_ages_are_listed_oldest_first() {
  local dir state out old mid new lines
  dir=$(make_case ages)
  state="$dir/state"
  out="$dir/drain.out"
  new=$(write_old_note "$state" 20 NewOne "newest words")
  old=$(write_old_note "$state" 259500 OldOne "oldest words")
  mid=$(write_old_note "$state" 5410 MidOne "middle words")

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>&1 || fail "drain failed with several notes"

  grep -F 'CAPTAIN NOTES WAITING (3 from the captain' "$out" >/dev/null \
    || fail "the listing did not count all three notes: $(cat "$out")"
  lines=$(grep -E ' waiting [^:]+: ' "$out")
  [ "$(printf '%s\n' "$lines" | awk 'END { print NR }')" = 3 ] || fail "expected three note lines: $lines"
  printf '%s\n' "$lines" | sed -n 1p | grep -E "^$old waiting 3d00h: oldest words$" >/dev/null \
    || fail "the oldest note is not first with its wait in days: $lines"
  printf '%s\n' "$lines" | sed -n 2p | grep -E "^$mid waiting 1h3[0-9]m: middle words$" >/dev/null \
    || fail "the middle note is not second with its wait in hours: $lines"
  printf '%s\n' "$lines" | sed -n 3p | grep -E "^$new waiting [0-9]+s: newest words$" >/dev/null \
    || fail "the newest note is not last with its wait in seconds: $lines"
  pass "several notes of different ages are listed oldest first, each with how long it has waited"
}

test_note_acknowledged_normally_clears_everything() {
  local dir state err ack id
  dir=$(make_case ordinary)
  state="$dir/state"
  err="$dir/drain.err"
  id=$(queue_note "$state" "add a dark mode")

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$err" || fail "drain failed"
  grep -F "inbox:$id" "$dir/drain.out" >/dev/null || fail "the note's wake was not presented"
  grep -F "$id waiting" "$dir/drain.out" >/dev/null || fail "the note was not listed"

  FM_STATE_OVERRIDE="$state" "$INBOX_CLI" drain --ack "$id" | grep -Fx "acked $id" >/dev/null \
    || fail "the per-note acknowledgement failed"
  ack=$(ack_printed "$state" "$err") || fail "acknowledgement failed: $ack"

  [ ! -s "$state/.wake-queue" ] || fail "an acknowledged note's wake was kept: $(cat "$state/.wake-queue")"
  if printf '%s\n' "$ack" | grep -F 'CAPTAIN NOTES' >/dev/null; then
    fail "the acknowledgement named a note after it was acknowledged: $ack"
  fi
  [ -f "$state/inbox/handled/$id.note" ] || fail "the note did not move to handled/"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/after.out" 2>&1 || fail "drain after acknowledgement failed"
  if grep -F 'CAPTAIN NOTES' "$dir/after.out" >/dev/null; then
    fail "an acknowledged note was still listed: $(cat "$dir/after.out")"
  fi
  pass "a note acknowledged by its own id leaves no listing, no held line, and an empty queue"
}

test_acknowledging_one_note_leaves_the_other_waiting() {
  local dir state err ack first second
  dir=$(make_case one-of-two)
  state="$dir/state"
  err="$dir/drain.err"
  first=$(queue_note "$state" "first message")
  second=$(queue_note "$state" "second message")

  FM_STATE_OVERRIDE="$state" "$DRAIN" > /dev/null 2> "$err" || fail "drain failed"
  FM_STATE_OVERRIDE="$state" "$INBOX_CLI" drain --ack "$first" >/dev/null || fail "per-note acknowledgement failed"
  ack=$(ack_printed "$state" "$err") || fail "acknowledgement failed: $ack"

  [ "$(queued_inbox_rows "$state")" = "inbox:$second" ] \
    || fail "only the unacknowledged note's wake should remain: $(cat "$state/.wake-queue")"
  case "$(printf '%s\n' "$ack" | tail -1)" in
    *"$first"*) fail "the held line named the acknowledged note: $ack" ;;
    "CAPTAIN NOTES HELD: 1 note(s)"*"$second (waiting "*) ;;
    *) fail "the held line did not name the waiting note: $ack" ;;
  esac
  [ -f "$state/inbox/$second.note" ] || fail "acknowledging one note cleared another"
  pass "acknowledging one note by its id leaves every other note waiting and named"
}

test_unreadable_inbox_keeps_every_note_wake() {
  local dir state err ack id
  if [ "$(id -u)" = 0 ]; then
    pass "unreadable-inbox case skipped: root reads any directory"
    return 0
  fi
  dir=$(make_case unreadable)
  state="$dir/state"
  err="$dir/drain.err"
  id=$(queue_note "$state" "are you there")
  chmod 000 "$state/inbox"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$err" || { chmod 700 "$state/inbox"; fail "drain failed"; }
  ack=$(ack_printed "$state" "$err")
  chmod 700 "$state/inbox"

  grep -F 'CAPTAIN NOTES UNREADABLE' "$dir/drain.out" >/dev/null \
    || fail "an unreadable inbox read as nothing waiting: $(cat "$dir/drain.out")"
  [ "$(queued_inbox_rows "$state")" = "inbox:$id" ] \
    || fail "an unreadable inbox let the acknowledgement consume a note's wake"
  case "$(printf '%s\n' "$ack" | tail -1)" in
    'CAPTAIN NOTES HELD: the captain inbox'*'could not be read'*) ;;
    *) fail "the acknowledgement did not report the unreadable inbox: $ack" ;;
  esac
  pass "an unreadable inbox is reported and keeps every captain-note wake queued"
}

test_lock_skipped_drain_still_lists_notes() {
  local dir state out holder id i
  dir=$(make_case lock-skipped)
  state="$dir/state"
  out="$dir/drain.out"
  id=$(write_old_note "$state" 600 Contended "answer me while the queue is busy")

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    printf "ready\n" > "$3"
    exec sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.wake-queue.lock" "$dir/queue.ready" &
  holder=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/queue.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/queue.ready" ] || { kill "$holder" 2>/dev/null || true; fail "queue holder never acquired its lock"; }

  FM_STATE_OVERRIDE="$state" FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 "$DRAIN" > "$out" 2>&1 \
    || { kill "$holder" 2>/dev/null || true; fail "contended drain failed"; }
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  grep -F "WAKE DRAIN SKIPPED: queue lock remains held by live pid $holder" "$out" >/dev/null \
    || fail "setup error: the drain was not skipped on lock contention: $(cat "$out")"
  grep -E "^$id waiting [0-9]+m: answer me while the queue is busy$" "$out" >/dev/null \
    || fail "a drain skipped on lock contention did not list the waiting note: $(cat "$out")"
  [ -f "$state/inbox/$id.note" ] || fail "the skipped drain acknowledged the note"
  pass "a drain skipped because the queue lock is held still lists every waiting note"
}

test_note_with_no_wake_is_listed
test_filtered_drain_cannot_acknowledge_a_note
test_note_whose_wake_was_already_acknowledged
test_notes_of_different_ages_are_listed_oldest_first
test_note_acknowledged_normally_clears_everything
test_acknowledging_one_note_leaves_the_other_waiting
test_unreadable_inbox_keeps_every_note_wake
test_lock_skipped_drain_still_lists_notes
