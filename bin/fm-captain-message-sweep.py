#!/usr/bin/env python3
# fm-captain-message-sweep.py - the automatic half of the captain-message log.
#
# bin/fm-captain-message.sh records a captain-facing message only when firstmate
# remembers to call it, and across one day firstmate forgot dozens of times.
# This sweep removes the remembering: it reads the Claude conversation record on
# disk, which holds every message verbatim, and appends every turn-final
# assistant message it has not yet recorded to data/captain-messages.jsonl -
# the same log, read back by the command center (docs/command-center.md).
#
# WHICH TRANSCRIPTS. The Stop hook's payload NAMES the transcript the session
# is writing, and that name is authoritative: --from-payload reads the payload
# on stdin and sweeps exactly that file. Nothing else knows it - the directory
# this falls back to is derived from the home's path, and a session started
# from anywhere else writes somewhere else entirely, which is how a message can
# be said and never appear. Every transcript a payload has named is remembered
# and swept by the directory runs too, and until one has, the capture record
# says the directory is only inferred so the page never shows a green band over
# a list it cannot vouch for.
#
# WHO RUNS IT. Two callers, each enough for what it can see:
#   - bin/fm-captain-message-hook.sh, a Claude Stop hook, right as a turn ends,
#     pinned to that turn's own transcript;
#   - bin/command-center.py, on its poll cadence, over the inferred directory
#     and every named transcript, which also catches turns that ended without a
#     Stop (interrupt, crash, kill) once their session moves on.
# A file lock serializes them, and every run dedupes against the messages
# already in the log, so running it twice - or recovering a lost cursor - can
# never record the same message twice.
#
# WHAT COUNTS AS A MESSAGE. An assistant response whose stop_reason is end_turn:
# exactly the messages the harness presented as a reply.
# Mid-turn narration before a tool call carries stop_reason tool_use and is
# deliberately not a message; sidechain (subagent) entries are never his chat.
# Entries the harness itself authored are excluded too, whether they are
# flagged (isApiErrorMessage) or only marked by model "<synthetic>" - the
# latter reads exactly like a reply ("No response requested.") and firstmate
# never said it.
# One response can span several transcript lines (one per content block, sharing
# a requestId), so text blocks are joined per requestId in block order.
# A sweep killed on its bound can stop mid-write, so the log is appended to in
# whole lines and mended before use (append_rows): a torn line costs itself and
# nothing after it, and the message it was carrying is recorded by the next run.
#
# ponytail: if a sweep lands exactly between two text blocks of one response,
# the recorded message can miss the trailing block. The next batch reads that
# requestId again, so the log's own requestIds are consulted for every batch,
# never only the first: a split response is at worst short by a block, never a
# second row wearing the same id.
#
# A MESSAGE FIRSTMATE ALSO RECORDED BY HAND. A question tied to a decision is
# recorded by firstmate itself with bin/fm-captain-message.sh --question, which
# is the only row that knows where a reply to it goes. The routed row and the
# captured one are the same words, so the words are what match them: a final
# message whose text a by-hand row already carries is not added beside it. Each
# by-hand row stands for one captured message and no more - which ones have
# already done so is kept with the cursor, so saying the same thing again in a
# later turn is still recorded. This never decides a message is a question.
#
# BACKFILL AND THE FLOOR. The first run has no cursor and reads every transcript
# from the top, so the log starts complete from the floor - today's local
# midnight unless --since says otherwise. The floor is stored and applied
# forever after, because a resumed session copies older history into a new
# transcript file and those copies must not resurface as new messages.
#
# HONESTY. Every run, success or failure, rewrites state/.captain-message-capture
# with what happened; the command center reads it and says when this list may be
# incomplete instead of quietly showing a short one.
#
# Usage:
#   fm-captain-message-sweep.py [--home <FM_HOME>] [--transcripts <dir>]
#                               [--since <ISO>] [--from-payload]
#
#   --home          operational home (default: $FM_HOME, else the code root)
#   --transcripts   transcript directory (default: $CLAUDE_CONFIG_DIR or
#                   ~/.claude, /projects/<encoded home path>)
#   --since         first-run floor override, ISO-8601 UTC; ignored once a
#                   floor is stored
#   --from-payload  read a Claude hook payload on stdin and sweep only the
#                   transcript it names; a payload naming none does nothing
#
# State (all under <home>/state/, atomically replaced, safe to delete):
#   .captain-message-sweep       per-transcript byte cursor, which transcripts
#                                a payload has named, and the stored floor
#   .captain-message-sweep.lock  serializes concurrent sweeps
#   .captain-message-capture     the last run's outcome, read by the page
#
# Exit: 0 on success or when another sweep holds the lock; 1 on failure, with
# the failure also written to the capture record.
import argparse
import fcntl
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone

FINAL_STOPS = ("end_turn",)


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def default_transcript_dir(home):
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    encoded = re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(home))
    return os.path.join(base, "projects", encoded)


def local_midnight_utc():
    now = datetime.now().astimezone()
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    return midnight.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def clean_ts(ts):
    """2026-09-20T17:10:53.250Z -> 2026-09-20T17:10:53Z; anything else as-is."""
    return re.sub(r"\.\d+Z$", "Z", ts) if isinstance(ts, str) else ""


def derive_title(text):
    """The line he reads in the list: the first real line, markdown stripped."""
    for line in text.splitlines():
        s = line.strip()
        s = re.sub(r"^#{1,6}\s+", "", s)
        s = re.sub(r"^[>*-]\s+", "", s)
        s = s.replace("**", "").replace("`", "").strip()
        if s:
            if len(s) > 100:
                s = s[:100].rsplit(" ", 1)[0] + "…"
            return s
    return text.strip()[:100] or "(no text)"


def same_text(text):
    return " ".join(text.split())


def recorded(log_path):
    """The log itself is the dedupe record: the requestIds already captured,
    and the by-hand rows as {text: [id, ...]}."""
    reqs, hand = set(), {}
    try:
        with open(log_path, "rb") as fh:
            for line in fh:
                m = re.search(rb'"req":"([^"]*)"', line)
                if m:
                    reqs.add(m.group(1).decode("utf-8", "replace"))
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict) and isinstance(row.get("text"), str) \
                        and row.get("id"):
                    hand.setdefault(same_text(row["text"]), []).append(row["id"])
    except OSError:
        pass
    return reqs, hand


def parse_batch(lines):
    """Turn one batch of transcript lines into finished messages, in order.

    Groups the lines of each final response by requestId and joins its text
    blocks; a response with no text (interrupted, or thinking only so far)
    yields nothing and is left for a later batch to complete.
    """
    groups = {}
    for raw in lines:
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if not isinstance(entry, dict) or entry.get("type") != "assistant":
            continue
        if entry.get("isSidechain") or entry.get("isApiErrorMessage"):
            continue
        message = entry.get("message")
        if not isinstance(message, dict) or message.get("stop_reason") not in FINAL_STOPS:
            continue
        if message.get("model") == "<synthetic>":
            continue
        req = entry.get("requestId") or entry.get("uuid") or ""
        if not req:
            continue
        g = groups.setdefault(req, {"parts": [], "at": "", "session": ""})
        for block in message.get("content") or []:
            if isinstance(block, dict) and block.get("type") == "text":
                g["parts"].append(block.get("text") or "")
        g["at"] = clean_ts(entry.get("timestamp")) or g["at"]
        g["session"] = entry.get("sessionId") or g["session"]
    out = []
    for req, g in groups.items():
        text = "".join(g["parts"]).strip()
        if text:
            out.append((req, g["at"], g["session"], text))
    return out


