#!/usr/bin/env bash
# Drives the tracked Claude PreToolUse registration of the delegate guard exactly as Claude Code does:
# the settings.json hook command, CLAUDE_PROJECT_DIR = an isolated primary home, PreToolUse JSON on stdin.
L=$(cat "$(dirname "$0")/.live-root"); HOME_DIR=$L/home
HOOK=$(jq -r '.hooks.PreToolUse[] | .hooks[] | .command | select(test("fm-delegate-pretool"))' "$HOME_DIR/.claude/settings.json")
run() { # expect cwd command
  local exp=$1 cwd=$2 cmd=$3 rc=0 err
  err=$(jq -nc --arg c "$cmd" --arg d "$cwd" '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
    | (cd "$cwd" && env -u FM_HOME -u FM_ROOT_OVERRIDE CLAUDE_PROJECT_DIR="$HOME_DIR" bash -c "$HOOK") 2>&1 >/dev/null) || rc=$?
  local got=ALLOW; [ $rc -eq 2 ] && got=DENY; [ $rc -ne 0 ] && [ $rc -ne 2 ] && got="EXIT$rc"
  local mark=PASS; [ "$got" = "$exp" ] || mark=FAIL
  printf '%s | expect %-5s got %-5s | %s\n' "$mark" "$exp" "$got" "$cmd"
  [ "$got" = DENY ] && [ -n "${SHOWMSG:-}" ] && printf '      reason: %s\n' "$(printf '%s' "$err" | jq -r .systemMessage)"
  return 0
}
H=$HOME_DIR; P=$HOME_DIR/projects/koin; k=talktejas/koin; u=https://github.com/talktejas/koin
echo "== S1 the incident: compare branches against develop and delete them by hand =="
SHOWMSG=1 run DENY $H "gh api repos/$k/compare/develop...feature/a --jq .ahead_by"
run DENY $H "for b in a b c; do gh api -X DELETE repos/$k/git/refs/heads/feature/\$b; done"
run DENY $H "git push $u --delete feature/a feature/b"
run DENY $P "git push origin --delete feature/a"
run DENY $H "gh api --method=DELETE /repos/$k/git/refs/heads/x"
run DENY $H "gh api -XDELETE repos/$k/git/refs/heads/x"
echo "== S2 PR / issue writes on a project =="
SHOWMSG=1 run DENY $H "gh pr merge 5 --squash -R $k"
run DENY $H "gh pr create -R $k -t t -b b"
run DENY $H "gh-axi pr comment 5 -R $k --body hi"
run DENY $H "gh issue close 3 --repo $k"
run DENY $H "gh api -X POST repos/$k/issues/3/comments -f body=hi"
run DENY $H "gh api repos/$k/pulls/5/merge -X PUT"
run DENY $P "gh pr close 5"
echo "== S3 repo settings / visibility / default branch / releases / tags =="
run DENY $H "gh repo edit $k --visibility public --accept-visibility-change-consequences"
run DENY $H "gh repo edit $k --default-branch main"
run DENY $H "gh api -X PATCH repos/$k -f default_branch=main"
run DENY $H "gh release create v1.0 -R $k"
run DENY $H "gh api repos/$k/git/tags -f tag=v1"
run DENY $H "gh repo rename new -R $k"
echo "== S4 reading project file contents through the forge =="
SHOWMSG=1 run DENY $H "gh api repos/$k/contents/app.php"
run DENY $H "gh pr diff 5 -R $k"
run DENY $H "gh api -H 'Accept: application/vnd.github.raw' repos/$k/contents/app.php"
run DENY $H "gh api repos/$k/pulls/5 -H 'Accept: application/vnd.github.DIFF'"
run DENY $H "curl -sL https://raw.githubusercontent.com/$k/develop/app.php"
run ALLOW $H "gh repo clone $k $H/projects/koin2"   # onboarding: clone is allowed, the disk rule governs the copy
run DENY $H "cat $P/src/app.php"   # ...and reading the cloned project on disk is refused
run DENY $H "gh api 'search/code?q=repo:$k+secret'"
run DENY $H "gh api repositories/12345/contents/app.php"
run DENY $H "gh browse app.php -R $k -n"
echo "== S5 firstmate's own merge/record path and supervision reads still work =="
run ALLOW $H "bin/fm-pr-merge.sh task-1 $u/pull/5"
run ALLOW $H "bin/fm-pr-check.sh task-1 $u/pull/5"
run ALLOW $H "gh pr view 5 -R $k --json state,mergeable,statusCheckRollup"
run ALLOW $H "gh pr checks 5 --repo $k"
run ALLOW $H "gh-axi pr view 5 -R $k"
run ALLOW $H "gh run view 99 -R $k"
run ALLOW $H "gh api repos/$k/pulls/5 --jq .mergeable"
run ALLOW $H "gh api repos/$k/commits/abc/check-runs"
run ALLOW $H "gh pr list -R $k --state open"
echo "== S6 firstmate's own repository is not a project =="
run ALLOW $H "gh pr create -R talktejas/firstmate --title t --body b"
run ALLOW $H "gh pr close 12"
run ALLOW $H "git push origin HEAD:refs/heads/fm/x"
run ALLOW $H "gh api -X DELETE repos/talktejas/firstmate/git/refs/heads/old"
run ALLOW $H "gh api repos/talktejas/firstmate/contents/AGENTS.md"
echo "== S7 worker session (linked task worktree of the home) is untouched =="
W=$L/worker-wt; [ -d "$W" ] || { git -C "$H" worktree add -q --detach "$W"; mkdir -p "$W/state"; }
wrun() { local cmd=$1 rc=0
  jq -nc --arg c "$cmd" --arg d "$W" '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
   | (cd "$W" && env -u FM_HOME CLAUDE_PROJECT_DIR="$W" bash -c "$HOOK") >/dev/null 2>&1 || rc=$?
  [ $rc -eq 0 ] && echo "PASS | expect ALLOW got ALLOW | [worker] $cmd" || echo "FAIL | expect ALLOW got exit $rc | [worker] $cmd"; }
wrun "gh pr close 5 -R $k"
wrun "gh api -X DELETE repos/$k/git/refs/heads/old"
wrun "gh api repos/$k/contents/app.php"
wrun "git push $u HEAD:refs/heads/x"
