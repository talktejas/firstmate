#!/usr/bin/env bash
# Drives the real bin/fm-pr-check.sh in a throwaway home. Real git, real
# bin/fm-review-diff.sh, real curl over real HTTP. Only the two external
# services are stand-ins: api.typesafe.ai is a local HTTP server (the curl on
# PATH rewrites only the host, then execs /usr/bin/curl), and gh/glab answer the
# title and description from a file because the invented changes have no PR.
set -u
ROOT=$1; EV=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d /tmp/fm-risk-live.XXXXXX); H=$T/home; BIN=$T/bin; PROJ=$T/alpha; WT=$T/wt
PORT=18473; KEY=fake-key-not-real-7f3a
mkdir -p "$H/state" "$H/config" "$BIN"
cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
args=()
for a; do args+=("\${a/https:\/\/api.typesafe.ai/http://127.0.0.1:$PORT}"); done
printf '%s\n' "\$*" >> "$T/curl-argv"
exec /usr/bin/curl "\${args[@]}"
EOF
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/forge-calls"
case "\$*" in *title,body*) [ -f "$T/pr.json" ] && cat "$T/pr.json" && exit 0 ;; esac
exit 1
EOF
cat > "$BIN/glab" <<EOF
#!/usr/bin/env bash
printf 'glab %s\n' "\$*" >> "$T/forge-calls"
case "\$*" in *"mr view"*"-F json"*) [ -f "$T/mr.json" ] && cat "$T/mr.json" && exit 0 ;; esac
exit 1
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_GUARD_GRACE=999999
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset TYPESAFE_API_KEY
git init -q -b main "$PROJ"; mkdir -p "$PROJ/src"; seq 1 4 > "$PROJ/src/old.js"; echo '# alpha' > "$PROJ/README.md"
git -C "$PROJ" add -A; git -C "$PROJ" commit -qm initial
git -C "$PROJ" worktree add --quiet -b fm/task-a "$WT"

