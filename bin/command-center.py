#!/usr/bin/env python3
# command-center.py - the captain's permanent command center.
#
# One page at a fixed address showing everything waiting on the captain across
# every local firstmate home, with his answer going straight back through the
# scripts that already own delivery. bin/command-center-scan.sh is the reading
# half; docs/command-center.md is the operator guide.
#
# Usage:
#   command-center.py [--port 8765] [--home <FM_HOME>]
#   command-center.py --install-unit [--port 8765]   write the systemd user unit
#
# STDLIB ONLY, BY DESIGN. No dependency to install, no lockfile to refresh, no
# build step, nothing that rots between uses. The whole server is http.server,
# json and subprocess.
#
# POLLING, NOT A HELD CONNECTION. The page asks for /api/items every few seconds
# and gets 304 when nothing moved. Server-sent events would hold one connection
# per open tab, and a browser allows only six per origin - the same limit that
# already stalls this fleet's review pages once six are open. A held stream also
# pins a ThreadingHTTPServer thread that is only reclaimed on the next write, so
# a forgotten tab leaks. The change check is a stat sweep costing ~30ms, so the
# expensive scan runs once per actual change however many tabs are open.
#
# IT STORES TWO THINGS, AND ONLY BECAUSE NOTHING ELSE DOES.
#
# data/captain-messages.jsonl is what firstmate SAID to the captain, appended by
# bin/fm-captain-message.sh as firstmate says it. The terminal was the only
# other copy and a terminal scrolls, so the page's default list is that log: it
# is the whole point of this surface, and firstmate's own work records are not
# a substitute for it.
#
# data/command-center/said.jsonl is what HE said back. Firstmate already keeps
# the questions and the answers that close a decision, so copying those here
# would create a second truth that can drift. What firstmate does NOT keep is
# the captain's own words in three cases: a steer to a worker is deleted with
# the task's steering inbox at teardown (bin/fm-teardown.sh), an unsent draft
# never existed, and terminal text is only scrollback. So this appends every
# word he sends to that log, and stores nothing else.
#
# Drafts and read state stay in the browser, because they are his and this runs
# on his machine.
#
# TRUST BOUNDARY. It binds loopback only and runs firstmate's own scripts with
# the captain's authority, which is the point of it; it is not an authenticated
# multi-user surface and must never be bound to a routable address. Every
# request field that reaches a command is validated against the scanned record
# set first, and text reaches scripts as an argument or a file, never a shell
# string.
import argparse
import collections
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIN = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(BIN, "command-center.html")
# The page's decision rules, in their own file so tests can execute them.
RULES = os.path.join(BIN, "command-center-state.js")
SCAN = os.path.join(BIN, "command-center-scan.sh")

# tasks-axi's own limit on a recorded decision (bin/fm-captain-hold.sh).
MAX_TEXT = 8192
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SCAN_TIMEOUT = 240
SEND_TIMEOUT = 120
SCAN_WAIT = 30


