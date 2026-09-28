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
# A MESSAGE FIRSTMATE ALSO RECORDED BY HAND. Firstmate records some messages
# itself with bin/fm-captain-message.sh: a question tied to a decision
# (--question, the only row that knows where a reply to it goes), an answer to
# one of his notes (--answers, the only row that knows which note it threads
# under), and any message it names the work of with --task. That row carries
# its project, worktree and branch, and AGENTS.md section 9 has it record
# exactly that turn's final message, so the capture must not add a second,
# unlabelled copy beside it. In practice the two are often reworded,
# re-punctuated, or re-formatted, so words alone cannot say which row a reply
# belongs to. The turn itself says it: the recorder prints the new row's id,
# and that output sits in the transcript as the result of the tool call that
# ran it. So the final message is not added beside a by-hand row - the row
# stands, untouched, as the one record of it - when either
#   (a) its own turn ran the recorder and got back exactly one row id, read
#       from the result of a tool call that named the recorder, and stamped
#       inside that call's own run (the id carries its write time), so an id
#       the turn merely printed from the log is never taken for one it wrote;
#       it is the first final message of that turn; and it says the same as
#       the row (same_message): exactly the same links, numbers and
#       identifiers, and exactly the same negations, modals and auxiliaries
#       (CLAIM, and every n't contraction), both ways, and not one word the
#       row lacks beyond a fixed list of filler words (FILLER), or
#   (b) no such id ties it to a row, and a by-hand row written inside that
#       turn - between its opening prompt and the reply - has exactly the
#       reply's text once markdown, backticks, list markers, dash and quote
#       variants, whitespace and case are dropped (normalized).
# Each row stands for at most one reply. Anything else - a reply that adds a
# word the row does not have, a row written before the turn began, the same
# words in another turn - is captured as usual, and a row the turn's recorder
# wrote is then evidence of its work (below). The row may carry more ordinary
# words than the reply, never fewer, and never a different negation or tense,
# so a fold loses nothing the captain would read: this can leave a duplicate
# but never drops something only the reply said. This never decides a message
# is a question.
#
# WHICH WORK A MESSAGE IS ABOUT (work_for). A message belongs to the work it
# is about, and only evidence that is there counts. It is read in this order,
# and the first tier with any evidence decides:
#   1. the work firstmate named when it recorded the message by hand: the
#      task of a by-hand row the turn's recorder wrote, else that row's
#      project (the task, because a row's own labels can predate how its
#      task resolves today);
#   2. the work firstmate steered in that turn: a tool call naming a task's own
#      record (state/<id>.meta or state/<id>.status), a steering script run on
#      a task (STEER: the task id each takes first), the recorder run with
#      --task, and the task of a by-hand row the turn wrote;
#   3. an identifier in the message: a repo of a project in the home's
#      registries as owner/name (a pull request URL names it so), a
#      ~/wt/<project>/<name> worktree path, or a task id with a
#      state/<id>.meta;
#   4. the message's own subject: a registered name the message calls a
#      project ("project koin").
# A task resolves to its project through task_record, else through a by-hand
# row that named it, else through its data/backlog.md item's repo; a steered
# task nothing resolves leaves the message unknown, since that work could be
# any project. A project's name said in passing - "the same convention as
# JewelTrek, INTERACT and Casa Mira" - is no evidence at all. Two projects in
# the deciding tier leave the message unknown, never filed under both: an
# honest blank beats a wrong label. Registered names are each project in
# data/projects.md, its repo, and each second mate in data/secondmates.md
# owning one project (registry). With the project known, the task is recorded
# when exactly one task of that project is evidenced; the worktree is that
# task's, else one a by-hand row or the message names; the branch is that
# task's recorded one, else - only in the Stop hook's run, which captures the
# turn that just ended - its worktree's live branch (a catch-up run may be
# reading an old turn, and a worktree's branch now is not its branch then),
# else one a by-hand row names, else the one branch the message names that the
# project's clone under projects/ actually has. A second mate's record names
# its own home, so its work is read from its projects= instead (task_record),
# which also names that project's development branch.
# bin/fm-captain-message-backfill.py applies the same rules to older rows.
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
#   .captain-message-sweep       per-transcript byte cursor and unfinished
#                                turn, which transcripts a payload has named,
#                                and the stored floor
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
import subprocess
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


