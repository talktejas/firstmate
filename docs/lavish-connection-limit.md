# Lavish review pages stalling past six open tabs

## The problem

Chrome allows six simultaneous connections to one server origin.
Every open Lavish review page permanently holds one of them open for its live-update stream (`dist/chrome-client.js`, `new EventSource("/events/" + key)`), served by a handler that never closes.
At six pages open at once, the seventh page never loads and "Send to agent" on an already-open page silently queues instead of arriving - the message is not lost, it just waits for a connection to free up.
Full investigation: `data/fm-lavish-pages-dont-load/report.md`.

This is a client bug in lavish-axi upstream, not anything in this repo or in the Lavish server.
Confirmed still present as of the installed 0.1.63 (the original report checked 0.1.43 and 0.1.52).

## The patch

`bin/fm-lavish-client-patch.sh` edits the installed `dist/chrome-client.js` in place.
It releases the page's `EventSource` when the tab goes to the background (`document.visibilitychange`, `document.hidden`) and reopens it when the tab is shown again; a page opened straight into a background tab never takes a connection until it is first looked at.
Since the captain looks at one page at a time, this removes the six-page ceiling entirely.
The server only replays chat and presence to a reconnecting stream, never a `reload`, so a page whose stream was closed while hidden also resyncs its artifact frame when shown again;
a regeneration pushed while that tab was hidden is not missed.
A page that started in a background tab is the exception: its first view only opens the stream, so a regeneration pushed before that first look still needs a manual reload.

One tradeoff this patch does not solve: while every review page is hidden, the shared server sees no connections, so its idle timer runs.
If the whole browser stays backgrounded or minimized for `LAVISH_AXI_IDLE_TIMEOUT_MS` (default 30m) with no agent polling, the server shuts down and the open pages go dead until it is relaunched.
Raise or disable that timeout on the shared server if that bites.

Run it any time to check or reapply:

```
bin/fm-lavish-client-patch.sh
```

It is idempotent - a second run detects the patch is already present and changes nothing - and it refuses without touching the file if lavish-axi's surrounding code no longer matches what it expects to replace, rather than risk corrupting the installed client.
The write itself is atomic (a sibling `chrome-client.js.fm-tmp` renamed over the original), so an interrupted or failed run leaves the installed client intact; delete a leftover `.fm-tmp` file if you see one.

A server restart is required for a freshly applied patch to take effect in already-open pages; this script never restarts the shared server itself.

Upgrading lavish-axi silently reverts the patch: an upgrade reinstalls `dist/chrome-client.js` from the new package, unpatched.
Re-run the script after every `lavish-axi update`.

Verification for this patch was static rather than a live six-plus-tab browser proof.
`tests/fm-lavish-client-patch.test.sh` owns the repeatable part: against a fixture it writes itself, it proves the script applies once, is a no-op on a second run, and refuses without touching the file when the target code has moved, then runs the patched code against a fake `EventSource`/`document` harness to prove the stream closes on hide and reopens on show.
The remaining checks were one-off manual verification during the task and are not re-run by that test: `node --check` and the three idempotency cases against throwaway copies of the installed lavish-axi 0.1.63 client fetched via `npm pack`, and an HTTP check against a disposable Lavish instance on a private port confirming the served client was the patched one.
This machine's only browsers are the captain's own, so proving the fix live needs opening more than six real tabs and no browser here can do that without it being his.
The real proof will be the captain simply no longer seeing pages stall.

## Two workarounds that need no patch

- Keep at most four or five review pages open at once.
- Spread pages across `127.0.0.1:4387` and `localhost:4387` - the browser budgets each address's six connections separately, so up to twelve pages can stay open split between the two.
  (`[::1]:4387` is not a third address; the server only listens on IPv4.)
