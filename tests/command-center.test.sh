#!/usr/bin/env bash
# Behavioral regressions for the command center's reading half and its HTTP
# boundary. Everything here goes through the executables: the scan script's
# JSON and the server's own endpoints, never their source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN="$ROOT/bin/command-center-scan.sh"
SERVER="$ROOT/bin/command-center.py"
TMP_ROOT=$(fm_test_tmproot command-center)

# A home whose backlog carries one live captain hold, one hold that was already
# answered, and one hold that belongs to firstmate rather than the captain.
seed_home() {  # <home>
  local home=$1
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] cc-live - Blue or green? (repo: demo) (kind: ship) (since 2026-09-01) (hold: The colour call) (hold-kind: captain)
  Body first paragraph.

  Body second paragraph, after a blank line.
- [ ] cc-deferred - Hosting region (repo: demo) (kind: ship) (since 2026-09-02) (hold: Deferred by the captain) (hold-kind: captain) (hold-until: 2099-01-01)
- [ ] cc-not-captain - Waiting on CI (repo: demo) (kind: ship) (since 2026-09-03) (hold: blocked on an upstream release) (hold-kind: system)
- [ ] cc-plain - Ordinary queued work (repo: demo) (kind: ship) (since 2026-09-04)

## Done
- [x] cc-answered - Already settled (repo: demo) (kind: ship) (done 2026-09-05) (hold: The colour call) (hold-kind: captain)
EOF
}

scan() {  # <home>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" "$SCAN"
}

test_only_live_captain_holds_are_carded() {
  local home out
  home="$TMP_ROOT/holds"
  seed_home "$home"
  out=$(scan "$home") || fail "the scan failed on a seeded home"

  assert_contains "$out" '"id":"cc-live"' \
    "an open captain hold is missing from the scan"
  assert_contains "$out" '"id":"cc-deferred"' \
    "a deferred captain hold is missing from the scan"
  assert_not_contains "$out" '"id":"cc-answered"' \
    "a closed task still carries its hold annotation and was carded again"
  assert_not_contains "$out" '"id":"cc-not-captain"' \
    "a non-captain hold was presented as the captain's to answer"
  assert_not_contains "$out" '"id":"cc-plain"' \
    "an unheld queued task was presented as waiting on the captain"
  pass "only open captain holds reach the captain's list"
}

test_body_survives_the_record_separator() {
  local home detail
  home="$TMP_ROOT/body"
  seed_home "$home"
  detail=$(scan "$home" | jq -r '.items[] | select(.id == "cc-live") | .detail')

  assert_contains "$detail" 'The colour call' \
    "the hold reason is missing from the item detail"
  assert_contains "$detail" 'Body first paragraph.' \
    "the task body is missing from the item detail"
  assert_contains "$detail" 'Body second paragraph, after a blank line.' \
    "a body paragraph after a blank line was lost"
  pass "a multi-paragraph body survives the scan intact"
}

test_deferred_hold_reports_its_date() {
  local out
  out=$(scan "$TMP_ROOT/holds")
  assert_equals "2099-01-01" \
    "$(printf '%s' "$out" | jq -r '.items[] | select(.id == "cc-deferred") | .deferred_until')" \
    "a hold deferred to a date did not report that date"
  assert_equals "null" \
    "$(printf '%s' "$out" | jq -r '.items[] | select(.id == "cc-live") | .deferred_until')" \
    "an undeferred hold invented a deferral date"
  pass "a deferred hold carries its date and an undeferred one carries none"
}

# project, worktree and branch are three different facts with three different
# ways of being absent, and a row that has none of them must still be honest
# rather than guessing.
test_branch_states_are_honest() {
  local home out ship scout
  home="$TMP_ROOT/branches"
  seed_home "$home"
  ship="$TMP_ROOT/ship-wt"
  scout="$TMP_ROOT/scout-wt"
  fm_git_identity
  fm_git_init_commit "$ship" >/dev/null 2>&1
  fm_git_init_commit "$scout" >/dev/null 2>&1
  git -C "$ship" checkout -q -b fm/on-a-branch
  git -C "$scout" checkout -q --detach HEAD

  printf 'needs-decision [key=k-ship]: pick one\n' > "$home/state/t-ship.status"
  printf 'needs-decision [key=k-scout]: pick one\n' > "$home/state/t-scout.status"
  printf 'worktree=%s\nproject=/somewhere/demo\nkind=ship\n' "$ship" > "$home/state/t-ship.meta"
  printf 'worktree=%s\nproject=/somewhere/demo\nkind=scout\n' "$scout" > "$home/state/t-scout.meta"

  out=$(scan "$home")
  assert_equals "branch" \
    "$(printf '%s' "$out" | jq -r '.items[] | select(.id == "t-ship") | .branch_state')" \
    "a worker on a real branch was not reported as on a branch"
  assert_equals "fm/on-a-branch" \
    "$(printf '%s' "$out" | jq -r '.items[] | select(.id == "t-ship") | .branch')" \
    "the branch name was not read from the worktree"
  assert_equals "detached" \
    "$(printf '%s' "$out" | jq -r '.items[] | select(.id == "t-scout") | .branch_state')" \
    "a detached scratch copy was not reported as detached"
  assert_equals "null" \
    "$(printf '%s' "$out" | jq -r '.items[] | select(.id == "t-scout") | .branch')" \
    "a detached copy invented a branch name"
  assert_equals "not-started" \
    "$(printf '%s' "$out" | jq -r '.items[] | select(.id == "cc-live") | .branch_state')" \
    "a hold nobody has started claimed a branch state it cannot have"
  pass "branch, detached and not-started are each reported for what they are"
}

