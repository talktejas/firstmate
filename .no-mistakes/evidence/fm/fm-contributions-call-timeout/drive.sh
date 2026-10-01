#!/usr/bin/env bash
# Drives bin/fm-contributions.sh poll (and the watcher) against a fake gh whose
# reads take real wall-clock time. usage: drive.sh <tree-root> <scenario>
set -u
WT=$PWD; TREE=$1; SCN=$2
. "$WT/tests/lib.sh"; . <(sed -e "/^failures=0\$/,\$d" -e "/lib\.sh\")\?\"\?$/d" "$WT/tests/fm-contributions.test.sh")
ROOT=$TREE
home=$(new_home "drive-$SCN"); forge_home "$home"
mv "$home/fakebin/gh" "$home/fakebin/gh-fixture"
cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(/bin/date +%T)" "$*" >> "$FORGE/calls"
d=$(cat "$FORGE/delay"); on=$(cat "$FORGE/delay_on")
if [ "$on" = all ] || [ "$*" = 'api repos/o/r/pulls/8' ]; then sleep "$d"; fi
exec "$(dirname "$0")/gh-fixture" "$@"
SH
chmod +x "$home/fakebin/gh"
mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
poll() { local s=$SECONDS out rc=0; out=$(with_home "$home" "$@" "$ROOT/bin/fm-contributions.sh" poll) || rc=$?
  echo "\$ ${*:2} fm-contributions.sh poll   (rc=$rc, $((SECONDS-s))s)"; echo "stdout: ${out:-<empty>}"
  jq -c '.records[0]|{checked_at,error,observed:(.observation!=null)}' "$home/data/delivery/contributions.json"; }
echo "== tree: $(basename "$TREE")  scenario: $SCN"
case $SCN in
  slow20) echo 20 > "$home/forge/delay"; echo first > "$home/forge/delay_on"; poll env ;;
  hang40) echo 40 > "$home/forge/delay"; echo first > "$home/forge/delay_on"; poll env
          poll env FM_CONTRIBUTIONS_NOW=2026-09-16T09:00:00Z ;;
  override5) echo 20 > "$home/forge/delay"; echo first > "$home/forge/delay_on"; poll env FM_CONTRIBUTIONS_CALL_TIMEOUT=5 ;;
  watch) echo 18 > "$home/forge/delay"; echo all > "$home/forge/delay_on"
    with_home "$home" "$ROOT/bin/fm-contributions.sh" arm >/dev/null || echo ARM FAILED
    s=$SECONDS rc=0
    with_home "$home" env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
      "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 175 > "$home/w.out" 2> "$home/w.err" || rc=$?
    echo "watcher checkpoint, 8 forge reads x 18s = 144s, nothing configured (rc=$rc, $((SECONDS-s))s)"
    echo "gh calls started: $(wc -l < "$home/forge/calls")"; cat "$home/forge/calls"
    jq -c '.records[0]|{checked_at,error,observed:(.observation!=null)}' "$home/data/delivery/contributions.json"
    head -5 "$home/w.out" "$home/w.err" ;;
esac
