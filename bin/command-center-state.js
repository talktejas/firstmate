// command-center-state.js - the command center's decision rules, as pure
// functions of state.
//
// These four are here, and only these four, because they are the ones that got
// the rules wrong twice: what a poll's answer means for the view on screen,
// whether a band may speak in the present, what a dropped send means on each
// route, and when a do-not-resend verdict is set and released. They touch no
// DOM and no network, so tests/command-center-state.test.js can execute the
// real rules rather than a restatement of them.
//
// The page loads this before its own script (bin/command-center.html) and
// bin/command-center.py serves it beside the page.

// --- what a poll's ANSWER means -----------------------------------------------
// Only a RESOLVED poll may change any of this. A poll being in flight says
// nothing about the view already on screen, so there is deliberately no entry
// point here for "a request is open".
//
//   answer.kind:
//     'unreachable'  the fetch itself failed - nothing can be sent
//     'unread'       reachable, but no scan has ever published - no list, and
//                    the server refuses sends too
//     'unchanged'    304: the server confirmed the view already on screen
//     'body'         a list arrived; answer.error set means the scan failed
//                    over a list an earlier scan published
function pollFacts(answer, now) {
  switch (answer.kind) {
    case 'unreachable':
      return { connected: false, offline: answer.detail || '', confirmed: false };
    case 'unread':
      return { connected: true, offline: null, unread: answer.detail || '',
               error: null, confirmed: false };
    case 'unchanged':
      // A read. It clears every reachability alarm, not the subset one branch
      // happens to remember: that enumeration is what kept leaving one standing.
      return { connected: true, offline: null, unread: null, error: null,
               confirmed: true, readAt: now };
    case 'body':
      // A body is a resolved read either way, so it always has a read time. An
      // error means the CONTENT is stale, which `confirmed` carries on its own.
      return answer.error
        ? { connected: true, offline: null, unread: null, error: answer.error,
            confirmed: false, readAt: now }
        : { connected: true, offline: null, unread: null, error: null,
            confirmed: true, readAt: now };
  }
  throw new Error('unknown poll answer: ' + answer.kind);
}

// --- may a band speak in the present? ------------------------------------------
// One question: did the last poll confirm the view on screen? Any state that
// leaves it unconfirmed inherits the historical labelling without being listed.
// The read time is the last successful READ, never the view's own `generated`,
// which is when the records last CHANGED - a dead watcher freezes that, so
// reading it as a read time turns the watcher's death into reassurance.
function tense(state, now) {
  const past = !state.confirmed;
  return { past, readAt: past && state.readAt ? state.readAt : now };
}

// --- what a dropped send means, per route ---------------------------------------
// The request never came back. On the SEND route the steer may already sit on
// the worker's inbox, so delivery is unknown and a second try is a second steer.
// A HOLD writes a local record with no delivery plane, and fm-captain-hold.sh
// documents an exact retry as idempotent: the hold route has NO locking outcome,
// in this failure or any other, because a lock there blocks the retry that IS
// the fix.
function transportFailure(source, detail) {
  return source === 'hold' ? { error: detail } : { outcome: 'unknown', detail };
}

// --- when a do-not-resend verdict is set, and when it ends -----------------------
// Set only for an outcome that forbids a resend, and never on the hold route.
function verdictFor(source, outcome, detail, sentCount) {
  if (source === 'hold' || outcome !== 'unknown') return null;
  return { outcome, detail: detail || '', sent: sentCount };
}

// Released on EVIDENCE, never on a clock: the item has left the list, or the
// steering record the send was unsure of has since appeared. A view the scan
// did not actually publish knows no items, so it releases nothing.
function releaseVerdicts(verdicts, view) {
  if (view.error || !Array.isArray(view.items)) return verdicts;
  const live = new Map(view.items.map(i => [itemKey(i), i]));
  const kept = {};
  for (const [key, verdict] of Object.entries(verdicts)) {
    const item = live.get(key);
    if (item && (item.sent || []).length <= verdict.sent) kept[key] = verdict;
  }
  return kept;
}

// The identity the server uses too (item_key in bin/command-center.py).
function itemKey(it) {
  return [it.home, it.source, it.id, it.key || ''].join('/');
}

if (typeof module === 'object' && module.exports)
  module.exports = { pollFacts, tense, transportFailure, verdictFor,
                     releaseVerdicts, itemKey };
