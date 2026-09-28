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
# THE BY-HAND WRITER. On a Claude primary the log is filled automatically by
# bin/fm-captain-message-sweep.py reading the conversation record, which never
# marks a message as a question. This script is the ROUTING path: a question
# tied to a decision is recorded here with --question, and an answer to one of
# his notes with --answers; the capture keeps this row instead of adding a copy
# when the same turn's final message says the same thing. It is also the only
# writer for what that record cannot see: another primary harness, or something
# said outside the recorded conversation. AGENTS.md section 9 carries that split.
#
# Usage:
#   fm-captain-message.sh --title <title> [options] <text>...
#   fm-captain-message.sh --title <title> [options] -        (body from stdin)
#
#   --title <t>     the short line the captain sees in the list; when left out,
#                   the message's first line stands in for it.
#   --task <id>     a task in this home; fills project, worktree and branch from
#                   its own record (state/<id>.meta), else its project from its
#                   backlog line's (repo: r), unless the flags below override
#                   them. An id nothing resolves is still recorded (see below).
#   --general       this message is about no task. Optional: a message naming
#                   no task is recorded the same way, and --task wins over it.
#   --project <p>   --worktree <path>   --branch <b>
#   --question           this message IS the question waiting on him, so his
#                        reply in the command center answers it.
#   --question-key <k>   the stopped worker's own decision key it asks about;
#                        implies --question. Omit it for a captain hold, which
#                        has no key.
#   --answers <note-id>  the captain's inbox note this message answers: the id
#                        fm-inbox.sh list and drain print above the note, and
#                        the one drain --ack takes. A note from the command
#                        center is headed 'Reply to message <msg-id> - ...';
#                        pass the note's own id, not that msg-id. The page
#                        threads this message under his. Recorded as "answers";
#                        left out entirely when absent, and left out with a
#                        warning when no note in state/inbox/ or
#                        state/inbox/handled/ has that id, so the message shows
#                        on its own rather than under a note that is not there.
#
# WHETHER A MESSAGE IS A QUESTION IS RECORDED, NEVER GUESSED. A task collects
# several messages over its life - the question, then the PR, then the result -
# so a reply routed by task id alone would be written as the answer to whatever
# decision that task happens to be stopped on. Only a message marked here is
# answerable, and only against the decision it names.
#
# The captain's standing rule is that every item names its project, its worktree
# and its branch, so --task exists to make supplying all three one flag rather
# than three chances to leave one out. A missing label never costs him the
# message: nothing about the work being unresolvable refuses a message, because
# a message never recorded is a message he never sees. A field nothing knows is
# recorded as null and shown as unknown; it is never guessed. When a --task was
# given and still no project resolves, the id stays as the task firstmate named
# and the record gains "resolution":"failed" (absent on every other record), so
# the page can show it as an ordinary message whose label is unknown. The only
# failures left are a destination that cannot be written and a message with no
# words in it.
#
# Every write to the log, and the backfill's rewrite of it, holds
# state/.captain-message-sweep.lock, so no writer's line is lost to another.
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
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

title='' task='' project='' worktree='' branch='' question=0 question_key='' answers=''
while [ $# -gt 0 ]; do
  case "$1" in
    --title)    title=${2-}; shift 2 ;;
    --task)     task=${2-}; shift 2 ;;
    --general)  shift ;;  # naming no task says the same; kept for its callers
    --project)  project=${2-}; shift 2 ;;
    --worktree) worktree=${2-}; shift 2 ;;
    --branch)   branch=${2-}; shift 2 ;;
    --question) question=1; shift ;;
    --question-key) question_key=${2-}; question=1; shift 2 ;;
    --answers)  answers=${2-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    # Anything else begins the message. A body is often a bullet list, so an
    # argument starting with a dash is his text, not a misspelled flag: a log
    # whose whole purpose is that no message is lost may not refuse one.
    *)  break ;;
  esac
done

warn() {
  printf 'fm-captain-message: %s\n' "$*" >&2
}