def dump(obj):
    """Compact JSON for the wire: no filler whitespace on a 3-second poll."""
    return json.dumps(obj, separators=(",", ":")).encode()


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Records:
    """The scanned view, refreshed only when a record actually moved.

    `fingerprint` is a cheap stat sweep; `payload` is the full scan. Callers get
    a (etag, json-bytes) pair, so an unchanged poll answers 304 with no body.
    """

    def __init__(self, home):
        self.home = home
        self.etag = None
        self.body = b"{}"
        self.error = None
        self.checked = float("-inf")
        # ThreadingHTTPServer gives every open tab its own thread, so the etag
        # and the body it names must become visible together or a reader can
        # store a new etag against an old list and 304 on it forever.
        self.lock = threading.Lock()
        # And one scan per change however many tabs poll, as the header promises:
        # a thread that cannot take this serves the snapshot instead of forking
        # its own jq-per-item scan beside the one already running.
        self.scan = threading.Lock()

    def snapshot(self):
        with self.lock:
            return self.etag, self.body

    def invalidate(self):
        # Force the next scan without unpublishing: a null etag means "never
        # scanned" and nothing else, or a poll right after a send would be told
        # records it has been reading for hours have never been read.
        self.checked = float("-inf")

    def _run(self, args, timeout):
        env = dict(os.environ, FM_HOME=self.home)
        return subprocess.run(
            args, capture_output=True, text=True, timeout=timeout, env=env,
            stdin=subprocess.DEVNULL, check=False
        )

    def refresh(self, min_interval=1.0):
        if self.etag is not None and time.monotonic() - self.checked < min_interval:
            return
        if self.scan.acquire(blocking=False):
            try:
                self._refresh_locked(min_interval)
            finally:
                self.scan.release()
            return
        # Someone is already scanning these very records: wait for THEIR result
        # rather than starting a second scan beside it or repeating it after.
        if self.scan.acquire(timeout=SCAN_WAIT):
            self.scan.release()

    def _refresh_locked(self, min_interval):
        now = time.monotonic()
        if now - self.checked < min_interval:
            return
        self.checked = now
        try:
            fp = self._run([SCAN, "--fingerprint"], 30)
        except subprocess.SubprocessError as exc:
            self.error = f"change check failed: {exc}"
            return
        if fp.returncode != 0:
            self.error = f"change check failed: {fp.stderr.strip()[:400]}"
            return
        etag = hashlib.sha256(fp.stdout.encode()).hexdigest()[:32]
        if etag == self.etag:
            self.error = None
            return
        try:
            out = self._run([SCAN], SCAN_TIMEOUT)
        except subprocess.SubprocessError as exc:
            self.error = f"scan failed: {exc}"
            return
        if out.returncode != 0:
            self.error = f"scan failed: {out.stderr.strip()[:400]}"
            return
        try:
            data = json.loads(out.stdout)
        except json.JSONDecodeError as exc:
            self.error = f"scan produced unreadable output: {exc}"
            return
        self.error = None
        with self.lock:
            self.etag = etag
            self.body = dump(data)

    def view(self):
        return json.loads(self.body)

    def home_path(self, home_id):
        for home in self.view().get("homes", []):
            if home["id"] == home_id:
                return home["path"]
        return None

    def waiting_question(self, task_id, key):
        """The decision a recorded QUESTION asked about, or None when it is settled.

        Only the decision the message itself named can answer it. A task
        collects several messages over its life - a question, then a PR, then a
        result - so answering whatever decision the task happens to be stopped
        on now would write his reply to a question he was not looking at. A key
        names a stopped worker's own decision; no key means the captain hold
        this home filed.

        Only THIS home's items can answer it. The message log belongs to the
        home this server was started on, and two homes on one machine can hold
        the same task id (bin/fm-backend-hometag-lib.sh), so matching across
        them would deliver his words to an unrelated worker.
        """
        if not task_id or not ID_RE.match(task_id):
            return None
        view = self.view()
        mine = {h["id"] for h in view.get("homes", [])
                if os.path.realpath(h["path"]) == os.path.realpath(self.home)}
        for it in view.get("items", []):
            if it["id"] != task_id or it["home"] not in mine:
                continue
            if key:
                if it["source"] == "status" and (it.get("key") or "") == key:
                    return it
            elif it["source"] == "hold":
                return it
        return None

    def item(self, home_id, task_id, source, key):
        # A task can be waiting twice at once - captain-held AND stopped on its
        # own status record - and the two are answered by different commands, so
        # the record it came from is part of its identity, not a detail of it.
        for it in self.view().get("items", []):
            if (it["home"], it["id"], it["source"], it.get("key") or "") \
                    == (home_id, task_id, source, key):
                return it
        return None


def item_key(item):
    """The identity the page uses too (itemKey in bin/command-center.html)."""
    return "/".join([item["home"], item["source"], item["id"], item.get("key") or ""])