def recorded(log_path):
    """The log itself is the dedupe record: the requestIds already captured,
    and the rows recorded by hand, as {id: row}."""
    reqs, by_hand = set(), {}
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
                if isinstance(row, dict) and isinstance(row.get("id"), str) \
                        and isinstance(row.get("text"), str) and not row.get("req") \
                        and row.get("source") != "transcript":
                    by_hand[row["id"]] = row
    except OSError:
        pass
    return reqs, by_hand


URL = re.compile(r"https?://[^\s<>()\[\]*`\"']+")
LIST_MARKER = re.compile(r"(?m)^\s*(?:\d+[.)]|[-*>])\s+")
TOKEN = re.compile(r"[A-Za-z0-9][\w./:#@-]*[\w/]|\d")
SPECIFIC = re.compile(r"\d|[A-Za-z0-9][./_:#@][A-Za-z0-9]")
# The only words a reply may say that its row does not.
FILLER = frozenset("""
a an the this that these those it its i me my we us our you your he him his she
her they them their be and or but so if then as of to in on at by for with from
into about let's captain
""".split())
# Words that negate or change a claim's tense or commitment, and so must be the
# same both ways; every n't contraction is one of them too.
CLAIM = frozenset("""
not no never none nor neither cannot did does do done will would can could
should must may might shall has have had was were is are am been i'm i've i'll
i'd you're you've you'll we're we've we'll it's that's there's
""".split())


def specifics(text):
    """The links, numbers and identifiers a message names: where two messages
    of one turn genuinely differ, and what folding must never lose."""
    found = {u.rstrip(".,;:!?") for u in URL.findall(text)}
    text = LIST_MARKER.sub(" ", URL.sub(" ", text))
    return found | {w for w in TOKEN.findall(text) if SPECIFIC.search(w)}


def plain_words(text):
    text = LIST_MARKER.sub(" ", URL.sub(" ", text)).lower().replace("\u2019", "'")
    return set(re.findall(r"[a-z0-9]+(?:'[a-z0-9]+)*", text))


def claims(words):
    return {w for w in words if w in CLAIM or w.endswith("n't")}


def normalized(text):
    return re.sub(r"[\s*_`~\"'\u2018\u2019\u201c\u201d\u2010-\u2015-]", "",
                  LIST_MARKER.sub(" ", text)).lower()


def same_message(reply, row):
    """Whether a captured reply says the same as a by-hand row.

    Formatting never counts: markdown, backticks, dashes, quotes, list markers
    and line breaks are dropped before words are compared, and a contraction
    is one word, so "can't" never passes for "can". The two must name
    exactly the same links, numbers and identifiers, and exactly the same
    negations, modals and auxiliaries (CLAIM, and every n't form), both ways;
    and every word of the reply must also be in the row unless it is in
    FILLER. The row may carry other ordinary words the reply lacks; a reply
    that adds any other word says something new and is captured.
    """
    words, other = plain_words(reply), plain_words(row)
    return specifics(reply) == specifics(row) and claims(words) == claims(other) \
        and words - other <= FILLER


def routed_row(req, text, at, start, hand, by_hand, used):
    """The by-hand row that already carries this reply, if any; `used` maps
    each row that already stands for a reply to that reply's requestId."""
    free = lambda i: used.get(i, req) == req
    if len(hand) == 1 and hand[0] in by_hand:
        row = hand[0]
        return row if free(row) and same_message(text, by_hand[row]["text"]) else None
    return next((i for i, row in by_hand.items()
                 if free(i) and start and start <= (row.get("at") or "") <= at
                 and normalized(row["text"]) == normalized(text)), None)


TASK_RECORD = re.compile(r"\bstate/([A-Za-z0-9][A-Za-z0-9_-]*)\.(?:meta|status)\b")
# The scripts firstmate steers one task with, each taking its id first, and
# the recorder naming the task a message is about.
STEER = re.compile(r"\bfm-(?:send|pr-check|pr-merge|teardown|crew-state|peek|control"
                   r"|promote|spawn|brief)\.sh\s+['\"]?([A-Za-z0-9][A-Za-z0-9_-]*)")
