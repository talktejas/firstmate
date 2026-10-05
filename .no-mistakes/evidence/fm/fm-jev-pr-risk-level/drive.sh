#!/usr/bin/env bash
# Drives the real bin/fm-pr-check.sh in an isolated home against a fixture
# project/worktree. Real git, real bin/fm-review-diff.sh, real curl over HTTP to
# a local stand-in for api.typesafe.ai (jev-standin.py); gh/glab are shims
# because no real pull request exists.
set -u
ROOT=$(pwd); E=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d /tmp/fmrisk.XXXXXX); H=$T/home; S=$T/shim; J=$T/jev
mkdir -p "$H/state" "$H/config" "$S" "$J"
KEY='drive-key-51aa-not-on-argv'
URL='https://github.com/o/r/pull/8'
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset TYPESAFE_API_KEY FM_TASK_ID

echo '{}' > "$J/mode.json"; : > "$J/requests.jsonl"
python3 "$E/jev-standin.py" "$J" & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 50); do [ -s "$J/port" ] && break; sleep 0.1; done
PORT=$(cat "$J/port")

cat > "$S/curl" <<EOF
#!/usr/bin/env bash
{ printf 'curl argv: %s\n' "\$*"; env | grep -c '^TYPESAFE_API_KEY' | sed 's/^/curl env key vars: /'; } >> "$T/children.log"
args=(); for a; do args+=("\${a/https:\/\/api.typesafe.ai/http://127.0.0.1:\$(cat "$J/port.use")}"); done
exec /usr/bin/curl "\${args[@]}"
EOF
cat > "$S/gh" <<EOF
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$T/children.log"
case "\$*" in *title,body*) [ -s "$T/pr.json" ] && cat "$T/pr.json" || exit 1 ;; *) exit 1 ;; esac
EOF
cat > "$S/glab" <<EOF
#!/usr/bin/env bash
printf 'glab %s\n' "\$*" >> "$T/children.log"
case "\$*" in *"mr view"*) [ -s "$T/mr.json" ] && cat "$T/mr.json" || exit 1 ;; *) exit 1 ;; esac
EOF
chmod +x "$S"/*
export PATH="$S:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_GUARD_GRACE=999999

P=$T/alpha; WT=$T/wt
git init -q -b main "$P"; mkdir -p "$P/src"; echo '# alpha' > "$P/README.md"; seq 1 4 > "$P/src/old.js"
git -C "$P" add -A; git -C "$P" commit -qm initial
git -C "$P" worktree add -q -b fm/task-a "$WT"

change() { # <path>:<lines>|<path>:deleted ...
  git -C "$WT" reset -q --hard main
  for spec; do p=${spec%:*} n=${spec##*:}
    if [ "$n" = deleted ]; then git -C "$WT" rm -q -- "$p"; else mkdir -p "$WT/$(dirname "$p")"; seq 1 "$n" > "$WT/$p"; git -C "$WT" add -- "$p"; fi
  done; git -C "$WT" commit -qm change
}
mode() { printf '%s' "$1" > "$J/mode.json"; }
up() { echo "$PORT" > "$J/port.use"; }
down() { echo 1 > "$J/port.use"; }   # port 1: connection refused
key() { if [ "$1" = on ]; then printf 'TYPESAFE_API_KEY=%s\n' "$KEY" > "$H/.env"; else rm -f "$H/.env"; fi; }
list() { if [ "$1" = none ]; then rm -f "$H/config/jev-code-projects"; else printf "$1" > "$H/config/jev-code-projects"; fi; }
SC=0
run() { # <title> [script] [url] [extra args...]
  local title=$1 script=${2:-$ROOT/bin/fm-pr-check.sh} url=${3:-$URL}; shift; shift 2>/dev/null; shift 2>/dev/null
  SC=$((SC+1))
  printf 'window=fm-task-a\nkind=ship\nworktree=%s\nproject=%s\n' "$WT" "$P" > "$H/state/task-a.meta"
  rm -f "$H/state/task-a.pr-poll" "$H/state/task-a.check.sh"; : > "$J/requests.jsonl"; : > "$T/children.log"
  local t0=$(date +%s.%N) rc=0
  OUT=$("$script" task-a "$url" "$@" 2>"$T/err") || rc=$?
  local dt=$(echo "$(date +%s.%N) - $t0" | bc)
  printf '\n=== %d. %s\n' "$SC" "$title"
  printf '$ %s task-a %s %s\n' "${script#$ROOT/}" "$url" "$*"
  printf '%s\n' "$OUT" | sed 's/^/  stdout| /'
  [ ! -s "$T/err" ] || sed 's/^/  stderr| /' "$T/err"
  printf '  exit=%s  wall=%.1fs  recorded=%s  poll_armed=%s\n' "$rc" "$dt" \
    "$(grep '^pr=' "$H/state/task-a.meta" || echo none)" "$([ -e "$H/state/task-a.pr-poll" ] && echo yes || echo no)"
  printf '  requests received by Jev stand-in: %s [%s]\n' "$(wc -l < "$J/requests.jsonl")" "$(jq -r .question "$J/requests.jsonl" | paste -sd' ')"
  printf '  curl started: %s   forge description reads: %s\n' "$(grep -c '^curl argv' "$T/children.log")" "$(grep -c 'title,body\|mr view' "$T/children.log")"
}

echo '{"title":"Tidy the parser","body":"Splits one long function."}' > "$T/pr.json"
up; mode '{}'

echo "############ A. Key absent: work carries on exactly as today"
key off; list 'alpha\n'; change db/migrations/0042_drop.sql:3 src/parser.js:12
# warm-up so the once-per-episode watcher banner is not what differs between the two runs
printf 'window=fm-task-a\nkind=ship\nworktree=%s\nproject=%s\n' "$WT" "$P" > "$H/state/task-a.meta"; "$ROOT/bin/fm-pr-check.sh" task-a "$URL" >/dev/null 2>&1
run "key absent, project listed, migration change -> no risk line at all"
A_OUT=$OUT; A_ERR=$(cat "$T/err"); A_META=$(cat "$H/state/task-a.meta")
mkdir -p "$T/base"; git -C "$ROOT" archive f6a10db bin | tar -x -C "$T/base"
run "same registration with the BASE commit's script (f6a10db)" "$T/base/bin/fm-pr-check.sh"
[ "$A_OUT|$A_ERR|$A_META" = "$OUT|$(cat "$T/err")|$(cat "$H/state/task-a.meta")" ] \
  && echo "  COMPARE: stdout, stderr and task meta identical to base commit" || echo "  COMPARE: DIFFERS from base commit"

echo; echo "############ B. Key present, project listed: full rating"
key on
change src/parser.js:12
run "ordinary code change, Jev answers no x3 -> low"
echo "  --- state Jev was sent (first request, diff_start trimmed):"
jq -c 'select(.question=="untested") | .body.state.change | .diff_start |= (.[0:60] + "...")' "$J/requests.jsonl" | sed 's/^/  /'
echo "  --- options offered per question: $(jq -c '.body.questions[] | (.criteria | keys)' "$J/requests.jsonl" | sort -u | paste -sd' ')  auth header received: $(jq -r .auth "$J/requests.jsonl" | sort -u | sed "s/$KEY/<the key>/")"
echo "  --- key on curl argv: $(grep -c "$KEY" "$T/children.log")   $(grep 'env key vars' "$T/children.log" | sort -u)"
mode '{"untested":["yes",0.9]}';     run "Jev: behaviour changed with no test -> medium"
mode '{"mismatch":["yes",0.9]}';     run "Jev: description does not match -> medium"
mode '{"irreversible":["yes",0.9]}'; run "Jev: something hard to undo -> high"
mode '{}'
change src/parser.js:12 tests/parser.test.js:5; run "test file changed -> 'untested' settled in code, only 2 questions asked"
for c in 'db/migrations/0042_drop.sql:3|migration path' 'app/AuthController.php:3|login/permissions path' 'src/billing/invoice.ts:3|payments path' 'src/old.js:deleted|deleted file' 'src/big.js:400|400 lines' 'src/big.js:1500|1500 lines' 'db/migrations/café.sql:3|non-ASCII (git-quoted) migration path' 'my schema.sql:3|path with a space'; do
  change "${c%%|*}"; run "fact: ${c##*|} (Jev answers no x3)"
done

echo; echo "############ C. Jev unsure or down: 'not rated', never lowers"
change src/parser.js:12
mode '{"irreversible":["yes",0.59]}'; run "yes below the 0.6 floor -> not counted, not rated (never low)"
mode '{"mismatch":["no",0.4]}';       run "no below the floor -> not rated (never low)"
mode '{"untested":["maybe",0.9]}';    run "answer outside the fixed yes/no list -> not counted"
mode '{"default":"http500"}';         run "Jev returns HTTP 500 -> not rated, registration intact, one call only"
mode '{"default":"garbage"}';         run "Jev returns non-JSON -> not rated"
mode '{"default":"hang"}';            run "Jev hangs past the 5s timeout -> not rated after ONE timeout"
mode '{}'; down;                      run "Jev unreachable (connection refused) -> not rated"
change db/migrations/0042_drop.sql:3; run "Jev unreachable on a migration -> stays high"
up; mode '{"default":["no",0.99]}';   run "Jev confidently says no x3 on a migration -> stays high (never lowers)"
mode '{}'; change src/parser.js:12; : > "$T/pr.json"; run "forge description unreadable -> mismatch unasked, not rated"
echo '{"title":"Tidy the parser","body":"Splits one long function."}' > "$T/pr.json"

echo; echo "############ D. Per-project opt-in: the key alone sends nothing"
mode '{"default":["yes",0.99]}'
list none;                       run "no config/jev-code-projects -> nothing sent, no forge read, not rated"
list '';                         run "empty list file -> nothing sent"
list '# alpha\nbeta\nalpha-two\nalph\n'; run "only '# alpha' comment and similar names -> nothing sent"
list '*\n.*\nalpha \n';          run "wildcards / trailing-space name do not match -> nothing sent"
change db/migrations/0042_drop.sql:3; run "unlisted project with a migration -> high from facts, questions named unanswered"
list '# may be sent\nbeta\n\nalpha\n'; mode '{}'; run "listed beside comment lines -> asked and rated"

echo; echo "############ E. Merge-time re-registration never rates"
run "listed project, key present, --no-risk -> registration only" "$ROOT/bin/fm-pr-check.sh" "$URL" --no-risk

echo; echo "############ F. Secondmate home: ready line unchanged, risk printed after armed"
printf 'mate-x\n' > "$H/.fm-secondmate-home"; printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$H/.fm-secondmate-parent"
rm -f "$H/state/parent-replies.status"
run "secondmate home, migration change"
echo "  parent channel line: $(cat "$H/state/parent-replies.status" 2>&1)"
rm -f "$H/.fm-secondmate-home" "$H/.fm-secondmate-parent"

echo; echo "############ G. GitLab merge request"
echo '{"title":"Drop legacy column","description":"Removes users.legacy via migration."}' > "$T/mr.json"
run "GitLab MR on a self-hosted host, description read through glab" "$ROOT/bin/fm-pr-check.sh" "https://gitlab.example.com/grp/sub/proj/-/merge_requests/5"
grep '^glab' "$T/children.log" | sed 's/^/  /'
