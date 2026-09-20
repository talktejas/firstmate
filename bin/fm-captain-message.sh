#!/usr/bin/env bash
# fm-captain-message.sh - the durable record of what firstmate SAID to the captain.
#
# Firstmate's records hold the work: a held task, a stopped worker, a merged PR.
# None of them hold the MESSAGE - the sentence firstmate actually put in front of
# the captain. Until this file existed the terminal was the only copy of that, and
# a terminal scrolls, so everything firstmate said while he was away was gone.
# This appends one line per message to an append-only log so the command center
# can show him every one of them (bin/command-center.py, docs/command-center.md).
#
# ONE WRITER, CALLED BY THE SUPERVISOR. There is deliberately no capture of
# terminal output and no harness hook: firstmate calls this as it sends the
# message. AGENTS.md section 9 carries that obligation.
#
# Usage:
#   fm-captain-message.sh --title <title> [options] <text>...
#   fm-captain-message.sh --title <title> [options] -        (body from stdin)
#
#   --title <t>     the short line the captain sees in the list. required.
#   --task <id>     a task in this home; fills project, worktree and branch from
#                   its own record unless the flags below override them.
#   --project <p>   --worktree <path>   --branch <b>
#   --question           this message IS the question waiting on him, so his
#                        reply in the command center answers it.
#   --question-key <k>   the stopped worker's own decision key it asks about;
#                        implies --question. Omit it for a captain hold, which
#                        has no key.
#
# WHETHER A MESSAGE IS A QUESTION IS RECORDED, NEVER GUESSED. A task collects
# several messages over its life - the question, then the PR, then the result -
# so a reply routed by task id alone would be written as the answer to whatever
# decision that task happens to be stopped on. Only a message marked here is
# answerable, and only against the decision it names.
#
# The captain's standing rule is that every item names its project, its worktree
# and its branch, so --task exists to make supplying all three one flag rather
# than three chances to leave one out. A field nothing knows is recorded as null
# and shown as unknown; it is never guessed.
#
# Environment:
#   FM_HOME   operational home whose data/ is written (default: the code root).
#
# Output: the new message's id on stdout.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
LOG="$FM_HOME/data/captain-messages.jsonl"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

fail() {
  printf 'fm-captain-message: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"

title='' task='' project='' worktree='' branch='' question=0 question_key=''
while [ $# -gt 0 ]; do
  case "$1" in
    --title)    title=${2-}; shift 2 ;;
    --task)     task=${2-}; shift 2 ;;
    --project)  project=${2-}; shift 2 ;;
    --worktree) worktree=${2-}; shift 2 ;;
    --branch)   branch=${2-}; shift 2 ;;
    --question) question=1; shift ;;
    --question-key) question_key=${2-}; question=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    # Anything else begins the message. A body is often a bullet list, so an
    # argument starting with a dash is his text, not a misspelled flag: a log
    # whose whole purpose is that no message is lost may not refuse one.
    *)  break ;;
  esac
done

[ -n "$title" ] || fail "a message needs --title: it is the line he reads in the list"
[ $# -gt 0 ] || fail "no message text"

if [ "$1" = - ] && [ $# -eq 1 ]; then
  text=$(cat)
else
  text="$*"
fi
[ -n "${text//[[:space:]]/}" ] || fail "an empty message is not a message"

# The task's own record answers project and worktree; the branch is recorded
# nowhere, so it is read live from the worktree, exactly as the command center's
# scan does. Each is filled only where the caller left it empty.
if [ -n "$task" ]; then
  meta="$FM_HOME/state/$task.meta"
  if [ -f "$meta" ]; then
    if [ -z "$project" ]; then
      project=$(sed -n 's/^project=//p' "$meta" | head -1)
      project=${project##*/}
    fi
    [ -n "$worktree" ] || worktree=$(sed -n 's/^worktree=//p' "$meta" | head -1)
  fi
fi
if [ -z "$branch" ] && [ -n "$worktree" ] && [ -d "$worktree" ]; then
  branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=
fi

# ponytail: the id is the append time plus the pid, which is unique enough for a
# log one supervisor appends to; a counter would need a lock this does not need.
id="m$(date -u +%Y%m%dT%H%M%SZ)-$$"

mkdir -p "$(dirname "$LOG")"
line=$(jq -cn \
  --arg id "$id" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg title "$title" --arg text "$text" --arg task "$task" \
  --arg project "$project" --arg worktree "$worktree" \
  --arg branch "$branch" --argjson question "$question" \
  --arg question_key "$question_key" '
  def n: if . == "" then null else . end;
  {id:$id, at:$at, title:$title, text:$text,
   task:($task|n), project:($project|n), worktree:($worktree|n),
   branch:($branch|n), question:($question == 1),
   question_key:($question_key|n)}')
printf '%s\n' "$line" >> "$LOG"
printf '%s\n' "$id"
