#!/usr/bin/env python3
# fm-captain-message-backfill.py - fill recorded message context from its task.
#
# Older rows are brought to what the capture records today, by the capture's
# own rules in bin/fm-captain-message-sweep.py, reading each captured row's turn
# back from the conversation record:
#   - A captured row the capture would now fold into a by-hand row (A MESSAGE
#     FIRSTMATE ALSO RECORDED BY HAND) is removed: the by-hand row, which
#     carries the labels, stands as the one record of it, and the capture's
#     cursor remembers that row as taken so the message never comes back.
#   - A row with no project is labelled by the same evidence (WHICH WORK A
#     MESSAGE IS ABOUT), from its turn and its own text, and stays unknown
#     where that evidence names no project or several.
# A row carrying a task id then has its missing project and worktree filled
# from state/<task>.meta, the same authoritative record Bearings uses. A branch
# is never derived from a worktree: its current branch says nothing about which
# branch a past message was about, so a branch stays unknown unless the row
# already recorded it, a by-hand row of its turn or the message itself names it
# (verified against the project's clone), or the task is a second mate, whose
# record names its owned project's development branch. It never consults the
# caller's current directory. Read receipts (rows with a kind) are copied as
# they are.
#
# It overwrites a recorded value in one case only: a row the old resolution
# filed under a second mate's own machinery. When the task has a
# kind=secondmate state/<task>.meta, is registered in data/secondmates.md, owns
# at least one project, and the row's worktree is that meta's worktree= and its
# project the basename of its project= (what the old resolution wrote), the row's project, worktree and branch are replaced with what
# a new write records (the owned project or the mate's name, no worktree, the
# development branch). Every other field is kept.
#
# Usage:
#   fm-captain-message-backfill.py [--home <FM_HOME>]
#
# Output: one JSON summary on stdout. `changed` is the number of log rows whose
# missing context was filled or relabelled; `relabelled` counts the latter.
# `labelled` counts rows that had no project and gained one, `unknown` the
# message rows still without one, and `folded` the captured duplicates removed.
# `unresolved` is the number still missing one or more context fields (a second
# mate's row never needs a worktree); `unresolved_reasons` says why. Re-running
# converges: an already-filled or relabelled row is not changed again. A malformed or torn log row is copied
# without alteration and counted under `malformed_row`.
#
# The command takes the log's write lock, shared with the sweep and
# bin/fm-captain-message.sh, so no concurrent append is lost to its rewrite. If
# a writer owns it, it exits successfully with `busy:true` and changes nothing.
import argparse
import fcntl
import json
import os
import re
import sys
import tempfile
import importlib.util
from collections import Counter