[ $# -gt 0 ] || fail "no message text"

if [ "$1" = - ] && [ $# -eq 1 ]; then
  text=$(cat)
else
  text="$*"
fi
[ -n "${text//[[:space:]]/}" ] || fail "an empty message is not a message"
if [ -z "${title//[[:space:]]/}" ]; then
  title=$(printf '%s\n' "$text" | awk 'NF { sub(/^[[:space:]]+/, ""); print substr($0, 1, 80); exit }')
  warn "no --title; recorded under its first line: $title"
fi

if [ -n "$answers" ]; then
  case "$answers" in
    */*|.*) found=0 ;;
    *) found=1; [ -f "$FM_HOME/state/inbox/$answers.note" ] || [ -f "$FM_HOME/state/inbox/handled/$answers.note" ] || found=0 ;;
  esac
  if [ "$found" -eq 0 ]; then
    warn "--answers $answers matches no note in state/inbox/ or state/inbox/handled/; recorded on its own, not under a note"
    answers=''
  fi
fi

# The task's own record answers project and worktree, read by the capture's
# resolver so both writers name the same work (task_record in
# bin/fm-captain-message-sweep.py, which also turns a second mate's home into
# the project it owns). An ordinary task's branch is recorded nowhere, so it is
# read live from the worktree, exactly as the command center's scan does. A task
# with no record falls back to its backlog line's project (backlog_project).
# Each is filled only where the caller left it empty.
rec_project='' rec_worktree='' rec_branch='' resolution=''
if [ -n "$task" ]; then
  { IFS= read -r rec_project; IFS= read -r rec_worktree; IFS= read -r rec_branch; } < <(
    python3 - "$SCRIPT_DIR/fm-captain-message-sweep.py" "$FM_HOME" "$task" <<'PYEOF'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fm_captain_message_sweep", sys.argv[1])
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)
home, task = sys.argv[2], sys.argv[3]
record = capture.task_record(os.path.join(home, "state"), task) or {}
if not record.get("project"):
    record["project"] = capture.backlog_project(home, task)
for field in ("project", "worktree", "branch"):
    print((record.get(field) or "").replace("\n", " "))
PYEOF
  ) || true
  [ -n "$project" ] || project=$rec_project
  [ -n "$worktree" ] || worktree=$rec_worktree
  if [ -z "$project" ]; then
    resolution=failed
    warn "--task $task resolved to no project; recorded with its project unknown"
  fi
fi
if [ -z "$branch" ] && [ -n "$worktree" ] && [ -d "$worktree" ]; then
  branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=
fi
[ -n "$branch" ] || branch=$rec_branch

# ponytail: the id is the append time plus the pid, which is unique enough for a
# log one supervisor appends to; a counter would need a lock this does not need.
id="m$(date -u +%Y%m%dT%H%M%SZ)-$$"

mkdir -p "$(dirname "$LOG")" "$FM_HOME/state"
line=$(jq -cn \
  --arg id "$id" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg title "$title" --arg text "$text" --arg task "$task" \
  --arg project "$project" --arg worktree "$worktree" \
  --arg branch "$branch" --argjson question "$question" \
  --arg question_key "$question_key" --arg answers "$answers" \
  --arg resolution "$resolution" '
  def n: if . == "" then null else . end;
  {id:$id, at:$at, title:$title, text:$text,
   task:($task|n), project:($project|n), worktree:($worktree|n),
   branch:($branch|n), question:($question == 1),
   question_key:($question_key|n)}
  + (if $answers == "" then {} else {answers:$answers} end)
  + (if $resolution == "" then {} else {resolution:$resolution} end)')
# The automatic capture can be killed on its Stop-hook bound mid-write, so this
# log's last line may be a torn one. The sweep's appender mends it before adding
# to it (bin/fm-captain-message-sweep.py), and so does this: a record glued onto
# a torn line is unreadable, and takes the torn one's message down with it.
python3 - "$FM_HOME/state/.captain-message-sweep.lock" "$LOG" "$line" <<'PYEOF'
import fcntl, sys
lock_path, log, line = sys.argv[1:]
with open(lock_path, "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    with open(log, "ab+") as target:
        target.seek(0, 2)
        if target.tell():
            target.seek(-1, 2)
            if target.read(1) != b"\n":
                target.write(b"\n")
        target.write(line.encode("utf-8") + b"\n")
PYEOF
printf '%s\n' "$id"
