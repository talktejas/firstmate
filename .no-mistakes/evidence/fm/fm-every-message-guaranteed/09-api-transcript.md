# Command Center — live drive transcript (isolated home /tmp/cc-live, server on 127.0.0.1:8792)

## 1. Stop hook captures a turn-final message, with nobody recording it (primary checkout /tmp/cc-primary)
$ printf {"transcript_path":".../sess-1.jsonl"} | fm-captain-message-hook.sh   # 0.23s
$ cat /tmp/cc-primary/data/captain-messages.jsonl
{"id":"c2c89e76ccb5a623e","at":"2026-09-20T21:30:38Z","title":"Said as the turn ended, with nobody recording it.","text":"Said as the turn ended, with nobody recording it.","task":null,"project":null,"worktree":null,"branch":null,"pr":null,"source":"transcript","session":"s1","req":"r-hook"}

(the same transcript also held a harness entry model=<synthetic> "No response requested." — it is absent above)

## 2. The server itself captures a new chat message on its backstop cadence
$ curl .../api/messages?q=pr+%2317
{
    "messages": [
        {
            "id": "cbb468cda084050bf",
            "at": "2026-09-20T21:28:57Z",
            "title": "PR #17 is ready for your review, captain.",
            "text": "PR #17 is ready for your review, captain.",
            "task": null,
            "project": null,
            "worktree": null,
            "branch": null,
            "pr": null,
            "source": "transcript",
            "session": "sess-live",
            "req": "r9"
        }
    ],
    "more": false,
    "total": 226,
    "error": null,

$ curl .../api/messages?q=no+response+requested   # the synthetic entry beside it
{"messages": [], "total": 226}

## 3. A send returns before it delivers (fm-inbox stub sleeps 12s)
$ time curl -X POST .../api/note -d {"text":"Ship the green palette."}
{"ok":true,"outcome":"sending","said":"9255f84f940c"}   elapsed=0.00s
$ curl .../api/said        # 14s later, the outcome folded back onto the record
{"kind": "note", "msg": "c787a9307eace3a54", "title": "Deploy is blocked on the \u00dcber-gate review.", "text": "Understood \u2014 hold the deploy until the gate clears.", "sid": "28a28fa8637e", "at": "2026-09-20T21:27:43Z", "outcome": "sent", "resolved": "note", "route": "fm-inbox.sh note", "detail": "note queued after a slow wake", "home": "main"}
{"kind": "answer", "home": "main", "item": "cc-live", "source": "hold", "key": "cc-live", "item_key": "main/hold/cc-live/cc-live", "title": "Blue or green?", "text": "Go with green.", "sid": "5259130c08b2", "at": "2026-09-20T21:25:56Z", "outcome": "sent", "route": "fm-captain-hold.sh answer cc-live --release", "detail": "released: cc-live", "mode": "release"}
{"kind": "note", "msg": "cbffa22644f1e4448", "title": "Palette landed", "text": "Green is right. Ship it.", "sid": "7ddcd82fb1e6", "at": "2026-09-20T21:25:56Z", "outcome": "sent", "resolved": "note", "route": "fm-inbox.sh note", "detail": "note queued after a slow wake", "home": "main"}
{"kind": "note", "home": "main", "text": "Ship the green palette.", "sid": "9255f84f940c", "at": "2026-09-20T21:25:30Z", "outcome": "sent", "route": "fm-inbox.sh note", "detail": "note queued after a slow wake"}

## 4. Every message stays reachable: window, by-id, and search past it
$ curl .../api/messages
served 200 of total 226 more: True
$ curl .../api/messages?id=cbffa22644f1e4448   # 220+ rows behind the window
[{"id": "cbffa22644f1e4448", "at": "2026-09-20T21:24:23Z", "title": "Palette landed", "text": "# Palette landed\nThe **green** palette is live. CI is green and the PR is ready for you.", "task": null, "project": null, "worktree": null, "branch": null, "pr": null, "source": "transcript", "session": "sess-live", "req": "r2"}]
$ curl .../api/messages?q=%C3%BCber   # non-ASCII search
['Deploy is blocked on the Über-gate review.']
