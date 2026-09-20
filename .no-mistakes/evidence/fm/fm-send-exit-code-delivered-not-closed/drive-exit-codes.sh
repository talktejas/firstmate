#!/usr/bin/env bash
# Operator-level drive of bin/fm-send.sh --resolve-key exit codes.
# Each scenario runs the real fm-send CLI against a throwaway FM_HOME with a
# stubbed terminal/ssh transport, and prints the exit code the caller sees.
set -u
ROOT=${ROOT:?}
SEND="$ROOT/bin/fm-send.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-send-exit.XXXXXX")
FB="$TMP/fakebin"; mkdir -p "$FB"
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
    shift; literal=0
    while [ $# -gt 0 ]; do case "$1" in -t) shift 2;; -l) literal=1; shift;; *) break;; esac; done
    [ "$literal" = 1 ] && printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    exit 0 ;;
  display-message) for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0;; esac; done; printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf '%s\n' fm-t1 fm-t2 fm-mate; exit 0 ;;
esac
exit 0
SH
cat > "$FB/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FB/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" >> "$FM_SSH_LOG"
exit "${FM_FAKE_SSH_RC:-0}"
SH
chmod +x "$FB"/*

meta() { local f=$1; shift; : > "$f"; for kv in "$@"; do printf '%s\n' "$kv" >> "$f"; done; }
home() { local h="$TMP/$1"; mkdir -p "$h/state"; printf '%s\n' "$h"; }
remote_home() {
  local h; h=$(home "$1"); mkdir -p "$h/data"
  meta "$h/state/rsm.meta" window=fm-remote:w1:p1 endpoint_task_id=rsm harness=claude \
    kind=secondmate mode=secondmate yolo=off remote_host=remote-mac remote_root=/remote/root \
    remote_backend=herdr remote_herdr_session=fm-remote remote_target=fm-remote:w1:p1
  printf -- '- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)\n' \
    > "$h/data/secondmates.md"
  printf '%s\n' "$h"
}
FAILED=0
report() { # <name> <expected-desc> <rc> <ok?>
  if [ "$4" = 1 ]; then printf 'PASS  %-46s exit=%s (%s)\n' "$1" "$3" "$2"
  else printf 'FAIL  %-46s exit=%s (expected %s)\n' "$1" "$3" "$2"; FAILED=1; fi
}

echo "=== fm-send --resolve-key exit-code contract ==="

# 1. local inbox plane, close succeeds -> 0, decision closed, record enqueued
h=$(home happy); meta "$h/state/t1.meta" window=sess:fm-t1 kind=ship
printf 'needs-decision [key=creds]: which token?\n' > "$h/state/t1.status"
env PATH="$FB:$PATH" FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$h" FM_HOME="$h" FM_SEND_LOG="$TMP/l1" FM_SEND_SETTLE=0 \
  "$SEND" t1 --resolve-key creds "use the vault token" >/dev/null 2>"$TMP/e1"; rc=$?
closed=0; grep -qF 'resolved [key=creds]' "$h/state/t1.status" && closed=1
rec=0; [ -d "$h/state/t1.inbox" ] && [ -n "$(ls -A "$h/state/t1.inbox")" ] && rec=1
report "local: delivered + closed" "0, decision closed, record enqueued" "$rc" \
  "$([ "$rc" = 0 ] && [ "$closed" = 1 ] && [ "$rec" = 1 ] && echo 1 || echo 0)"
echo "      status now: $(tr '\n' '|' < "$h/state/t1.status")"
echo "      open decisions after: $(FM_STATE_OVERRIDE="$h/state" "$DRAIN" 2>/dev/null | grep -c 'OPEN DECISIONS')"

# 2. local inbox plane, delivered but close append fails -> 4
h=$(home notclosed); meta "$h/state/t1.meta" window=sess:fm-t1 kind=ship
printf 'needs-decision [key=creds]: which token?\n' > "$h/state/t1.status"; chmod 0400 "$h/state/t1.status"
env PATH="$FB:$PATH" FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$h" FM_HOME="$h" FM_SEND_LOG="$TMP/l2" FM_SEND_SETTLE=0 \
  "$SEND" t1 --resolve-key creds "use the vault token" >/dev/null 2>"$TMP/e2"; rc=$?
chmod 0600 "$h/state/t1.status"
rec=0; [ -d "$h/state/t1.inbox" ] && [ -n "$(ls -A "$h/state/t1.inbox")" ] && rec=1
report "local: delivered, close failed" "4, answer still enqueued" "$rc" \
  "$([ "$rc" = 4 ] && [ "$rec" = 1 ] && echo 1 || echo 0)"
echo "      stderr: $(grep -a "^error:" "$TMP/e2" | head -c 300)"

# 3. local inbox plane, nothing delivered (enqueue fails) -> nonzero but NOT 4
h=$(home undelivered); meta "$h/state/t5.meta" window=sess:fm-t5 kind=ship
printf 'blocked [key=creds]: need the deploy token\n' > "$h/state/t5.status"
: > "$h/state/t5.inbox"   # a FILE where the inbox dir must go
env PATH="$FB:$PATH" FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$h" FM_HOME="$h" FM_SEND_LOG="$TMP/l3" FM_SEND_SETTLE=0 \
  "$SEND" t5 --resolve-key creds "token is in the vault" >/dev/null 2>"$TMP/e3"; rc=$?
open=0; FM_STATE_OVERRIDE="$h/state" "$DRAIN" 2>/dev/null | grep -qF '[key=creds]' && open=1
report "local: undelivered (enqueue failed)" "nonzero != 4, decision stays open" "$rc" \
  "$([ "$rc" != 0 ] && [ "$rc" != 4 ] && [ "$open" = 1 ] && echo 1 || echo 0)"
echo "      stderr: $(grep -a "^error:" "$TMP/e3" | head -c 200)"

# 4. local inbox plane, retired/changed endpoint -> nonzero but NOT 4
h=$(home retired); meta "$h/state/t1.meta" window=sess:fm-t1 kind=ship
printf 'needs-decision [key=creds]: which token?\n' > "$h/state/t1.status"
env PATH="$FB:$PATH" FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$h" FM_HOME="$h" FM_SEND_LOG="$TMP/l4" FM_SEND_SETTLE=0 \
  FM_SEND_EXPECTED_SPAWN_GEN=99 \
  "$SEND" t1 --resolve-key creds "use the vault token" >/dev/null 2>"$TMP/e4"; rc=$?
report "local: endpoint retired/changed" "nonzero != 4" "$rc" \
  "$([ "$rc" != 0 ] && [ "$rc" != 4 ] && echo 1 || echo 0)"
echo "      stderr: $(grep -a "^error:" "$TMP/e4" | head -c 200)"

# 5. remote inbox leg, delivered over transport but close append fails -> 4
h=$(remote_home remote-notclosed)
printf 'needs-decision [key=creds]: which token?\n' > "$h/state/rsm.status"; chmod 0400 "$h/state/rsm.status"
env PATH="$FB:$PATH" FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$h" FM_SEND_LOG="$TMP/l5" FM_SEND_SETTLE=0 \
  FM_SSH_BIN="$FB/fake-ssh" FM_SSH_LOG="$TMP/ssh5" FM_FAKE_SSH_RC=0 \
  "$SEND" rsm --resolve-key creds "use the vault token" >/dev/null 2>"$TMP/e5"; rc=$?
chmod 0600 "$h/state/rsm.status"
sent=0; [ -s "$TMP/ssh5" ] && sent=1
report "remote: delivered, close failed" "4, transport did run" "$rc" \
  "$([ "$rc" = 4 ] && [ "$sent" = 1 ] && echo 1 || echo 0)"
echo "      stderr: $(grep -a "^error:" "$TMP/e5" | head -c 250)"

# 6. remote inbox leg, transport failed -> nonzero but NOT 4
h=$(remote_home remote-lost)
printf 'needs-decision [key=creds]: which token?\n' > "$h/state/rsm.status"
env PATH="$FB:$PATH" FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$h" FM_SEND_LOG="$TMP/l6" FM_SEND_SETTLE=0 \
  FM_SSH_BIN="$FB/fake-ssh" FM_SSH_LOG="$TMP/ssh6" FM_FAKE_SSH_RC=1 \
  "$SEND" rsm --resolve-key creds "use the vault token" >/dev/null 2>"$TMP/e6"; rc=$?
open=0; grep -qF 'resolved' "$h/state/rsm.status" || open=1
report "remote: transport failed" "nonzero != 4, decision stays open" "$rc" \
  "$([ "$rc" != 0 ] && [ "$rc" != 4 ] && [ "$open" = 1 ] && echo 1 || echo 0)"
echo "      stderr: $(grep -a "^error:" "$TMP/e6" | head -c 200)"

# 7. typed plane still uses its own codes (3 = delivered/submit unconfirmed is
#    unchanged; a typed-plane close failure is out of this change's scope).
h=$(home typed); meta "$h/state/t1.meta" window=sess:fm-t1 kind=ship harness=claude
printf 'needs-decision [key=creds]: which token?\n' > "$h/state/t1.status"; chmod 0400 "$h/state/t1.status"
env PATH="$FB:$PATH" FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$h" FM_HOME="$h" FM_SEND_LOG="$TMP/l7" FM_SEND_SETTLE=0 \
  "$SEND" t1 --resolve-key creds "/compact now" >/dev/null 2>"$TMP/e7"; rc=$?
chmod 0600 "$h/state/t1.status"
typed=0; grep -qF '/compact now' "$TMP/l7" && typed=1
report "typed plane: unchanged (no exit 4)" "1 (typed), text typed" "$rc" \
  "$([ "$rc" = 1 ] && [ "$typed" = 1 ] && echo 1 || echo 0)"
echo "      typed bytes: $(head -c 120 "$TMP/l7")"
echo "      stderr: $(grep -a "^error:" "$TMP/e7" | head -c 200)"

echo
[ "$FAILED" = 0 ] && echo "ALL SCENARIOS PASSED" || echo "SOME SCENARIOS FAILED"
rm -rf "$TMP"
exit "$FAILED"
