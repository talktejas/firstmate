# Command center

One permanent page showing everything firstmate has said to you, newest first, with a box to reply in, and beside it everything it is still waiting on you for across every local home.
Its default list is the conversation, because the terminal was the only other copy of it and a terminal scrolls.
Everything else on it is a view over firstmate's own records, not a second place where work lives.

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

The left list has three tabs.

**Messages** is the default and is what firstmate said to you: one row per message, newest first, each with its title, its time, and its project, worktree and branch.
Click one and the whole message opens with a box to reply in.
If the list is ever shortened it says so and says how many rows are missing, so a quiet list is always the whole of it.
A reply goes where your answer would have gone had you been at the terminal: to the worker still waiting on that task if there is one, and to firstmate itself if there is not.
Your replies appear under the message, so the exchange reads as a conversation.

Firstmate writes each of these as it sends it, with `bin/fm-captain-message.sh`; nothing captures terminal output, so a message firstmate did not record is one this page cannot show.
That obligation is `AGENTS.md` section 9.

**Waiting on you** is the queue firstmate is still holding, from two kinds of durable record:

- A **captain hold** on a backlog task, in any local home: a question filed for you.
- An **open status decision**: a worker that stopped on `needs-decision` or `blocked` and is waiting.
  These never appear as held tasks, which is why a surface built on holds alone cannot reach them.

A stopped worker's row carries the worker's own note, exactly as it wrote it, because the options you are being asked to choose between are the whole value of that row.
The one exception is the machine line a no-mistakes ask-user gate reports itself with, `ask-user findings=<ids> file=<path>`, which is ids and a path with the content deliberately left in the file: that row is stated plainly instead, as which project it is and that a worker there stopped and needs a decision or cannot go on.

**My words** is everything you have typed here and where it went.

Every row on every tab carries its project, its worktree and its branch.
`Group by` arranges the list by project, project and worktree, or project and branch. `Latest first` and `Oldest first` drop the grouping for one flat list in time order, and `Nothing — one flat list` drops it for one list in the order the records were read, making no ordering claim at all.

The messages lead with the last thing firstmate said and the waiting queue with what has waited longest; `Latest first` and `Oldest first` override both.

Beside it, `Filter by state` narrows the waiting list to what is stuck, sent but not acted on, or has nobody listening. Its default view leaves out rows firstmate has already deferred to a date still in the future — they are waiting, but not on you today — and `Deferred` is the one view that shows them.

In every ordered view, rows whose records carry no usable time are never given a guessed position: they follow the dated rows and the list says how many there are. The unsorted flat list orders nothing, so it says nothing about them either.

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

Something you sent a worker that has not been picked up is called stuck after 270 seconds, the page's own threshold, chosen to match firstmate's retry ladder: `FM_TASK_INBOX_GRACE_SECS` (default 90) between rings times `FM_TASK_INBOX_RING_MAX` (default 3) rings.
Nothing serves that environment to the browser, so setting either variable changes firstmate's ringing and not this page; to keep the two in step, edit `GRACE_SECS` and `RING_MAX` in `bin/command-center.html` as well.

Above the list, every notice that applies is shown as its own band, because two independent facts never share one slot and none of them pushes another off the screen: whatever has gone wrong between the page and the records, a backlog whose holds are hidden, the homes firstmate is not watching, and the homes it is — each named, each with its own last beat from `state/.last-watcher-beat`.
If a home has gone quiet, an answer you send there is still recorded but nothing will ring it, and the page says so rather than looking normal.
Three things can go wrong between the page and the records, and each says what you can do about it. **It cannot reach the server** — nothing can be sent until it is back. **The server answers but no scan has ever succeeded** — there is no list, and the server refuses sends until there is one. **A scan failed over a list an earlier one read** — the list may be incomplete, and everything on it can still be answered.
In all three the health bands stay on screen but stop speaking in the present: they say what was true at the last successful read, and when that read was. A poll merely being in flight changes nothing — the bands keep saying what the last answer established until a new one arrives.

The page itself arrives as two files from the same address: the page, and `bin/command-center-state.js`, the decision rules every band and every send verdict above is made by.
The server refuses to start if either is missing, but a file can still fail to be served under it — during a self-update, say — so if the rules do not arrive the page says it did not load completely and sends nothing, rather than showing an empty list and a live beat it cannot stand behind. Reload; if that does not fix it, restart the command center.

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

## Where your reply to a message goes