# A status decision is a stopped worker; it never appears in the backlog as
# held, which is exactly why a surface built on captain holds alone misses it.
test_status_decisions_are_carded_with_their_verb() {
  local home out
  home="$TMP_ROOT/status"
  mkdir -p "$home/data" "$home/state"
  printf '# Backlog\n' > "$home/data/backlog.md"
  printf 'working: started\nblocked [key=k-stuck]: the pipeline is down\n' \
    > "$home/state/t-blocked.status"
  printf 'needs-decision [key=k-ask]: which shape\nresolved [key=k-ask]: settled\n' \
    > "$home/state/t-resolved.status"

  out=$(scan "$home")
  assert_contains "$out" '"id":"t-blocked"' \
    "an open blocker was missing from the scan"
  assert_equals "blocked" \
    "$(printf '%s' "$out" | jq -r '.items[] | select(.id == "t-blocked") | .status_verb')" \
    "the status verb did not travel with the item"
  assert_not_contains "$out" '"id":"t-resolved"' \
    "a decision closed by its own resolved line was still presented as open"
  pass "open status decisions are carded and resolved ones are not"
}

# Delivered and picked up are different facts with different proofs. The move
# into handled/ IS the acknowledgement, and nothing may be reported between them.
test_steering_records_report_delivered_and_picked_up() {
  local home out
  home="$TMP_ROOT/sent"
  mkdir -p "$home/data" "$home/state/t-sent.inbox/handled"
  printf '# Backlog\n' > "$home/data/backlog.md"
  printf 'blocked [key=k]: waiting\n' > "$home/state/t-sent.status"
  printf 'schema=fm-task-inbox.v1\nat=2026-09-01T10:00:00Z\n--\nfirst answer\n' \
    > "$home/state/t-sent.inbox/handled/001.msg"
  printf 'schema=fm-task-inbox.v1\nat=2026-09-01T11:00:00Z\n--\nsecond answer\n' \
    > "$home/state/t-sent.inbox/002.msg"

  out=$(printf '%s' "$(scan "$home")" | jq -c '.items[] | select(.id == "t-sent") | .sent')
  assert_contains "$out" '"seq":"001"' "an acknowledged steering record was dropped"
  assert_contains "$out" '"seq":"002"' "an unacknowledged steering record was dropped"
  assert_contains "$out" '"text":"first answer"' "the captain's words were lost from the record"
  assert_equals "true" \
    "$(printf '%s' "$out" | jq -r '.[] | select(.seq == "001") | .handled')" \
    "a record moved into handled/ was not reported as picked up"
  assert_equals "false" \
    "$(printf '%s' "$out" | jq -r '.[] | select(.seq == "002") | .handled')" \
    "a record still in the inbox was reported as picked up"
  pass "a steering record reports delivered and picked up from the acknowledgement move"
}

test_fingerprint_changes_only_when_a_record_moves() {
  local home first second third
  home="$TMP_ROOT/fingerprint"
  seed_home "$home"
  first=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SCAN" --fingerprint)
  second=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SCAN" --fingerprint)
  assert_equals "$first" "$second" \
    "the change check reported a change when nothing moved"
  printf 'blocked [key=k]: something happened\n' > "$home/state/t-new.status"
  third=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SCAN" --fingerprint)
  assert_not_equals "$first" "$third" \
    "the change check missed a new status record"
  pass "the change check is stable when idle and notices a moved record"
}

# --- HTTP boundary -----------------------------------------------------------
# Sets SERVER_PORT and SERVER_PID in the CALLER's shell. It must not be used in
# a command substitution: that runs in a subshell, the pid never comes back, and
# every test leaks a live server.
start_server() {  # <home>
  local home=$1
  SERVER_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  FM_ROOT_OVERRIDE="$ROOT" python3 "$SERVER" --port "$SERVER_PORT" --home "$home" \
    > "$home/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 60); do
    curl -sf -m 2 -o /dev/null "http://127.0.0.1:$SERVER_PORT/" && return 0
    kill -0 "$SERVER_PID" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}