def append_rows(log_path, rows):
    """Append one batch of messages, whole lines only.

    The Stop hook bounds this sweep and kills it when the bound is hit, so a
    write can stop anywhere. The batch goes down unbuffered in one call, and a
    log that does not end in a newline is mended before anything is added to
    it: appending onto a torn line would join it to the next message and take
    BOTH off the page, where a torn line on its own is skipped by the reader
    and re-recorded by the next sweep.
    """
    data = "".join(json.dumps(row, ensure_ascii=False,
                              separators=(",", ":")) + "\n"
                   for row in rows).encode("utf-8")
    with open(log_path, "a+b", buffering=0) as fh:
        if fh.seek(0, os.SEEK_END) > 0:
            fh.seek(-1, os.SEEK_END)
            if fh.read(1) != b"\n":
                data = b"\n" + data
        while data:
            data = data[fh.write(data):]


def write_cursor(cursor_path, cursor):
    tmp = cursor_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(cursor, fh)
    os.replace(tmp, cursor_path)


def sweep(home, since, paths=None, directory=None):
    """Read what is not yet recorded. `paths` is a named transcript (the hook's
    payload), `directory` the inferred fallback; a directory run also sweeps
    every transcript a payload has ever named."""
    state_dir = os.path.join(home, "state")
    data_dir = os.path.join(home, "data")
    os.makedirs(state_dir, exist_ok=True)
    cursor_path = os.path.join(state_dir, ".captain-message-sweep")
    log_path = os.path.join(data_dir, "captain-messages.jsonl")

    try:
        with open(cursor_path, encoding="utf-8") as fh:
            cursor = json.load(fh)
        if not isinstance(cursor, dict) or not isinstance(cursor.get("files"), dict):
            cursor = None
    except (OSError, json.JSONDecodeError):
        cursor = None
    if cursor is None:
        cursor = {"v": 2, "floor": since or local_midnight_utc(), "files": {}}
    floor = cursor.get("floor") or ""
    # Which by-hand rows have already stood for a captured message: kept here
    # because a run reads the log afresh and cannot otherwise tell a routed row
    # that is spoken for from one that is not.
    used = set(cursor.get("used") or [])
    named = [p for p, f in cursor["files"].items() if isinstance(f, dict) and f.get("named")]

    if paths:
        targets = [os.path.abspath(p) for p in paths]
        directory = os.path.dirname(targets[0])
    else:
        targets = []
        if directory and os.path.isdir(directory):
            targets = sorted(
                (os.path.join(directory, f) for f in os.listdir(directory)
                 if f.endswith(".jsonl")
                 and os.path.isfile(os.path.join(directory, f))),
                key=os.path.getmtime)
        targets += [p for p in named if p not in targets]
    targets = [p for p in targets if os.path.isfile(p)]
    if not targets:
        return {"active": False, "dir": directory, "transcripts": 0, "new": 0,
                "named": len(named)}

    seen, hand = set(), {}
    deduped = False
    new = 0
    for path in targets:
        entry = cursor["files"].get(path)
        entry = dict(entry) if isinstance(entry, dict) else {}
        offset = entry.get("off", 0)
        size = os.path.getsize(path)
        if size < offset:
            offset = 0          # truncated or rewritten; the log still dedupes
        if paths:
            entry["named"] = True
        if size == offset:
            # Nothing new to read, but a payload naming this transcript is
            # itself a fact worth keeping: it is what lets the page vouch for
            # the list, and the run that read the bytes may have got here first.
            if cursor["files"].get(path) != entry:
                cursor["files"][path] = entry
                write_cursor(cursor_path, cursor)
            continue
        # The log's own requestIds are the dedupe record, read once per run
        # that has anything to read: a file starting from its top repeats what
        # the log holds, and a response whose blocks straddle this offset is
        # read again as part of the next batch.
        if not deduped:
            seen, hand = recorded(log_path)
            deduped = True
        with open(path, "rb") as fh:
            fh.seek(offset)
            chunk = fh.read(size - offset)
        end = chunk.rfind(b"\n")
        if end < 0:
            continue            # no complete new line yet
        lines = chunk[:end + 1].splitlines()

        rows = []
        for req, at, session, text in parse_batch(lines):
            if req in seen or (floor and at and at < floor):
                continue
            seen.add(req)
            routed = next((i for i in hand.get(same_text(text), [])
                           if i not in used), None)
            if routed:
                used.add(routed)
                cursor["used"] = sorted(used)
                continue
            rows.append({
                "id": "c" + hashlib.sha1((session + req).encode()).hexdigest()[:16],
                "at": at or utc_now(), "title": derive_title(text), "text": text,
                "task": None, "project": None, "worktree": None,
                "branch": None,
                "source": "transcript", "session": session or None, "req": req,
            })
        if rows:
            os.makedirs(data_dir, exist_ok=True)
            append_rows(log_path, rows)
            new += len(rows)

        # Advance the cursor only after this file's messages are on disk, one
        # file at a time, so a killed sweep loses progress, never messages.
        entry["off"] = offset + end + 1
        cursor["files"][path] = entry
        write_cursor(cursor_path, cursor)

    named = [p for p, f in cursor["files"].items() if isinstance(f, dict) and f.get("named")]
    return {"active": True, "dir": directory, "transcripts": len(targets),
            "new": new, "named": len(named)}


