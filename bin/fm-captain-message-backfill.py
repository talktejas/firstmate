#!/usr/bin/env python3
# fm-captain-message-backfill.py - fill recorded message context from its task.
#
# A row with no task id gets one only by the capture's own evidence rule
# (bin/fm-captain-message-sweep.py, WHICH WORK A MESSAGE IS ABOUT): the turn it
# was said in, read back from the conversation record, named exactly one task's
# own record in a tool call. A row carrying a task id then has its missing
# project and worktree filled from state/<task>.meta, the same authoritative
# record Bearings uses. A branch is never derived here: the worktree's current
# branch says nothing about which branch a past message was about, so a branch
# stays unknown unless the row already recorded it. It never extracts a task id
# from text, consults the caller's current directory, or overwrites a recorded
# value.
#
# Usage:
#   fm-captain-message-backfill.py [--home <FM_HOME>]
#
# Output: one JSON summary on stdout. `changed` is the number of log rows whose
# missing context was filled. `unresolved` is the number still missing one or
# more context fields; `unresolved_reasons` says why. Re-running converges: an
# already-filled row is not changed again. A malformed or torn log row is copied
# without alteration and counted under `malformed_row`.
#
# The command takes the log's write lock, shared with the sweep and
# bin/fm-captain-message.sh, so no concurrent append is lost to its rewrite. If
# a writer owns it, it exits successfully with `busy:true` and changes nothing.
import argparse
import fcntl
import json
import os
import sys
import tempfile
import importlib.util
from collections import Counter

_spec = importlib.util.spec_from_file_location(
    "fm_captain_message_sweep",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-captain-message-sweep.py"))
capture = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(capture)


def turn_tasks(home):
    """requestId -> the task ids its turn's tool calls named, from every
    transcript the capture knows of."""
    paths = set()
    directory = capture.default_transcript_dir(home)
    if os.path.isdir(directory):
        paths.update(os.path.join(directory, f) for f in os.listdir(directory)
                     if f.endswith(".jsonl"))
    try:
        with open(os.path.join(home, "state", ".captain-message-sweep"), encoding="utf-8") as fh:
            files = json.load(fh).get("files")
        if isinstance(files, dict):
            paths.update(files)
    except (OSError, ValueError, AttributeError):
        pass
    tasks = {}
    for path in sorted(paths):
        try:
            with open(path, "rb") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        for req, _at, _session, _text, found in capture.parse_batch(lines):
            tasks.setdefault(req, found)
    return tasks


def missing(row, field):
    return not isinstance(row.get(field), str) or not row[field].strip()


def resolve(row, state, turns):
    task = row.get("task")
    if not isinstance(task, str) or not task:
        task = capture.turn_task(turns.get(row.get("req"), set()))
        if task:
            row["task"] = task
    record = capture.task_record(state, task) if task else None
    if record:
        for field in ("project", "worktree"):
            if missing(row, field) and record.get(field):
                row[field] = record[field]

    if all(not missing(row, field) for field in ("project", "worktree", "branch")):
        return None
    if not isinstance(task, str) or not task:
        return "no_task_record"
    if not record:
        return "task_metadata_unavailable"
    if missing(row, "worktree"):
        return "task_metadata_has_no_worktree"
    if missing(row, "project"):
        return "task_metadata_has_no_project"
    return "branch_not_recorded"


def backfill(home):
    state = os.path.join(home, "state")
    log = os.path.join(home, "data", "captain-messages.jsonl")
    summary = Counter(rows=0, changed=0, unresolved=0, malformed_rows=0)
    reasons = Counter()
    if not os.path.exists(log):
        return summary, reasons

    with open(log, "rb") as source:
        lines = source.readlines()
    turns = turn_tasks(home)
    output = []
    for raw in lines:
        try:
            row = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError):
            summary["malformed_rows"] += 1
            output.append(raw)
            continue
        if not isinstance(row, dict):
            summary["malformed_rows"] += 1
            output.append(raw)
            continue
        summary["rows"] += 1
        original = json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        reason = resolve(row, state, turns)
        changed = json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":")) != original
        if changed:
            summary["changed"] += 1
            rendered = json.dumps(row, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
        else:
            rendered = raw
        if reason:
            summary["unresolved"] += 1
            reasons[reason] += 1
        output.append(rendered)

    directory = os.path.dirname(log)
    fd, temporary = tempfile.mkstemp(prefix=".captain-messages.", dir=directory)
    try:
        with os.fdopen(fd, "wb") as target:
            for raw in output:
                target.write(raw)
        os.replace(temporary, log)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    return summary, reasons


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--home", default=os.environ.get("FM_HOME") or os.getcwd())
    parser.add_argument("-h", "--help", action="help")
    args = parser.parse_args()
    home = os.path.abspath(args.home)
    state = os.path.join(home, "state")
    os.makedirs(state, exist_ok=True)
    with open(os.path.join(state, ".captain-message-sweep.lock"), "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print(json.dumps({"busy": True, "changed": 0, "rows": 0, "unresolved": 0,
                              "unresolved_reasons": {}}))
            return 0
        try:
            summary, reasons = backfill(home)
        except Exception as exc:
            print(f"fm-captain-message-backfill: {exc}", file=sys.stderr)
            return 1
    print(json.dumps({"busy": False, "rows": summary["rows"], "changed": summary["changed"],
                      "unresolved": summary["unresolved"], "malformed_rows": summary["malformed_rows"],
                      "unresolved_reasons": dict(sorted(reasons.items()))}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
