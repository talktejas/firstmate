#!/usr/bin/env bash
# Drives bin/fm-house-rules-check.sh as an end user would, in throwaway
# firstmate homes. Only the network edge (curl) is replaced.
set -u
WT=/home/tds/.no-mistakes/worktrees/3605d2c32b02/01M46J2PSMGGGB0MBZ2671F1AN
T=$(mktemp -d /tmp/hr-drive.XXXXXX); export HR_T=$T
TOOL=$WT/bin/fm-house-rules-check.sh
unset TYPESAFE_API_KEY FM_HOME FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE
KEY=drive-key-4411-not-real
say() { printf '\n===== %s =====\n' "$*"; }
run() { printf '$ %s\n' "$*" | sed "s#$WT/##g; s#$T#\$T#g"; "$@"; local c=$?; printf '[exit %s]\n' "$c"; return 0; }

# --- fake curl: the only stub. Logs each request, answers by FAKE_MODE -------
mkdir -p $T/fakebin $T/log
cat > $T/fakebin/curl <<'SH'
#!/usr/bin/env bash
log=$HR_T/log
out=''; while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
n=$(( $(cat $log/calls 2>/dev/null || echo 0) + 1 )); echo $n > $log/calls
cat > $log/body.$n
jq -r '.state.change.file' $log/body.$n >> $log/files
case "${FAKE_MODE:-smart}" in
  down) exit 7 ;;
  timeout) exit 28 ;;
  http500) echo 'upstream exploded' > "$out"; printf 500; exit 0 ;;
  garbage) echo '{"answers":{"house_rule":{"choice":"maybe"}}}' > "$out"; printf 200; exit 0 ;;
  unsure) echo '{"model":"jev-fake","answers":{"house_rule":{"choice":"yes","confidence":0.55,"probabilities":{"yes":0.55,"no":0.45}}}}' > "$out"; printf 200; exit 0 ;;
esac
# smart: yes only for the hard-coded commission rate under the hard-code rule,
# and the old-route redirect under a rule that asks about redirects.
c=no
if jq -e '(.questions.house_rule.instructions | test("hard-code")) and (.state.change.block | test("0\\.12"))' $log/body.$n >/dev/null; then c=yes; fi
if jq -e '(.questions.house_rule.instructions | test("redirect")) and (.state.change.block | test("redirect\\("))' $log/body.$n >/dev/null; then c=yes; fi
if [ $c = yes ]; then p='{"yes":0.97,"no":0.03}'; else p='{"yes":0.04,"no":0.96}'; fi
printf '{"model":"jev-fake","answers":{"house_rule":{"choice":"%s","confidence":0.96,"probabilities":%s}}}' $c "$p" > "$out"
printf 200
SH
chmod +x $T/fakebin/curl
reset_log() { rm -rf "$T/log"; mkdir -p "$T/log"; }
calls() { cat $T/log/calls 2>/dev/null || echo 0; }
fake() { env PATH="$T/fakebin:$PATH" "$@"; }

# --- homes ------------------------------------------------------------------
mkdir -p $T/home-keyonly $T/home-on/config $T/home-opted-nokey/config
printf 'TYPESAFE_API_KEY=%s\n' $KEY > $T/home-keyonly/.env
printf 'TYPESAFE_API_KEY=%s\n' $KEY > $T/home-on/.env
echo '{"projects": ["shop"]}' > $T/home-on/config/house-rules.json
echo '{"projects": ["shop"]}' > $T/home-opted-nokey/config/house-rules.json

# --- a project: local main ahead of a lagging origin/main, task branch on top -
R=$T/shop; mkdir -p $R/src $R/vendor
g() { git -C $R -c user.email=t@example.invalid -c user.name=t "$@"; }
g init -q -b main
printf '<?php\nfunction rate($sale) {\n  return settings("commission.rate");\n}\n' > $R/src/commission.php
printf '<?php\nRoute::get("/members", "MemberController@index");\n' > $R/src/routes.php
printf 'old\n' > $R/src/gone.php
g add -A; g commit -qm root
g update-ref refs/remotes/origin/main HEAD          # origin lags from here on
printf '<?php\n// another task, already merged locally\nfunction tax() { return 0.12 * 100; }\n' > $R/src/other_task.php
g add -A; g commit -qm "other task, merged to local main only"
g checkout -qb fm/task-1
printf '<?php\nfunction rate($sale) {\n  return $sale->isConsignment() ? 0.12 : 0.08;\n}\n' > $R/src/commission.php
printf '<?php\nRoute::get("/people", "MemberController@index");\nRoute::get("/members", fn () => redirect("/people"));\n' > $R/src/routes.php
printf '<?php\nfunction prefix() { return settings("invoice.prefix", "INV"); }\n' > $R/src/invoice.php
rm $R/src/gone.php
printf '# Shop\nrate is 0.12 now\n' > $R/README.md
printf 'password: 0.12-hunter2\n' > $R/src/Secrets.yml
printf 'API=0.12\n' > $R/.ENV
printf 'KEY 0.12\n' > $R/Server.PEM
printf 'creds 0.12\n' > $R/AWS_Credentials.json
printf 'x = 0.12\n' > $R/vendor/lib.js
printf '{"v":"0.12"}\n' > $R/package-lock.json
printf 'q = 0.12\n' > "$R/src/q\"uote.php"
g add -A; g commit -qm "task-1 work"
echo "fixture: task branch fm/task-1 changes these paths vs local main:"; g diff --name-status main | sed 's/^/  /'
echo "fixture: origin/main lags local main by $(g rev-list --count origin/main..main) commit (src/other_task.php, which also contains 0.12)"

