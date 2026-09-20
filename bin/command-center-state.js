// command-center-state.js - the command center's decision rules, as pure
// functions of state.
//
// What is here is what got the rules wrong, or what a wrong rule would cost him
// silently: what a poll's answer means for the view on screen, whether a band
// may speak in the present, what a dropped send means on each route, when a
// do-not-resend verdict is set and released, and the order each of the two
// lists is in. They touch no DOM and no network, so
// tests/command-center-state.test.js can execute the real rules rather than a
// restatement of them.
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
//
// A verdict against a MESSAGE is not an item's to release. The message log is
// append-only, so nothing in a scan of the work records is evidence about it,
// and a scan is not allowed to quietly re-offer a reply that may already have
// been delivered: that one ends when he says it does.
function releaseVerdicts(verdicts, view) {
  if (view.error || !Array.isArray(view.items)) return verdicts;
  const live = new Map(view.items.map(i => [itemKey(i), i]));
  const kept = {};
  for (const [key, verdict] of Object.entries(verdicts)) {
    if (key.startsWith('msg/')) { kept[key] = verdict; continue; }
    const item = live.get(key);
    if (item && (item.sent || []).length <= verdict.sent) kept[key] = verdict;
  }
  return kept;
}

// --- what a message is, and what order a list is in -----------------------------
// A recorded message (bin/fm-captain-message.sh) is given the same time and
// branch fields a scanned item has, so one grouping and one ordering serve both
// lists rather than two that can drift apart.
function shapeMessage(m) {
  const at = Date.parse(m.at || '');
  return Object.assign({}, m, {
    since_epoch: isNaN(at) ? null : Math.floor(at / 1000),
    since_kind: isNaN(at) ? 'none' : 'created',
    branch_state: m.branch ? 'branch' : 'not-started',
  });
}

// `newestDefault` is what an UNSORTED view means for each list, and the two
// differ honestly: the waiting queue leads with what has waited longest, while
// the messages lead with the last thing firstmate said. Latest and Oldest are
// explicit choices and override both. A row with no usable time is never given
// a position among the dated ones: it follows them, and the page says why.
function orderRows(rows, group, newestDefault) {
  if (group === 'none') return rows;   // as read: the flat list claims no order
  const dated = rows.filter(r => r.since_epoch);
  const undated = rows.filter(r => !r.since_epoch);
  const newest = group === 'latest' || (newestDefault && group !== 'oldest');
  dated.sort((a, b) => newest ? b.since_epoch - a.since_epoch
                              : a.since_epoch - b.since_epoch);
  return dated.concat(undated);
}

// --- two rows, one send ---------------------------------------------------------
// The click may not wait on a shell command, so the server writes his words to
// the durable record the moment it accepts them and writes the same record
// again under the same `sid` when the command answers (deliver in
// bin/command-center.py). The rows arrive newest first, so the first row for a
// sid is the later one: the outcome supersedes the acceptance.
function foldSaid(rows) {
  const seen = new Set();
  const kept = [];
  for (const r of rows || []) {
    if (r.sid) {
      if (seen.has(r.sid)) continue;
      seen.add(r.sid);
    }
    kept.push(r);
  }
  return kept;
}

// --- did anything actually change? ----------------------------------------------
// A log that does not exist yet is served with no change check, so every poll
// of it is a fresh 200 and "the response arrived" says nothing about whether
// the list moved. Both logs only ever grow at one end, so their length plus
// their newest row is their identity; a poll that finds the same one must not
// re-render, or the open reply box is rebuilt under his cursor every few
// seconds.
function listSignature(rows) {
  const newest = (rows || [])[0] || {};
  return [(rows || []).length, newest.sid || newest.id || '',
          newest.outcome || '', newest.at || ''].join('/');
}

// --- what an arrived outcome does to the words he typed -------------------------
// The click is accepted before the command runs, so the record's outcome row is
// what decides the fate of his draft. Only a send that LANDED may take his
// words out of the box: on failed or unknown they go back where he typed them
// and the row he sent from is flagged, because docs/command-center.md promises
// nothing he typed is cleared by a send that did not land. `null` means the
// outcome has not arrived yet and nothing may happen to them.
function wordsAfter(row) {
  if (!row || !row.sid || row.outcome === 'sending') return null;
  return row.outcome === 'sent' ? 'clear' : 'restore';
}

// --- where a reply is about to go -----------------------------------------------
// The same rule the server routes by (waiting_question in
// bin/command-center.py), so the pane can tell him what his reply will do
// BEFORE he sends it rather than after.
//
// Only a message the recorder marked as a question is answerable, and only
// against the decision it named: a task collects several messages over its
// life, so routing by task id alone would write his reply as the answer to
// whatever decision that task happens to be stopped on. Everything else is a
// note to firstmate, which is his words reaching firstmate without being
// delivered as an answer to a question he was not looking at.
function replyTarget(message, items) {
  if (!message.question) return { kind: 'note' };
  const key = message.question_key || '';
  const item = (items || []).find(it => it.home === 'main' && it.id === message.task
    && (key ? it.source === 'status' && (it.key || '') === key
            : it.source === 'hold'));
  return item ? { kind: 'answer', item } : { kind: 'note', settled: true };
}

// The identity the server uses too (item_key in bin/command-center.py).
function itemKey(it) {
  return [it.home, it.source, it.id, it.key || ''].join('/');
}

if (typeof module === 'object' && module.exports)
  module.exports = { pollFacts, tense, transportFailure, verdictFor,
                     releaseVerdicts, itemKey, shapeMessage, orderRows,
                     replyTarget, foldSaid, wordsAfter,
                     listSignature };