def message_log(home):
    """What firstmate said to him. bin/fm-captain-message.sh is its only writer."""
    return os.path.join(home, "data", "captain-messages.jsonl")


def said_log(home):
    """The one log, in the home this server was started on.

    Every entry lands here whichever home the answer went to - the record
    carries that - because this is the only log /api/said reads back.
    """
    return os.path.join(home, "data", "command-center", "said.jsonl")


def record_said(home, entry):
    """Append one line to the convenience view this server keeps.

    Append-only and best effort: firstmate's own records already hold a
    delivered answer and a queued note, so a failure here must never make one
    look undelivered. It goes to this server's log, not over the send result.
    A failed send is recorded too: what he typed is what this file is for.
    """
    path = said_log(home)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError as exc:
        sys.stderr.write(f"command-center: could not write {path}: {exc}\n")


def read_log(path, limit=500):
    """Returns (rows, error, dropped), newest first.

    A log that is not there yet is honestly empty; one that cannot be READ is a
    different state, and reporting it as empty would tell the captain he has
    never typed anything - or that firstmate never said anything to him.

    `dropped` is every line the list does not carry, whether the limit cut it
    or it could not be parsed at all, because a list shortened without saying
    so is the same silent loss this page exists to end.

    Only `limit` rows are ever held at once: the log is append-only and never
    pruned, so materialising all of it to keep the tail would make the cap a
    comment rather than a bound.
    """
    rows = collections.deque(maxlen=limit)
    lines = 0
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                lines += 1
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        return [], None, 0
    except OSError as exc:
        return [], f"the record could not be read: {exc}", 0
    return list(rows)[::-1], None, max(0, lines - len(rows))


# He reads his own words and firstmate's, not a page of either: the whole log
# is served, and the cap is only there so an unbounded file cannot exhaust this
# process. The reply thread under a message is read out of the said log, so a
# shortened said log would make an answered message read as unanswered.
LOG_LIMIT = 20000


def read_said(home, limit=LOG_LIMIT):
    return read_log(said_log(home), limit)


def read_messages(home, limit=LOG_LIMIT):
    return read_log(message_log(home), limit)


def log_etag(path):
    """A change check over the log's own (mtime, size), not its contents.

    The page polls this on the item cadence, so an unchanged log must cost a
    stat rather than a full parse and re-serialize of every message.
    """
    try:
        st = os.stat(path)
    except OSError:
        return None
    return hashlib.sha256(
        f"{st.st_mtime_ns}/{st.st_size}".encode()).hexdigest()[:32]


def find_message(home, msg_id):
    """The message a reply names, read back from the log rather than trusted.

    The whole log is read because the reply is rare and the log is one line per
    message; a reply to a message this home never recorded is refused.
    """
    rows, error, _ = read_messages(home)
    if error:
        return None, error
    for row in rows:
        if row.get("id") == msg_id:
            return row, None
    return None, None