say "S1 shipped default: a home with a key but no config/house-rules.json"
reset_log
(cd $R && run fake env FM_HOME=$T/home-keyonly $TOOL shop)
(cd $R && run fake env FM_HOME=$T/home-keyonly $TOOL --enabled shop)
echo "requests sent: $(calls)"
ls $WT/config 2>&1 | sed "s#$WT/##; s/^/repo ships: /"

say "S2 by hand for a project that is not opted in (key present, another project listed)"
reset_log
(cd $R && run fake env FM_HOME=$T/home-on $TOOL not-shop)
(cd $R && run fake env FM_HOME=$T/home-on TYPESAFE_API_KEY=$KEY $TOOL sho)
(cd $R && run fake env FM_HOME=$T/home-on $TOOL 'shop" or true or "')
(cd $R && run fake env FM_HOME=$T/home-on $TOOL SHOP)
for cfg in '{}' '{"projects": []}' '{"projects": "shop"}' '{"projects": {"shop": true}}' '{"rules": []}' 'not json'; do
  mkdir -p $T/home-x/config; printf 'TYPESAFE_API_KEY=%s\n' $KEY > $T/home-x/.env; printf '%s\n' "$cfg" > $T/home-x/config/house-rules.json
  printf 'config %s -> ' "$cfg"; (cd $R && fake env FM_HOME=$T/home-x $TOOL shop 2>&1; echo "[exit $?]") | sed "s#$T#\$T#g" | tr '\n' ' '; echo
done
echo "requests sent: $(calls)"

say "S3 opted in but no key"
reset_log
(cd $R && run fake env FM_HOME=$T/home-opted-nokey $TOOL shop)
echo "requests sent: $(calls)"

say "S4 opted in + key: flags with file:line on the task's own change"
reset_log
(cd $R && run fake env FM_HOME=$T/home-on $TOOL shop)
echo "requests sent: $(calls)"
echo "files offered to the model: $(sort -u $T/log/files | tr '\n' ' ')"
echo "--- first request body ---"
jq '{model, questions: (.questions | map_values({type, criteria: (.criteria | keys)})), state}' $T/log/body.1
grep -l "$KEY" $T/log/body.* >/dev/null 2>&1 && echo "KEY LEAKED INTO BODY" || echo "key absent from every request body"
echo "--- the flagged lines in the worktree ---"
printf 'src/commission.php:3 |%s\n' "$(sed -n '3p' $R/src/commission.php)"
printf 'src/routes.php:3     |%s\n' "$(sed -n '3p' $R/src/routes.php)"

say "S5 Jev down / erroring / unsure: no flag, exit 0"
for m in down timeout http500 garbage unsure; do
  reset_log
  printf -- '-- FAKE_MODE=%s\n' $m
  (cd $R && run fake env FAKE_MODE=$m FM_HOME=$T/home-on $TOOL shop)
  echo "requests sent: $(calls)"
done

say "S6 custom rules, empty rules, malformed rules"
mkdir -p $T/home-rules/config; printf 'TYPESAFE_API_KEY=%s\n' $KEY > $T/home-rules/.env
cat > $T/home-rules/config/house-rules.json <<'J'
{"projects": ["shop"], "rules": [{"id": "no-redirects", "question": "Do the added lines add a redirect matching \\d+ or 100%?", "yes": "They add a redirect.", "no": "They do not."}]}
J
reset_log; (cd $R && run fake env FM_HOME=$T/home-rules $TOOL shop)
echo '{"projects": ["shop"], "rules": []}' > $T/home-rules/config/house-rules.json
reset_log; (cd $R && run fake env FM_HOME=$T/home-rules $TOOL shop)
echo '{"projects": ["shop"], "rules": [{"id": "Bad Id", "question": "q"}]}' > $T/home-rules/config/house-rules.json
reset_log; (cd $R && run fake env FM_HOME=$T/home-rules $TOOL shop); echo "requests sent: $(calls)"

say "S7 usage errors, removed --base option, repo with no default branch, not a repo"
(cd $R && run fake env FM_HOME=$T/home-on $TOOL)
(cd $R && run fake env FM_HOME=$T/home-on $TOOL --base main shop)
git init -q -b trunk $T/nobase 2>/dev/null
reset_log; (cd $T/nobase && run fake env FM_HOME=$T/home-on $TOOL shop); echo "requests sent: $(calls)"
(cd $T && run fake env FM_HOME=$T/home-on $TOOL shop); echo "requests sent: $(calls)"

say "S8 large change: bounded at 60 calls"
B=$T/big; mkdir -p $B; gb() { git -C $B -c user.email=t@example.invalid -c user.name=t "$@"; }
gb init -q -b main; echo r > $B/r.sh; gb add -A; gb commit -qm r; gb checkout -qb fm/big
for i in $(seq 1 40); do printf 'v%s = %s\n' $i $i > $B/f$i.sh; done; gb add -A; gb commit -qm big
reset_log; (cd $B && run fake env FM_HOME=$T/home-on $TOOL shop); echo "requests sent: $(calls)"
echo; echo "scratch dir: $T"
