# Command center

One permanent page showing everything firstmate is waiting on you for, across every local home, with your answer going straight back.
It is a view over firstmate's own records, not a second place where work lives.

## Start it

```sh
python3 bin/command-center.py --home "$FM_HOME"
```

Then open `http://127.0.0.1:8765`.
That address never changes, so bookmark it once.

Nothing to install: it is Python 3 standard library only, with no build step and no dependency to keep current.
`jq` and `git` are already firstmate requirements and are used by the reading half.

## Keep it running

```sh
python3 bin/command-center.py --install-unit --home "$FM_HOME"
systemctl --user daemon-reload
systemctl --user enable --now firstmate-command-center
loginctl enable-linger "$USER"
```

The last line is what makes it start at boot rather than at your first login.
After this the page is simply there, at the same address, across a server restart, a firstmate restart and a reboot.

`--port` changes the port for both the server and the generated unit.
Re-run `--install-unit` after changing it, then `systemctl --user daemon-reload && systemctl --user restart firstmate-command-center`.

## What it shows

The left list is everything waiting on you, from two kinds of durable record:

- A **captain hold** on a backlog task, in any local home: a question filed for you.
- An **open status decision**: a worker that stopped on `needs-decision` or `blocked` and is waiting.
  These never appear as held tasks, which is why a surface built on holds alone cannot reach them.

Every row carries its project, its worktree and its branch.
`Group by` arranges the list by project, project and worktree, or project and branch. `Latest first` and `Oldest first` drop the grouping for one flat list in time order, and `Nothing — one flat list` drops it for one list in the order the scan read the records, making no ordering claim at all.

In the two time-ordered views, rows whose records carry no usable time are never given a guessed position: they follow the dated rows and the list says how many there are. The unsorted flat list orders nothing, so it says nothing about them either.

## What it can and cannot prove

The page never shows a state the records cannot support.

| Shown | Proved by |
|---|---|
| Delivered | the steering record exists under `state/<id>.inbox/` |
| Picked up | the worker moved that record into `handled/`, which is the acknowledgement itself |
| Acted on | the answer itself, which settles the decision in the same act — reported under **My words** |

Nothing is reported between delivered and picked up, because nothing between them is observable.
An item is in the waiting list only while its decision is still open, so the live track carries the first two facts only; the settlement appears under **My words**, written by the act that settled it.
The doorbell ring that `fm-send.sh` types into a pane is best effort and is never treated as proof that anything was read.

The lamp beside each row is `bin/fm-busy-lib.sh`'s classification of whether anyone is listening: **working**, **waiting**, **cannot tell**, **not running**, or **no worker** for a question firstmate itself owns.
A missing or stale signal classifies as *cannot tell* and is never shown as healthy.

A message that has not been picked up is called stuck after 270 seconds, the page's own threshold, chosen to match firstmate's retry ladder: `FM_TASK_INBOX_GRACE_SECS` (default 90) between rings times `FM_TASK_INBOX_RING_MAX` (default 3) rings.
Nothing serves that environment to the browser, so setting either variable changes firstmate's ringing and not this page; to keep the two in step, edit `GRACE_SECS` and `RING_MAX` in `bin/command-center.html` as well.

Above the list, one line reports whether firstmate is still watching each home, read from `state/.last-watcher-beat`.
If it has gone quiet, an answer you send is still recorded but nothing will ring it, and the page says so rather than looking normal.

## Where your answer goes

| You answered | It runs |
|---|---|
| a question held for you (`kind: captain`) | `bin/fm-captain-hold.sh answer`, which records your exact words and closes the call in the same act |
| work held pending your answer (any other kind) | `bin/fm-captain-hold.sh answer --release`, which records your words and lifts the hold so the work resumes — it is never marked done |
| a stopped worker | `bin/fm-send.sh --resolve-key`, which puts your words in the worker's steering inbox and closes the decision |
| a note that answers nothing | `bin/fm-inbox.sh note`, queued for firstmate's next turn |

The server reuses those commands rather than writing records itself, so every guard they carry still applies.
Every answer settles the decision it was sent about; the only difference between the two held rows is whether settling it closes the task or lets the work go on.
A held row that records no kind at all cannot be told apart, so the command center refuses the send and says so rather than risk marking unstarted work complete — answer that one with `fm-captain-hold.sh`, which can see the task itself.

## What it stores

One file: `<home>/data/command-center/said.jsonl`, an append-only log of what you typed and where it went, with the outcome of the send, read from the exit code of the command that ran and nothing else: **sent**, **failed** (a captain hold refused the record and nothing left this machine — answering it again is safe, and `fm-captain-hold.sh` documents an exact retry as idempotent), or **unknown** (the command reported neither, so the page never guesses which: `fm-send.sh` cannot say whether the steer reached the worker, and `fm-inbox.sh` saves a note before it wakes firstmate, so its failure may mean only that the wake did not land).
On **unknown** the page keeps your text, says plainly that delivery could not be confirmed, and does not offer Send again until the steering record appears — or until you say so yourself, knowing it may be a second copy. On any other non-success it keeps your text too, so nothing you typed is cleared by a send that did not land.

An open item shows one line derived from this record: the last thing you sent about it and what became of it.

If that log cannot be written the send is unaffected — firstmate's own records already hold a delivered answer and a queued note — so the server reports it on its own output and the page says nothing it cannot support.

That exists because firstmate keeps an answer that closes a decision but does not keep the rest of your words: a steer to a worker is removed with the task's steering inbox at cleanup, and an unsent draft was never recorded anywhere.
Everything else on the page is read fresh from firstmate's records, so there is no second copy to drift.

Two things stay in this browser, in its local storage, because they are yours and this runs on your machine: unsent drafts (an answer in progress and an unsent note alike), and which rows you have already opened.
They are per-browser and per-profile: they do not follow you to another browser, another machine or a private window, and clearing site data deletes them. What that costs you is a draft you had not sent; everything you did send is in firstmate's own records and in the log above.

## Cost and limits

The page polls `/api/items` every three seconds and is answered `304` when nothing moved.
The change check is a stat sweep over every status log, task meta, steering inbox and backlog across all homes, which takes about 30ms, so the full scan runs once per real change however many tabs are open.

Server-sent events were rejected deliberately: a browser allows six connections per origin, and a held stream per tab is what already stalls this fleet's review pages once six are open.

It binds loopback only.
It runs firstmate's scripts with your authority and has no authentication of its own, so it must never be bound to a routable address.

Remote secondmate homes are not polled: reaching one needs the remote transport, which is not a cost a three-second poll may pay.
Only local homes appear.

A home on a non-markdown backlog backend reports `backlog_readable: false` rather than appearing empty.

## Reading it without the page

`bin/command-center-scan.sh` prints the same view as JSON, and `--fingerprint` prints only the change check.
Both honour `FM_HOME`.