def send_answer(home_path, item, text):
    """Deliver one answer through the script that owns its delivery.

    A captain hold and a stopped worker are different records answered by
    different commands, and the item's own `source` decides which - the server
    never guesses. Both record the captain's words durably as part of the same
    act that closes the decision.

    Returns (outcome, route, detail, mode), the outcome read from the exit code
    and nothing else.
    The output carries the captain's own answer back (fm-send.sh echoes its argv
    on the remote leg), so reading prose here would let his words decide whether
    his send was delivered. A killed child is the same question by another name,
    so each route answers it here too rather than anywhere else.
    """
    env = dict(os.environ, FM_HOME=home_path)
    if item["source"] == "hold":
        # bin/fm-captain-hold.sh mints a question of its own with `--kind
        # captain`; a WORK item it holds keeps its own kind. Answering the
        # question closes it, but answering the gate must LIFT the hold so the
        # work resumes - closing it would mark unstarted work complete.
        kind = item.get("kind") or ""
        if not kind:
            return ("failed", f"fm-captain-hold.sh answer {item['id']}",
                    "this row records no kind, so the command center cannot tell a "
                    "question from work held pending your answer; nothing was sent. "
                    "Answer it with fm-captain-hold.sh, which can see the task itself.",
                    "none")
        mode = "close" if kind == "captain" else "release"
        args = [os.path.join(BIN, "fm-captain-hold.sh"), "answer", item["id"]]
        if mode == "release":
            args.append("--release")
        route = " ".join(["fm-captain-hold.sh", "answer", item["id"]]
                         + (["--release"] if mode == "release" else []))
        fd, tmp = tempfile.mkstemp(prefix="cc-decision-", text=True)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(text)
            proc = subprocess.run(
                args + ["--decision-file", tmp],
                capture_output=True, text=True, timeout=SEND_TIMEOUT,
                env=env, stdin=subprocess.DEVNULL, check=False,
            )
        except subprocess.SubprocessError as exc:
            return "failed", route, str(exc), mode
        finally:
            os.unlink(tmp)
        # A hold is a LOCAL record write with no delivery plane, and
        # bin/fm-captain-hold.sh documents an exact retry as idempotent, so a
        # refusal or a killed child is a plain failure he may simply send again.
        outcome = "sent" if proc.returncode == 0 else "failed"
    else:
        mode = "close"
        route = f"fm-send.sh {item['id']}"
        args = [os.path.join(BIN, "fm-send.sh"), item["id"]]
        if item.get("key"):
            args += ["--resolve-key", item["key"]]
        args.append(text)
        try:
            proc = subprocess.run(
                args, capture_output=True, text=True, timeout=SEND_TIMEOUT,
                env=env, stdin=subprocess.DEVNULL, check=False,
            )
        except subprocess.SubprocessError as exc:
            # Killed mid-flight: the steer may already sit on the worker's
            # inbox, and saying "not sent" is what invites a second delivery.
            return "unknown", route, str(exc), mode
        # fm-send.sh reports confirmed (0), typed-plane unconfirmed (3) and
        # inbox-plane delivered-but-not-closed (4); its remaining nonzero exits
        # conflate a refusal with a delivery it could not read back, so delivery
        # is genuinely unknown and unknown is what a surface that never guesses
        # has to say. Exit 4 is a delivered steer whose decision-close append
        # failed, and this server still reads it as unknown; reporting it as its
        # own outcome is a separate change.
        outcome = {0: "sent", 3: "unknown"}.get(proc.returncode, "unknown")
    detail = (proc.stdout + proc.stderr).strip()
    return outcome, route, detail[:600], mode


def deliver(home, said, run, route_hint="", invalidate=None):
    """Record what he typed, then carry the delivery out behind the answer.

    The click may not wait on a shell command: he types, it is recorded, and he
    moves on. So the durable record is written FIRST with outcome `sending`,
    and the same record is written again under the same `sid` when the command
    answers - delivered, failed or unknown, read from the exit code exactly as
    before. The page folds the two by `sid` and shows the outcome in place.

    Returns the sid. The thread is not a daemon: a delivery already started must
    finish even if the server is asked to stop.
    """
    sid = uuid.uuid4().hex[:12]
    record_said(home, dict(said, sid=sid, at=utc_now(), outcome="sending"))

    def carry_out():
        try:
            result = run()
        except subprocess.SubprocessError as exc:
            result = ("unknown", route_hint, str(exc))
        outcome, route, detail = result[0], result[1], result[2]
        extra = {"mode": result[3]} if len(result) > 3 else {}
        record_said(home, dict(said, sid=sid, at=utc_now(), outcome=outcome,
                               route=route, detail=detail, **extra))
        if invalidate is not None and outcome != "failed":
            invalidate()

    threading.Thread(target=carry_out, name="cc-deliver").start()
    return sid