| The message was recorded as | It runs |
|---|---|
| the question on a decision still waiting on you | whatever that row would have run under **Where your answer goes** above, unchanged |
| the question on a decision already settled | `bin/fm-inbox.sh note`, queued for firstmate's next turn |
| not a question | `bin/fm-inbox.sh note`, queued for firstmate's next turn |

Whether a message is a question is recorded when it is written, with `--question`, and never guessed from the task it names.
A task collects several messages over its life - the question, then the PR, then the result - so a reply routed by task id alone would be written as the answer to whatever decision that task happens to be stopped on, which is a wrong answer delivered to a worker.
Only the decision the message itself named can be answered by a reply to it.
The reply box says which of the three rows above your reply is about to take, before you send it.
Until the records have been read it says the route cannot be told yet rather than naming one, because the page never claims what the records do not support.

The server decides the route from the recorded message and the current scan, never from the browser.
A reply naming a message this home never recorded is refused, and a task id is only ever matched against the home this page was started on, because two homes on one machine can hold the same one.
A reply to a recorded question is refused outright while no scan has been read, because a reply that cannot rule out the answer route must not quietly become a note.
A reply to a message that is not a question is not refused then: no scan can change where it goes, so a backlog that will not parse has nothing to say about it.
A reply carries the same do-not-resend protection an answer does: on an unconfirmed delivery it keeps your words, stops offering Reply, and waits until you say to send it anyway.

## What it stores

`<home>/data/captain-messages.jsonl`, an append-only log of what firstmate said to you: when, the title, the text, and the project, worktree, branch and task it named, each recorded as unknown rather than guessed when nothing knows it.
`bin/fm-captain-message.sh` is its only writer, and `--task` fills the project, worktree and branch from that task's own record so all three are one flag rather than three chances to leave one out.
`--question` marks a message as the question waiting on you, and `--question-key` names the stopped worker's own decision it asks about.

`<home>/data/command-center/said.jsonl`, an append-only log of what you typed and where it went.
Your words are written there before the click returns, so the click never waits on a shell command: you send, it is recorded, and you move straight to the next item while the delivery is carried out behind you.
That is why one send writes two rows under the same `sid`: **sending** when your words were taken, and the outcome when the command answered.
The page folds the pair and shows the outcome in place on the row you answered, so nothing is claimed about delivery until the command has said it.
Until then the box says your words were written down and are going out, never that they arrived, and the button that sent them does not offer to send them again.

The outcome is read from the exit code of the command that ran and nothing else: **sent**, **failed** (a captain hold refused the record and nothing left this machine — answering it again is safe, and `fm-captain-hold.sh` documents an exact retry as idempotent), or **unknown** (the command reported neither, so the page never guesses which: the page reads only a confirmed `fm-send.sh` exit as sent, and every other exit is unknown to it — including the one that says the answer was delivered but its decision close failed, which the page does not yet report as a state of its own; and `fm-inbox.sh` saves a note before it wakes firstmate, so its failure may mean only that the wake did not land).
On **unknown** the page keeps your text, says plainly that delivery could not be confirmed, and does not offer Send again until the steering record appears — or until you say so yourself, knowing it may be a second copy.
On any other non-success it keeps your text too, so nothing you typed is cleared by a send that did not land.
Your words stay in the box until the outcome row says the send landed; when it says failed or unknown they are put back where you typed them, the row you sent from is flagged `not sent`, and a note that did not land says so on its own button.
If no outcome ever arrives, because the server or the page stopped while the command was still running, the page releases that send itself once the send window has passed: your words come back, the controls work again, and the row says plainly that nothing ever reported what became of it.

An open item shows one line derived from this record: the last thing you sent about it and what became of it, and a message shows every reply you sent to it.
Both logs are served whole, and if either is ever shortened the page says so and says how many rows are missing, because a reply missing from a thread reads as a message you never answered.

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

A home whose holds are hidden from the page — one on a non-markdown backlog backend, or one whose backlog file is there but cannot be read — reports `backlog_readable: false`, and the page says so in its own band rather than letting the list look short. A markdown home whose backlog file does not exist yet is a different thing: it holds nothing, so it reports readable and empty and gets no band.

## Reading it without the page

`bin/command-center-scan.sh` prints the waiting view as JSON, and `--fingerprint` prints only the change check.
`<home>/data/captain-messages.jsonl` is one JSON object per message and needs nothing to read it.
Both honour `FM_HOME`.