server_up() { python3 "$EV/fake-jev-server.py" $PORT "$T/mode" "$T/requests" & SRV=$!; sleep 0.7; }
server_down() { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; }
change() {  # <path>:<lines>|<path>:deleted ...
  local spec path n
  git -C "$WT" reset -q --hard main
  for spec; do path=${spec%:*} n=${spec##*:}
    if [ "$n" = deleted ]; then git -C "$WT" rm -q -- "$path"
    else mkdir -p "$WT/$(dirname "$path")"; seq 1 "$n" > "$WT/$path"; git -C "$WT" add -- "$path"; fi
  done
  git -C "$WT" commit -qm change
}
N=0
run() {  # <label> <url> [extra args]   -> transcript of one registration
  local label=$1 url=$2; shift 2
  N=$((N+1))
  printf 'window=fm-task-a\nkind=ship\nworktree=%s\nproject=%s\n' "$WT" "$PROJ" > "$H/state/task-a.meta"
  rm -f "$H/state/task-a.pr-poll" "$H/state/task-a.check.sh" "$T/requests" "$T/forge-calls" "$T/curl-argv"
  printf '\n=== %02d. %s\n' "$N" "$label"
  printf '$ bin/fm-pr-check.sh task-a %s %s\n' "$url" "$*"
  "$ROOT/bin/fm-pr-check.sh" task-a "$url" "$@" 2>"$T/err"; rc=$?
  printf '[exit %s] [pr recorded: %s] [merge poll armed: %s] ' "$rc" \
    "$(grep -c "^pr=$url\$" "$H/state/task-a.meta")" "$([ -e "$H/state/task-a.pr-poll" ] && echo yes || echo no)"
  if [ -s "$T/requests" ]; then
    printf '[Jev requests: %s]\n' "$(jq -r '"\(.question)->\(.reply)"' "$T/requests" | paste -sd' ')"
  else printf '[Jev requests: none]\n'; fi
  printf '[description read from forge: %s]\n' "$(grep -c 'title,body\|mr view' "$T/forge-calls" 2>/dev/null || true)"
  [ ! -s "$T/err" ] || sed 's/^/stderr: /' "$T/err"
}
mode() { printf '%s' "$1" > "$T/mode"; }
pr() { jq -n --arg t "$1" --arg b "$2" '{title:$t, body:$b}' > "$T/pr.json"; }
GH=https://github.com/o/r/pull/8
ALLNO='{"*":"no:0.95"}'
mode "$ALLNO"; pr 'Rename helper' 'Pure rename, no behaviour change.'
server_up

echo "##### A. Key absent: nothing changes"
change src/util.js:12
run 'no TYPESAFE_API_KEY anywhere, project listed' "$GH"

echo; echo "##### B. Key in the home .env, project listed in config/jev-code-projects"
printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$H/.env"
printf '# projects Jev may see\nalpha\n' > "$H/config/jev-code-projects"
run 'small code change, Jev answers no to all three -> low' "$GH"
echo "--- what the Jev endpoint received for that registration:"; jq -c . "$T/requests"
echo "--- curl argv (key must not appear): $(grep -c "$KEY" "$T/curl-argv") occurrence(s) of the key"
echo "--- key in task record: $(grep -c "$KEY" "$H/state/task-a.meta") occurrence(s)"
change src/util.js:12 tests/util.test.js:5
run 'code + test file changed -> untested settled in code, not asked' "$GH"

echo; echo "##### C. Facts collected by code set the level (Jev answers no to everything)"
change db/migrations/0042_drop.sql:3 tests/x.test.js:2;   run 'database migration path' "$GH"
change src/authorization/policy.rb:5 tests/x.test.js:2;   run 'authorization path (review fix)' "$GH"
change lib/authorize.js:5 tests/x.test.js:2;              run 'authorize path (review fix)' "$GH"
change app/unauthorized_handler.py:5 tests/x.test.js:2;   run 'unauthorized path (review fix)' "$GH"
change src/login/form.js:5 tests/x.test.js:2;             run 'login path' "$GH"
change src/authors/list.js:5 tests/x.test.js:2;           run 'ADVERSARIAL authors/ path must NOT read as login' "$GH"
change src/billing/invoice.js:5 tests/x.test.js:2;        run 'payments path' "$GH"
change src/old.js:deleted tests/x.test.js:40;             run 'a deleted file (beside an unrelated test file)' "$GH"
change src/old.js:deleted tests/x.test.js:2;              run 'a file moved and edited (git reports a rename, not a deletion)' "$GH"
change src/big.js:450 tests/x.test.js:2;                  run 'size: 452 lines (>=400)' "$GH"
change src/huge.js:1600 tests/x.test.js:2;                run 'size: 1602 lines (>=1500)' "$GH"
change docs/guide.md:10;                                  run 'docs only' "$GH"

echo; echo "##### D. A counted yes from Jev only raises"
change src/parser.js:12
mode '{"*":"no:0.95","untested":"yes:0.9"}';     run 'Jev: behaviour changed with no test = yes' "$GH"
mode '{"*":"no:0.95","mismatch":"yes:0.9"}';     run 'Jev: description does not match = yes' "$GH"
mode '{"*":"no:0.95","irreversible":"yes:0.9"}'; run 'Jev: hard to undo = yes' "$GH"
mode '{"*":"yes:0.9"}';                          run 'Jev: yes to all three' "$GH"

echo; echo "##### E. Jev unsure, off the fixed list, or down: 'not rated', never 'low', registration intact"
mode '{"*":"no:0.4"}';   run 'ADVERSARIAL Jev answers no at confidence 0.4 (below the 0.6 floor)' "$GH"
mode '{"*":"yes:0.4"}';  run 'ADVERSARIAL Jev answers yes at confidence 0.4 (below the floor, not counted)' "$GH"
mode '{"*":"maybe"}';    run 'ADVERSARIAL Jev picks "maybe", which is not on the fixed list' "$GH"
mode '{"*":"garbage"}';  run 'ADVERSARIAL Jev replies HTML instead of JSON' "$GH"
mode '{"*":"500"}';      run 'ADVERSARIAL Jev returns HTTP 500' "$GH"
mode '{"*":"sleep"}'; s=$(date +%s); run 'ADVERSARIAL Jev hangs past the 5 s timeout' "$GH"; echo "[wall time: $(( $(date +%s) - s )) s]"
server_down;             run 'ADVERSARIAL Jev endpoint is down (connection refused)' "$GH"
rm -f "$T/pr.json"; server_up; mode "$ALLNO"
run 'forge description unreadable (gh fails)' "$GH"
pr 'Rename helper' 'Pure rename, no behaviour change.'

echo; echo "##### F. Never lowers a level the facts set"
change db/migrations/0042_drop.sql:3 src/parser.js:12
mode '{"*":"no:0.99"}';  run 'ADVERSARIAL migration + Jev confidently says no to everything -> still high' "$GH"
mode '{"*":"500"}';      run 'ADVERSARIAL migration + Jev HTTP 500 -> still high' "$GH"
change src/old.js:deleted src/parser.js:12
mode '{"*":"no:0.4"}';   run 'ADVERSARIAL deletion + Jev unsure -> still medium' "$GH"

echo; echo "##### G. Project not listed: nothing about it leaves the machine"
mode '{"*":"yes:0.9"}'
printf '# alpha\nalpha-web\n' > "$H/config/jev-code-projects"
change src/parser.js:12;                run 'unlisted, no fact' "$GH"
change db/migrations/0042_drop.sql:3;   run 'unlisted, migration fact' "$GH"
rm -f "$H/config/jev-code-projects";    run 'list file absent, migration fact' "$GH"
printf 'alpha\n' > "$H/config/jev-code-projects"

echo; echo "##### H. Merge-time re-registration (--no-risk) rates nothing"
run 'listed project, key present, --no-risk' "$GH" --no-risk

echo; echo "##### I. GitLab merge request (fake glab answers title/description)"
jq -n '{title:"Add parser", description:"Adds the parser."}' > "$T/mr.json"
change src/parser.js:12; mode '{"*":"no:0.95","untested":"yes:0.9"}'
run 'gitlab MR, Jev: untested = yes' https://gitlab.com/g/p/-/merge_requests/5
server_down; rm -rf "$T"