RECORDER_TASK = re.compile(r"\bfm-captain-message\.sh\b[^\n;|&]*?--task[= ]['\"]?"
                           r"([A-Za-z0-9][A-Za-z0-9_-]*)")
RECORDER = "fm-captain-message.sh"
# The id bin/fm-captain-message.sh prints for the row it wrote.
HAND_ID = re.compile(r"\bm\d{8}T\d{6}Z-\d+\b")


def new_turn(saved=None):
    """What one turn has done so far, kept with the cursor between batches:
    when its prompt came, the task ids its tool calls named, its pending
    recorder calls, the row ids the recorder printed, and the first final
    reply with the rows it took."""
    saved = saved if isinstance(saved, dict) else {}
    return {"start": saved.get("start") or "",
            "tasks": set(saved.get("tasks") or []),
            "calls": dict(saved.get("calls") or {}),
            "hand": list(saved.get("hand") or []),
            "reply": saved.get("reply")}


def saved_turn(turn):
    return {"start": turn["start"], "tasks": sorted(turn["tasks"]), "calls": turn["calls"],
            "hand": turn["hand"], "reply": turn["reply"]}


def written_during(content, started, ended):
    """The recorder row ids in a call's output that were written while it ran."""
    text = content if isinstance(content, str) else "\n".join(
        b["text"] for b in (content if isinstance(content, list) else [])
        if isinstance(b, dict) and isinstance(b.get("text"), str))
    if not started or not ended:
        return []
    return [i for i in HAND_ID.findall(text) if started <= "%s-%s-%sT%s:%s:%sZ" % (
        i[1:5], i[5:7], i[7:9], i[10:12], i[12:14], i[14:16]) <= ended]


def task_refs(value):
    if isinstance(value, str):
        return set(TASK_RECORD.findall(value) + STEER.findall(value)
                   + RECORDER_TASK.findall(value))
    if isinstance(value, dict):
        value = list(value.values())
    if isinstance(value, list):
        return set().union(*(task_refs(v) for v in value))
    return set()


def is_prompt(entry):
    """A user entry that starts a turn, as opposed to a tool result."""
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return True
    return isinstance(content, list) and not any(
        isinstance(b, dict) and b.get("type") == "tool_result" for b in content)