def payload_transcript(stream):
    """The transcript a Claude hook payload names, as a one-item list.

    The payload is the only thing that knows which file this session writes;
    anything else is a guess at it.
    """
    try:
        payload = json.load(stream)
    except (json.JSONDecodeError, ValueError, OSError):
        return None
    path = payload.get("transcript_path") if isinstance(payload, dict) else None
    return [os.path.abspath(path)] if isinstance(path, str) and path else None


def write_capture(state_dir, record):
    path = os.path.join(state_dir, ".captain-message-capture")
    tmp = path + ".tmp"
    try:
        os.makedirs(state_dir, exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(record, fh)
        os.replace(tmp, path)
    except OSError as exc:
        sys.stderr.write(f"fm-captain-message-sweep: cannot write capture record: {exc}\n")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Record unrecorded captain-facing messages from the conversation record.")
    parser.add_argument("--home", default=os.environ.get("FM_HOME"))
    parser.add_argument("--transcripts")
    parser.add_argument("--since")
    parser.add_argument("--from-payload", action="store_true")
    args = parser.parse_args(argv)

    home = os.path.abspath(args.home or os.path.join(os.path.dirname(
        os.path.abspath(__file__)), ".."))
    state_dir = os.path.join(home, "state")
    transcript_dir = os.path.abspath(args.transcripts) if args.transcripts \
        else default_transcript_dir(home)
    paths = None
    if args.from_payload:
        paths = payload_transcript(sys.stdin)
        if not paths:
            return 0        # the payload names no transcript; nothing to pin

    os.makedirs(state_dir, exist_ok=True)
    # bin/command-center.py runs this in-process, so the lock file must be
    # closed on every path or each run leaks a descriptor into the server.
    with open(os.path.join(state_dir, ".captain-message-sweep.lock"), "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return 0            # another sweep is live; it captures the same record
        try:
            result = sweep(home, args.since, paths=paths,
                           directory=None if paths else transcript_dir)
        except Exception as exc:  # a broken sweep must say so, never look quiet
            write_capture(state_dir, {"at": utc_now(), "ok": False, "error": str(exc),
                                      "active": True, "dir": transcript_dir,
                                      "transcripts": 0, "new": 0, "named": 0})
            sys.stderr.write(f"fm-captain-message-sweep: {exc}\n")
            return 1
        write_capture(state_dir, dict(result, at=utc_now(), ok=True, error=None))
    return 0


if __name__ == "__main__":
    sys.exit(main())