_spec = importlib.util.spec_from_file_location(
    "fm_captain_message_sweep",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-captain-message-sweep.py"))
capture = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(capture)


def turns_by_request(home):
    """requestId -> (task ids its turn's tool calls named, the by-hand row ids
    its recorder wrote, when its prompt came), from every transcript the
    capture knows of."""
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
        for req, _at, _session, _text, found, hand, start in capture.parse_batch(lines):
            tasks.setdefault(req, (found, hand, start))
    return tasks


def missing(row, field):
    return not isinstance(row.get(field), str) or not row[field].strip()


def registered_mates(home):
    try:
        with open(os.path.join(home, "data", "secondmates.md"), encoding="utf-8") as fh:
            return {m.group(1) for m in (re.match(r"- ([A-Za-z0-9._-]+) - ", line) for line in fh) if m}
    except OSError:
        return set()


def same_path(a, b):
    return isinstance(a, str) and isinstance(b, str) and bool(a) and bool(b) \
        and os.path.normpath(a) == os.path.normpath(b)


def relabel(row, record, task, mates):
    """Replace a second mate's own machinery, recorded by the old resolution,
    with the work it owns; True when the row was relabelled."""
    if task not in mates or not record.get("projects") or not record.get("meta_project") \
            or not same_path(row.get("worktree"), record.get("meta_worktree")) \
            or row.get("project") != record["meta_project"]:
        return False
    for field in ("project", "worktree", "branch"):
        row[field] = record.get(field)
    return True


def resolve(row, state, turns, mates, ctx, by_hand):
    task = row.get("task")
    found, hand, _start = turns.get(row.get("req"), (set(), [], ""))
    if missing(row, "project"):
        work = capture.work_for(ctx, row.get("text") if isinstance(row.get("text"), str) else "",
                                found | ({task} if isinstance(task, str) and task else set()),
                                [by_hand[i] for i in hand if i in by_hand])
        for field in ("task", "project", "worktree", "branch"):
            if missing(row, field) and work.get(field):
                row[field] = work[field]
        task = row.get("task")
    record = capture.task_record(state, task) if task else None
    mate = bool(record) and "home" in record
    relabelled = mate and relabel(row, record, task, mates)
    if record:
        for field in ("project", "worktree"):
            if missing(row, field) and record.get(field):
                row[field] = record[field]
        if missing(row, "branch") and record.get("branch") and row.get("project") == record["project"]:
            row["branch"] = record["branch"]
    if not missing(row, "project"):
        row.pop("resolution", None)

    required = ("project", "branch") if mate else ("project", "worktree", "branch")
    if all(not missing(row, field) for field in required):
        return None, relabelled
    if not isinstance(task, str) or not task:
        return "no_task_record", relabelled
    if not record:
        return "task_metadata_unavailable", relabelled
    if missing(row, "worktree") and not mate:
        return "task_metadata_has_no_worktree", relabelled
    if missing(row, "project"):
        return "task_metadata_has_no_project", relabelled
    return "branch_not_recorded", relabelled


def backfill(home):
    state = os.path.join(home, "state")
    log = os.path.join(home, "data", "captain-messages.jsonl")
    summary = Counter(rows=0, changed=0, relabelled=0, unresolved=0, malformed_rows=0,
                      labelled=0, unknown=0, folded=0)
    reasons = Counter()
    if not os.path.exists(log):
        return summary, reasons

    with open(log, "rb") as source:
        lines = source.readlines()
    turns = turns_by_request(home)
    mates = registered_mates(home)
    ctx = capture.evidence_context(home)
    _reqs, by_hand = capture.recorded(log)
    cursor_path = os.path.join(state, ".captain-message-sweep")
    try:
        with open(cursor_path, encoding="utf-8") as fh:
            cursor = json.load(fh)
    except (OSError, ValueError):
        cursor = None
    cursor = cursor if isinstance(cursor, dict) and isinstance(cursor.get("files"), dict) else None
    used = dict(cursor.get("used") or {}) if cursor and isinstance(cursor.get("used"), dict) else {}
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
        if "kind" in row:
            output.append(raw)      # a read receipt, not a message
            continue
        req, text = row.get("req"), row.get("text")
        if isinstance(req, str) and req in turns and isinstance(text, str):
            _found, hand, start = turns[req]
            routed = capture.routed_row(req, text, row.get("at") or "", start, hand, by_hand, used)
            if routed:
                used[routed] = req
                summary["folded"] += 1
                continue            # the by-hand row already carries this message
        summary["rows"] += 1
        unlabelled = missing(row, "project")
        original = json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        reason, relabelled = resolve(row, state, turns, mates, ctx, by_hand)
        summary["labelled"] += unlabelled and not missing(row, "project")
        summary["unknown"] += missing(row, "project")
        summary["relabelled"] += relabelled
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
    # A folded message must stay folded when the capture reads its turn again;
    # with no cursor there is no floor to keep, and a fresh one would read
    # everything, so a missing cursor is left missing.
    if cursor and summary["folded"]:
        cursor["used"] = used
        capture.write_cursor(cursor_path, cursor)
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
            print(json.dumps({"busy": True, "changed": 0, "relabelled": 0, "rows": 0, "unresolved": 0,
                              "labelled": 0, "unknown": 0, "folded": 0,
                              "unresolved_reasons": {}}))
            return 0
        try:
            summary, reasons = backfill(home)
        except Exception as exc:
            print(f"fm-captain-message-backfill: {exc}", file=sys.stderr)
            return 1
    print(json.dumps({"busy": False, "rows": summary["rows"], "changed": summary["changed"],
                      "relabelled": summary["relabelled"], "labelled": summary["labelled"],
                      "unknown": summary["unknown"], "folded": summary["folded"],
                      "unresolved": summary["unresolved"], "malformed_rows": summary["malformed_rows"],
                      "unresolved_reasons": dict(sorted(reasons.items()))}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