def send_note(home_path, text):
    # Approved proposal section 3: the captain's words are logged even when they
    # answer no item, so a note with no addressee is a channel this surface owes.
    proc = subprocess.run(
        # The body goes over stdin, not argv: a note of exactly "-" is
        # fm-inbox.sh's own read-from-stdin selector, and as an argument it
        # would take that branch and queue nothing. The pipe closes after the
        # write, so a child that reads stdin still cannot hang the server.
        [os.path.join(BIN, "fm-inbox.sh"), "note", "-"],
        input=text, capture_output=True, text=True, timeout=SEND_TIMEOUT,
        env=dict(os.environ, FM_HOME=home_path), check=False,
    )
    detail = (proc.stdout + proc.stderr).strip()[:600]
    # fm-inbox.sh publishes the note record BEFORE it wakes firstmate and exits
    # nonzero if only the wake failed, so its exit code cannot tell nothing-saved
    # from saved-but-unannounced. Saying "not queued" about words already on disk
    # is the false claim this page exists to end, and a second note is not the
    # same note - queue_note mints a fresh id, so this route is not idempotent.
    outcome = "sent" if proc.returncode == 0 else "unknown"
    return outcome, "fm-inbox.sh note", detail


class Handler(BaseHTTPRequestHandler):
    server_version = "firstmate-command-center"
    protocol_version = "HTTP/1.1"
    records = None

    def log_message(self, fmt, *args):  # quieter than the stdlib default
        if self.path.startswith("/api/items"):
            return
        sys.stderr.write("%s %s\n" % (self.log_date_time_string(), fmt % args))

    # --- plumbing ------------------------------------------------------------
    def _send(self, code, body, ctype="application/json; charset=utf-8", etag=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if etag:
            self.send_header("ETag", etag)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, dump(obj))

    def _log_response(self, name, path, read):
        """Serve one log under a change check, but never cache a FAILED read.

        A read error carries no rows, and its (mtime, size) is the same one a
        successful read of the repaired file would have: caching it would answer
        304 to every later poll and leave the page saying his record could not
        be read long after it could.
        """
        etag = log_etag(path)
        if etag and self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            self.send_header("ETag", etag)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        rows, error, dropped = read(self.records.home)
        self._send(200, dump({name: rows, "error": error, "dropped": dropped}),
                   etag=None if error else etag)

    def _body(self):
        """Read the declared body first, on every path including a refusal.

        The connection is kept alive, so bytes left unread become the head of
        the next request: a refusal that skips the body hands the sender a way
        to smuggle a request that looks same-origin in behind the refused one.
        Anything that cannot be drained exactly closes the connection instead.
        """
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length < 0 or length > 1 << 20 or self.headers.get("Transfer-Encoding"):
            self.close_connection = True
            return None
        raw = self.rfile.read(length) if length else b""
        if len(raw) != length:
            self.close_connection = True
            return None
        try:
            return json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None

    def _local_request(self):
        """Hold the loopback trust boundary at the door.

        Binding to 127.0.0.1 keeps the network out but not the captain's own
        browser: any page he visits can post here, and a rebound hostname can
        read here. Both arrive with a Host, Origin or Sec-Fetch-Site that is not
        this server's, so that is what is checked.
        """
        port = self.server.server_address[1]
        if self.headers.get("Host") not in (f"127.0.0.1:{port}", f"localhost:{port}"):
            return False
        site = self.headers.get("Sec-Fetch-Site")
        if site is not None and site not in ("same-origin", "none"):
            return False
        origin = self.headers.get("Origin")
        return origin is None or origin in (
            f"http://127.0.0.1:{port}", f"http://localhost:{port}")

    def _text_field(self, payload):
        """Validate the one free-text field at the trust boundary."""
        text = payload.get("text")
        if not isinstance(text, str):
            return None, "no text"
        text = text.strip()
        if not text:
            return None, "an empty answer is not an answer"
        if len(text.encode()) > MAX_TEXT:
            return None, f"too long: the limit is {MAX_TEXT} bytes"
        return text, None

    # --- routes --------------------------------------------------------------
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if not self._local_request():
            self._send(403, b"not your server", "text/plain; charset=utf-8")
            return
        if path in ("/", "/command-center-state.js"):
            src = PAGE if path == "/" else RULES
            ctype = ("text/html" if path == "/" else "text/javascript")
            try:
                with open(src, "rb") as fh:
                    body = fh.read()
            except OSError as exc:
                self._send(500, f"cannot read {src}: {exc}".encode(),
                           "text/plain; charset=utf-8")
                return
            self._send(200, body, ctype + "; charset=utf-8")
            return

        if path == "/api/items":
            self.records.refresh()
            etag, body = self.records.snapshot()
            if etag is None:
                # Never serve the unscanned placeholder: an empty list reads as
                # "nothing is waiting on you", which is the one claim this page
                # exists to stop making without evidence.
                self._json(503, {"error": self.records.error
                                 or "the records have not been read yet"})
                return
            if self.headers.get("If-None-Match") == etag and not self.records.error:
                self.send_response(304)
                self.send_header("ETag", etag)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            view = json.loads(body)
            view["error"] = self.records.error
            self._send(200, dump(view), etag=etag)
            return

        if path == "/api/messages":
            self._log_response("messages", message_log(self.records.home),
                               read_messages)
            return

        if path == "/api/said":
            self._log_response("said", said_log(self.records.home), read_said)
            return

        self._send(404, b"not found", "text/plain; charset=utf-8")

    do_HEAD = do_GET

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        payload = self._body()
        ctype = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if not self._local_request() or ctype != "application/json":
            self._json(403, {"ok": False, "error": "refused: not this page"})
            return
        if payload is None or not isinstance(payload, dict):
            self._json(400, {"ok": False, "error": "unreadable request"})
            return
        text, err = self._text_field(payload)
        if err:
            self._json(400, {"ok": False, "error": err})
            return

        if path == "/api/note":
            # Approved proposal section 3: a note attached to no item still goes
            # in the captain's log, so this endpoint is part of that promise.
            sid = deliver(self.records.home,
                          {"kind": "note", "home": "main", "text": text},
                          lambda: send_note(self.records.home, text),
                          route_hint="fm-inbox.sh note")
            self._json(202, {"ok": True, "sid": sid, "outcome": "sending"})
            return

        if path == "/api/reply":
            # A reply to something firstmate SAID. Where it goes is decided by
            # the recorded message, never by the browser: a message the recorder
            # marked as a QUESTION is answered as that question, and anything
            # else reaches firstmate as a note, because a reply with nowhere to
            # be delivered is still his words. A message that is not a question
            # is never written as the answer to some other decision.
            msg_id = payload.get("msg")
            if not isinstance(msg_id, str) or not ID_RE.match(msg_id):
                self._json(400, {"ok": False, "error": "unknown message"})
                return
            message, log_error = find_message(self.records.home, msg_id)
            if log_error is not None:
                self._json(503, {"ok": False, "error": log_error})
                return
            if message is None:
                self._json(404, {"ok": False, "error": "no such message"})
                return
            self.records.refresh(min_interval=0)
            if self.records.etag is None:
                # With no published scan the answer route cannot be ruled out,
                # and falling through to the note route would tell him his steer
                # was delivered while the worker stayed stopped.
                self._json(503, {"ok": False,
                                 "error": self.records.error
                                 or "the records have not been read yet"})
                return
            item = (self.records.waiting_question(
                message.get("task"), message.get("question_key") or "")
                if message.get("question") else None)
            home_path = self.records.home_path(item["home"]) if item else None
            if item and home_path:
                said = {"kind": "answer", "home": item["home"], "item": item["id"],
                        "source": item["source"], "key": item.get("key"),
                        "item_key": item_key(item), "title": item.get("title"),
                        "sent_count": len(item.get("sent") or [])}
                run = lambda: send_answer(home_path, item, text)   # noqa: E731
                hint = "fm-send.sh " + item["id"]
                invalidate = self.records.invalidate
            else:
                said = {"kind": "note", "home": "main",
                        "title": message.get("title")}
                run = lambda: send_note(self.records.home, text)   # noqa: E731
                hint = "fm-inbox.sh note"
                invalidate = None
            sid = deliver(self.records.home, dict(said, msg=msg_id, text=text),
                          run, route_hint=hint, invalidate=invalidate)
            self._json(202, {"ok": True, "sid": sid, "outcome": "sending",
                             "source": said.get("source", "note")})
            return

        if path == "/api/answer":
            home_id = payload.get("home")
            task_id = payload.get("id")
            source = payload.get("source")
            key = payload.get("key") or ""
            if not isinstance(home_id, str) or not isinstance(task_id, str) \
                    or not isinstance(key, str) or source not in ("hold", "status") \
                    or not ID_RE.match(task_id):
                self._json(400, {"ok": False, "error": "unknown item"})
                return
            self.records.refresh(min_interval=0)
            if self.records.etag is None:
                self._json(503, {"ok": False,
                                 "error": "the records have not been read yet"})
                return
            item = self.records.item(home_id, task_id, source, key)
            home_path = self.records.home_path(home_id)
            if item is None or home_path is None:
                self._json(404, {"ok": False,
                                 "error": "that item is no longer waiting for you"})
                return
            sid = deliver(
                self.records.home,
                {"kind": "answer", "home": home_id, "item": task_id,
                 "source": item["source"], "key": item.get("key"),
                 "item_key": item_key(item), "title": item.get("title"),
                 "text": text, "sent_count": len(item.get("sent") or [])},
                lambda: send_answer(home_path, item, text),
                route_hint="fm-send.sh " + task_id,
                invalidate=self.records.invalidate)
            self._json(202, {"ok": True, "sid": sid, "outcome": "sending"})
            return

        self._json(404, {"ok": False, "error": "not found"})


