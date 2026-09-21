#!/usr/bin/env python3
# fm-captain-message-backfill.py - fill recorded message context from its task.
#
# Captured messages do not know what work they describe and must remain unknown.
# A row that already carries a task id is different: state/<task>.meta is the
# same authoritative record Bearings uses for project and worktree, and its
# worktree can authoritatively report its current branch. This command fills
# only missing fields from those records. It never extracts a task id from text,
# consults the caller's current directory, or overwrites a recorded value.
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
# The command shares the sweep lock, so it cannot race automatic capture. If a
# sweep owns it, it exits successfully with `busy:true` and changes nothing.
import argparse
import fcntl
import json
import os
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path


def branch_for(worktree):
    if not isinstance(worktree, str) or not os.path.isdir(worktree):
        return None
    result = subprocess.run(
        ["git", "-C", worktree, "symbolic-ref", "--quiet", "--short", "HEAD"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, check=False,
    )
    branch = result.stdout.strip()
    return branch if result.returncode == 0 and branch else None


def meta_records(state):
    records = {}
    try:
        paths = Path(state).glob("*.meta")
        for path in paths:
            try:
                values = {}
                for line in path.read_text(encoding="utf-8").splitlines():
                    key, sep, value = line.partition("=")
                    if sep and key in ("project", "worktree") and key not in values:
                        values[key] = value
                records[path.stem] = values
            except OSError:
                continue
    except OSError:
        pass
    return records


def missing(row, field):
    return not isinstance(row.get(field), str) or not row[field].strip()


def resolve(row, records):
    task = row.get("task")
    record = records.get(task) if isinstance(task, str) else None
    if record:
        if missing(row, "project"):
            project = record.get("project", "").strip()
            if project:
                row["project"] = os.path.basename(os.path.normpath(project))
        if missing(row, "worktree"):
            worktree = record.get("worktree", "").strip()
            if worktree:
                row["worktree"] = worktree
    if missing(row, "branch"):
        branch = branch_for(row.get("worktree"))
        if branch:
            row["branch"] = branch

    if all(not missing(row, field) for field in ("project", "worktree", "branch")):
        return None
    if not isinstance(task, str) or not task:
        return "no_task_record"
    if not record:
        return "task_metadata_unavailable"
    if missing(row, "worktree"):
        return "task_metadata_has_no_worktree"
    if missing(row, "branch"):
        return "worktree_unavailable_or_detached"
    return "task_metadata_has_no_project"


def backfill(home):
    state = os.path.join(home, "state")
    log = os.path.join(home, "data", "captain-messages.jsonl")
    records = meta_records(state)
    summary = Counter(rows=0, changed=0, unresolved=0, malformed_rows=0)
    reasons = Counter()
    if not os.path.exists(log):
        return summary, reasons

    with open(log, "rb") as source:
        lines = source.readlines()
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
        reason = resolve(row, records)
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