stop_server() {
  [ -n "${SERVER_PID:-}" ] || return 0
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
}

post() {  # <port> <path> <json>
  curl -s -X POST -H 'Content-Type: application/json' -d "$3" \
    "http://127.0.0.1:$1$2"
}

test_server_serves_the_page_and_the_records() {
  local home port body
  home="$TMP_ROOT/http"
  seed_home "$home"
  start_server "$home" || fail "the server did not start"
  port=$SERVER_PORT

  body=$(curl -s "http://127.0.0.1:$port/")
  assert_contains "$body" '<title>Firstmate Command Center</title>' \
    "the page was not served at the root address"
  body=$(curl -s -m 120 "http://127.0.0.1:$port/api/items")
  assert_contains "$body" '"id":"cc-live"' \
    "the records endpoint did not carry the waiting item"
  assert_equals "304" \
    "$(curl -s -o /dev/null -w '%{http_code}' \
        -H "If-None-Match: $(curl -sI -m 120 "http://127.0.0.1:$port/api/items" \
          | awk 'tolower($1)=="etag:"{gsub(/\r/,"");print $2}')" \
        "http://127.0.0.1:$port/api/items")" \
    "an unchanged poll re-sent the whole view instead of answering 304"
  stop_server
  pass "the page and the records are served, and an unchanged poll costs nothing"
}

# The one free-text field reaches firstmate's own scripts, so it is checked
# before anything is run, and an unknown item can never select a command.
test_server_refuses_bad_input_before_running_anything() {
  local home port
  home="$TMP_ROOT/guard"
  seed_home "$home"
  start_server "$home" || fail "the server did not start"
  port=$SERVER_PORT

  assert_contains "$(post "$port" /api/answer '{"home":"main","id":"cc-live","text":"   "}')" \
    'an empty answer is not an answer' "an empty answer was accepted"
  assert_contains "$(post "$port" /api/answer '{"home":"main","id":"../../etc/passwd","text":"x"}')" \
    '"ok":false' "a traversal-shaped task id was not refused"
  assert_contains "$(post "$port" /api/answer '{"home":"main","id":"cc-nonexistent","text":"x"}')" \
    'no longer waiting for you' "an unknown item was not refused"
  assert_contains "$(post "$port" /api/answer \
      "{\"home\":\"main\",\"id\":\"cc-live\",\"text\":\"$(head -c 9000 /dev/zero | tr '\0' 'a')\"}")" \
    '8192 bytes' "an oversize answer was not refused at the recorded-decision limit"
  assert_equals "400" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X POST -d 'not json' \
        "http://127.0.0.1:$port/api/answer")" \
    "an unreadable request body was not refused"
  stop_server
  pass "bad input is refused before any firstmate command runs"
}

# The whole point of the surface: his words reach the durable record, and the
# one thing firstmate does not keep is kept here.
test_answering_a_hold_records_the_captains_words_and_clears_the_item() {
  local home port result
  home="$TMP_ROOT/answer"
  mkdir -p "$home/data" "$home/state"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-tasks-axi.sh" add cc-answer "Blue or green?" --kind ship --repo demo \
    >/dev/null 2>&1 || { pass "tasks-axi unavailable; skipped the live answer round trip"; return; }
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-captain-hold.sh" hold cc-answer --reason "The colour call" >/dev/null 2>&1

  start_server "$home" || fail "the server did not start"
  port=$SERVER_PORT
  result=$(post "$port" /api/answer \
    '{"home":"main","id":"cc-answer","text":"Green. Blue reads as disabled."}')
  assert_contains "$result" '"ok":true' "the answer was not delivered"
  assert_contains "$result" 'fm-captain-hold.sh answer' \
    "a held decision was not answered through the script that owns decision records"

  assert_grep 'Green. Blue reads as disabled.' "$home/data/backlog.md" \
    "the captain's exact words did not reach the durable task record"
  assert_grep 'cc-answer' "$home/data/command-center/said.jsonl" \
    "the answer was not appended to the captain's own record of what he said"
  assert_not_contains "$(curl -s -m 120 "http://127.0.0.1:$port/api/items")" '"id":"cc-answer"' \
    "an answered decision stayed in the waiting list"
  stop_server
  pass "an answer reaches the task record, the captain's log, and leaves the list"
}

trap stop_server EXIT

test_only_live_captain_holds_are_carded
test_body_survives_the_record_separator
test_deferred_hold_reports_its_date
test_branch_states_are_honest
test_status_decisions_are_carded_with_their_verb
test_steering_records_report_delivered_and_picked_up
test_fingerprint_changes_only_when_a_record_moves
test_server_serves_the_page_and_the_records
test_server_refuses_bad_input_before_running_anything
test_answering_a_hold_records_the_captains_words_and_clears_the_item