UNIT = """\
[Unit]
Description=Firstmate command center
After=default.target

[Service]
ExecStart={python} {script} --port {port} --home {home}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
"""


def install_unit(home, port):
    """Write the user unit, and print the two commands only the captain can run.

    Enabling and lingering change his session, so this writes the file and stops
    there rather than reaching into systemd on his behalf.
    """
    directory = os.path.expanduser("~/.config/systemd/user")
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, "firstmate-command-center.service")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(UNIT.format(python=sys.executable, script=os.path.abspath(__file__),
                             port=port, home=home))
    print(f"wrote {path}")
    print("now run:")
    print("  systemctl --user daemon-reload")
    print("  systemctl --user enable --now firstmate-command-center")
    print("  loginctl enable-linger $USER   # so it starts at boot, before you log in")
    print(f"then bookmark http://127.0.0.1:{port}")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="The captain's permanent command center.")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--home", default=os.environ.get("FM_HOME"),
                        help="operational home to read (default: $FM_HOME, else the code root)")
    parser.add_argument("--install-unit", action="store_true",
                        help="write the systemd user unit and exit")
    args = parser.parse_args(argv)

    home = args.home or os.path.dirname(BIN)
    home = os.path.abspath(os.path.expanduser(home))
    if not os.path.isdir(home):
        print(f"command-center: no such home: {home}", file=sys.stderr)
        return 1
    if args.install_unit:
        return install_unit(home, args.port)
    for needed in (PAGE, RULES):
        if not os.path.exists(needed):
            print(f"command-center: a page file is missing: {needed}", file=sys.stderr)
            return 1

    Handler.records = Records(home)
    # Loopback only. This runs firstmate's scripts as the captain and has no
    # authentication of its own, so it must never listen on a routable address.
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    httpd.daemon_threads = True
    print(f"command center on http://127.0.0.1:{args.port}  (home: {home})")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
