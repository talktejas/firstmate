#!/usr/bin/env bash
# Live guard for the delegate guard's Claude wiring.
#
# The verdict this hook depends on is vendor-emitted: the PreToolUse payload's
# tool_name, tool_input.file_path, and cwd fields, the anchored matcher, and
# Claude honoring an exit-2 deny with empty stdout. A stub can only confirm the
# assumption already written into it, so this guard drives the INSTALLED claude
# end to end: a primary-shaped home must deny a project read outright, and a
# crewmate-shaped linked worktree carrying the identical tracked registration
# bytes must stay inert.
#
# Both cases use exactly ONE Read call, so an operator's own global
# duplicate-read hooks cannot contaminate the verdict.
# It submits prompts and therefore spends model tokens: opt-in.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_DELEGATE_GUARD_LIVE claude jq

CLAUDE_VERSION=$(claude --version 2>&1)
TMP_ROOT=$(fm_test_tmproot fm-delegate-guard-claude-live)
HOME_DIR="$TMP_ROOT/home"
PROJ="$TMP_ROOT/proj"
CREW="$TMP_ROOT/crew"
SENTINEL="DELEGATE_LIVE_SENTINEL_7431"

mkdir -p "$HOME_DIR/bin" "$HOME_DIR/state" "$HOME_DIR/projects" "$HOME_DIR/.claude" "$PROJ/src"
cp "$ROOT/bin/fm-delegate-pretool-check.sh" "$ROOT/bin/fm-primary-scope-lib.sh" \
  "$ROOT/bin/fm-hook-host-lib.sh" "$HOME_DIR/bin/"
printf '# fixture\n' > "$HOME_DIR/AGENTS.md"
printf '<?php // %s\n' "$SENTINEL" > "$PROJ/src/config.php"
git -C "$PROJ" init -q

# The registration must be byte-shaped like the tracked one: resolved through
# CLAUDE_PROJECT_DIR so a linked worktree runs its own copy and scopes itself out.
cat > "$HOME_DIR/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "^(Bash|Read|Grep|Glob|Edit|Write|NotebookEdit|MultiEdit)$",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/bin/fm-delegate-pretool-check.sh --claude"
          }
        ]
      }
    ]
  }
}
JSON

git -C "$HOME_DIR" init -q
git -C "$HOME_DIR" config user.name fixture
git -C "$HOME_DIR" config user.email fixture@example.test
git -C "$HOME_DIR" add -A
git -C "$HOME_DIR" commit -qm fixture
git -C "$HOME_DIR" worktree add -q -b live-crew "$CREW"
mkdir -p "$CREW/state"

PROMPT="Use the Read tool exactly once to read $PROJ/src/config.php. If the call is blocked by a hook, quote the block message verbatim and stop. If it succeeds, print the file content and stop. Make no other tool calls."

test_primary_home_denies_a_project_read_live() {
  local out
  out=$(cd "$HOME_DIR" && claude -p "$PROMPT" --dangerously-skip-permissions --output-format text </dev/null 2>&1) \
    || fail "claude $CLAUDE_VERSION: primary-home live run failed: $out"
  case "$out" in
    *delegate-project-work*) ;;
    *) fail "claude $CLAUDE_VERSION did not surface the delegate guard's deny in a primary home: $out" ;;
  esac
  case "$out" in
    *"$SENTINEL"*) fail "claude $CLAUDE_VERSION read the project file despite the deny: $out" ;;
  esac
  pass "claude $CLAUDE_VERSION honors the delegate guard's deny end to end in a primary home"
}

test_crewmate_worktree_stays_inert_live() {
  local out
  out=$(cd "$CREW" && claude -p "$PROMPT" --dangerously-skip-permissions --output-format text </dev/null 2>&1) \
    || fail "claude $CLAUDE_VERSION: crew-worktree live run failed: $out"
  case "$out" in
    *delegate-project-work*) fail "claude $CLAUDE_VERSION was blocked by the delegate guard inside a crewmate-shaped worktree: $out" ;;
  esac
  case "$out" in
    *"$SENTINEL"*) ;;
    *) fail "claude $CLAUDE_VERSION did not read the project file in the inert worktree case: $out" ;;
  esac
  pass "claude $CLAUDE_VERSION leaves a crewmate-shaped worktree unguarded with the identical tracked bytes"
}

test_primary_home_denies_a_project_read_live
test_crewmate_worktree_stays_inert_live