def task_record(state_dir, task):
    """The project and worktree a task's own state/<id>.meta names.

    A second mate's project= and worktree= are its own firstmate home, which is
    the machinery it runs in, not its work: its projects= field names the work
    (the same reading bin/command-center-scan.sh makes). One project is named
    with its development branch from bin/fm-project-base.sh; several are named
    by the mate's own domain, the task id, rather than one picked at random.
    Its worktree stays unknown, because a mate works in many. The mate's home,
    owned projects, and the project and worktree the old reading recorded ride
    along for the backfill's relabelling of rows written before this reading."""
    try:
        with open(os.path.join(state_dir, task + ".meta"), encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except (OSError, UnicodeDecodeError):
        return None
    values = {}
    for line in lines:
        key, sep, value = line.partition("=")
        if sep and key in ("project", "worktree", "kind", "projects", "home") \
                and key not in values:
            values[key] = value.strip() or None
    if values.pop("kind", None) == "secondmate":
        owned = (values.get("projects") or "").replace(",", " ").split()
        home = values.get("home") or values.get("project") or values.get("worktree")
        values = {"project": owned[0] if len(owned) == 1 else task,
                  "worktree": None, "branch": None, "home": home, "projects": owned,
                  "meta_project": os.path.basename(os.path.normpath(values["project"]))
                  if values.get("project") else None,
                  "meta_worktree": values.get("worktree")}
        if len(owned) == 1:
            values["branch"] = project_branch(
                os.path.dirname(os.path.normpath(state_dir)), home, owned[0])
        return values
    values.pop("projects", None)
    values.pop("home", None)
    if values.get("project"):
        values["project"] = os.path.basename(os.path.normpath(values["project"]))
    return values


def project_branch(fm_home, mate_home, project):
    """The project's development branch, read from the mate's clone of it, else
    this home's, with this home's registry as the fallback; None when the
    project declares none."""
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-project-base.sh")
    for home in (mate_home, fm_home):
        clone = os.path.join(home, "projects", project) if home else ""
        if not os.path.isdir(clone):
            continue
        result = subprocess.run(
            [script, clone, project], env=dict(os.environ, FM_HOME=fm_home),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False)
        return result.stdout.strip() or None
    result = subprocess.run(
        [os.path.join(os.path.dirname(script), "fm-project-mode.sh"), "--base", project],
        env=dict(os.environ, FM_HOME=fm_home), stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False)
    return result.stdout.strip() or None


def live_branch(worktree):
    if not worktree or not os.path.isdir(worktree):
        return None
    result = subprocess.run(
        ["git", "-C", worktree, "symbolic-ref", "--quiet", "--short", "HEAD"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, check=False)
    return result.stdout.strip() or None if result.returncode == 0 else None


WT_PATH = re.compile(r"(?:~|/home/[^/\s]+)/wt/([\w.-]+)/([\w.-]*\w)")
BRANCH_WORD = re.compile(r"\bbranch\s*[:*`'\"]*\s*([\w./-]*\w)", re.I)
BACKTICKED = re.compile(r"`([^`\s]+)`")
PROJECT_WORD = re.compile(r"\bproject[\s*`'\"]*$", re.I)


def registry(home):
    """name -> project for every name this home's registries say is real: each
    project in data/projects.md, its repo as owner/name and as name, and each
    second mate in data/secondmates.md that owns exactly one project. A name
    that would stand for two projects stands for neither."""
    pairs = []
    try:
        with open(os.path.join(home, "data", "projects.md"), encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"- ([A-Za-z0-9._-]+) \[", line)
                if not m:
                    continue
                pairs.append((m.group(1), m.group(1)))
                repo = re.search(r"\brepo\s+([\w.-]+/[\w.-]*\w)", line, re.I)
                if repo:
                    pairs += [(repo.group(1), m.group(1)),
                              (repo.group(1).split("/")[1], m.group(1))]
    except (OSError, UnicodeDecodeError):
        pass
    try:
        with open(os.path.join(home, "data", "secondmates.md"), encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"- ([A-Za-z0-9._-]+) - ", line)
                owned = re.search(r"; projects: ([^;)]*)", line)
                owned = owned.group(1).replace(",", " ").split() if owned else []
                if m and len(owned) == 1:
                    pairs.append((m.group(1), owned[0]))
    except (OSError, UnicodeDecodeError):
        pass
    names = {}
    for name, project in pairs:
        names.setdefault(name.lower(), set()).add(project)
    return {name: next(iter(p)) for name, p in names.items() if len(p) == 1}


def whole_words(words, flags=0):
    words = sorted(words, key=len, reverse=True)
    return re.compile(r"(?<![\w-])(" + "|".join(map(re.escape, words)) + r")(?![\w-])",
                      flags) if words else None


def backlog_repos(home):
    """task id -> the repo its data/backlog.md item names: the one record of a
    task's work that outlives its state/<id>.meta."""
    try:
        with open(os.path.join(home, "data", "backlog.md"), encoding="utf-8") as fh:
            items = (re.match(r"- \[.\] ([A-Za-z0-9][A-Za-z0-9_-]*) - .*\(repo: ([^)\s]+)\)", line)
                     for line in fh)
            return {m.group(1): m.group(2) for m in items if m}
    except (OSError, UnicodeDecodeError):
        return {}


def evidence_context(home):
    """What work_for reads once per run: the registry, the task ids with a
    record in this home, and the backlog's repo for each task."""
    state_dir = os.path.join(home, "state")
    reg = registry(home)
    try:
        ids = [f[:-5] for f in os.listdir(state_dir) if f.endswith(".meta")]
    except OSError:
        ids = []
    return {"home": home, "state": state_dir, "reg": reg, "names": whole_words(reg, re.I),
            "ids": whole_words(i for i in ids if i.lower() not in reg),
            "backlog": backlog_repos(home), "branches": {}, "records": {}}


def clone_branches(ctx, project):
    """The branches the project's clone in this home has, local or remote."""
    if project not in ctx["branches"]:
        clone = os.path.join(ctx["home"], "projects", project)
        result = subprocess.run(
            ["git", "-C", clone, "for-each-ref", "--format=%(refname:short)",
             "refs/heads", "refs/remotes"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, check=False) if os.path.isdir(clone) else None
        ctx["branches"][project] = {b[len("origin/"):] if b.startswith("origin/") else b
                                    for b in (result.stdout.split() if result else [])}
    return ctx["branches"][project]


def one(values):
    values = {v for v in values if v}
    return next(iter(values)) if len(values) == 1 else None


def work_for(ctx, text, tasks, hand_rows, live=False):
    """The task, project, worktree and branch a message is about, by the tiers
    the header's WHICH WORK A MESSAGE IS ABOUT lists; {} when unknown."""
    records = {}

    def owner(task):
        if task not in ctx["records"]:
            ctx["records"][task] = task_record(ctx["state"], task) or {}
        records[task] = ctx["records"][task]
        return records[task].get("project") or one(
            r.get("project") for r in hand_rows if r.get("task") == task) \
            or ctx["backlog"].get(task)

    steered = {t: owner(t) for t in set(tasks) | {r["task"] for r in hand_rows if r.get("task")}}
    if not all(steered.values()):
        return {}           # work nothing resolves could be any project
    ided = {t: owner(t) for t in ({m.group(1) for m in ctx["ids"].finditer(text)}
                                  if ctx["ids"] else set()) - set(steered)}
    paths = {}
    for m in WT_PATH.finditer(text):
        if m.group(1).lower() in ctx["reg"]:
            paths[os.path.expanduser("~/wt/%s/%s" % m.groups())] = ctx["reg"][m.group(1).lower()]
    repos, subjects = set(), set()
    for m in ctx["names"].finditer(text) if ctx["names"] else ():
        if "/" in m.group(1):
            repos.add(ctx["reg"][m.group(1).lower()])
        elif PROJECT_WORD.search(text, 0, m.start()):
            subjects.add(ctx["reg"][m.group(1).lower()])
    # A name in passing ("the same convention as JewelTrek") is no tier at
    # all; the first tier with any evidence decides, and two projects in it
    # leave the message unknown rather than filed under both.
    tiers = ({steered[r["task"]] if r.get("task") else r.get("project")
              for r in hand_rows} - {None},
             set(steered.values()),
             repos | set(paths.values()) | {p for p in ided.values() if p},
             subjects)
    projects = next((tier for tier in tiers if tier), set())
    if len(projects) != 1:
        return {}
    project = next(iter(projects))
    hand_rows = [r for r in hand_rows if r.get("project") == project]
    task = one(t for t, p in {**steered, **ided}.items() if p == project)
    record = records.get(task) or {}
    worktree = record.get("worktree") or one(r.get("worktree") for r in hand_rows) \
        or one(w for w, p in paths.items() if p == project)
    named = {m.group(1) for m in BRANCH_WORD.finditer(text)} \
        | {m.group(1) for m in BACKTICKED.finditer(text)}
    branch = record.get("branch") or (live_branch(record.get("worktree")) if live else None) \
        or one(r.get("branch") for r in hand_rows) \
        or (one(named & clone_branches(ctx, project)) if named else None)
    return {"task": task, "project": project, "worktree": worktree, "branch": branch}


def parse_batch(lines, turn=None):
    """Turn one batch of transcript lines into finished messages, in order.

    Groups the lines of each final response by requestId and joins its text
    blocks; a response with no text (interrupted, or thinking only so far)
    yields nothing and is left for a later batch to complete. `turn` is the
    current turn's state (new_turn); it carries across batches, and each message
    is returned with the task ids as they stood, when its turn's prompt came,
    and, for the turn's first final reply only, the row ids its recorder calls
    printed.
    """
    if turn is None:
        turn = new_turn()
    groups = {}
    for raw in lines:
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if not isinstance(entry, dict) or entry.get("isSidechain"):
            continue
        if entry.get("type") == "user" and is_prompt(entry):
            turn.update(new_turn({"start": clean_ts(entry.get("timestamp"))}))
            continue
        if entry.get("type") == "user":
            for block in (entry.get("message") or {}).get("content") or []:
                if isinstance(block, dict) and block.get("tool_use_id") in turn["calls"]:
                    turn["hand"] += written_during(
                        block.get("content"), turn["calls"].pop(block["tool_use_id"]),
                        clean_ts(entry.get("timestamp")))
            continue
        if entry.get("type") != "assistant" or entry.get("isApiErrorMessage"):
            continue
        message = entry.get("message")
        if not isinstance(message, dict):
            continue
        for block in message.get("content") or []:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                turn["tasks"].update(task_refs(block.get("input")))
                if RECORDER in json.dumps(block.get("input")) and block.get("id"):
                    turn["calls"][block["id"]] = clean_ts(entry.get("timestamp"))
        if message.get("stop_reason") not in FINAL_STOPS:
            continue
        if message.get("model") == "<synthetic>":
            continue
        req = entry.get("requestId") or entry.get("uuid") or ""
        if not req:
            continue
        if req not in groups:
            # The turn's first final reply takes the recorder's rows; a reply
            # read again in a later batch takes the same ones, any other none.
            if turn["reply"] is None:
                turn["reply"] = [req, list(turn["hand"])]
            hand = turn["reply"][1] if turn["reply"][0] == req else []
        g = groups.setdefault(req, {"parts": [], "at": "", "session": "",
                                    "tasks": set(turn["tasks"]), "hand": hand,
                                    "start": turn["start"]})
        for block in message.get("content") or []:
            if isinstance(block, dict) and block.get("type") == "text":
                g["parts"].append(block.get("text") or "")
        g["at"] = clean_ts(entry.get("timestamp")) or g["at"]
        g["session"] = entry.get("sessionId") or g["session"]
    out = []
    for req, g in groups.items():
        text = "".join(g["parts"]).strip()
        if text:
            out.append((req, g["at"], g["session"], text, g["tasks"], g["hand"],
                        g["start"]))
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
    # Which by-hand rows have already stood for a captured message.
    used = cursor.get("used") if isinstance(cursor.get("used"), dict) else {}
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

    seen, by_hand = set(), {}
    ctx = None
    deduped = False
    new = 0
    for path in targets:
        entry = cursor["files"].get(path)
        entry = dict(entry) if isinstance(entry, dict) else {}
        offset = entry.get("off", 0)
        size = os.path.getsize(path)
        turn = new_turn(entry.get("turn"))
        if size < offset:
            offset = 0          # truncated or rewritten; the log still dedupes
            turn = new_turn()
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
            seen, by_hand = recorded(log_path)
            deduped = True
        with open(path, "rb") as fh:
            fh.seek(offset)
            chunk = fh.read(size - offset)
        end = chunk.rfind(b"\n")
        if end < 0:
            continue            # no complete new line yet
        lines = chunk[:end + 1].splitlines()

        rows = []
        for req, at, session, text, tasks, hand, start in parse_batch(lines, turn):
            if req in seen or (floor and at and at < floor):
                continue
            seen.add(req)
            routed = routed_row(req, text, at, start, hand, by_hand, used)
            if routed:
                used[routed] = req
                cursor["used"] = used
                continue        # the routed row already carries this message
            ctx = ctx or evidence_context(home)
            work = work_for(ctx, text, tasks, [by_hand[i] for i in hand if i in by_hand],
                            live=bool(paths))
            rows.append({
                "id": "c" + hashlib.sha1((session + req).encode()).hexdigest()[:16],
                "at": at or utc_now(), "title": derive_title(text), "text": text,
                "task": work.get("task"), "project": work.get("project"),
                "worktree": work.get("worktree"), "branch": work.get("branch"),
                "source": "transcript", "session": session or None, "req": req,
            })
        if rows:
            os.makedirs(data_dir, exist_ok=True)
            append_rows(log_path, rows)
            new += len(rows)

        # Advance the cursor only after this file's messages are on disk, one
        # file at a time, so a killed sweep loses progress, never messages.
        entry["off"] = offset + end + 1
        entry["turn"] = saved_turn(turn)
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
