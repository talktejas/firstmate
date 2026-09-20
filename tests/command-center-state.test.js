// Behavioral regressions for the command center's decision rules. These execute
// bin/command-center-state.js itself - the same file the page loads - so what is
// asserted is the rule, not a restatement of it. No DOM is involved: every one
// of these is a pure function of state.
'use strict';
const assert = require('assert');
const path = require('path');
const {
  pollFacts, tense, transportFailure, verdictFor, releaseVerdicts, itemKey,
  shapeMessage, orderRows, replyTarget,
} = require(path.join(__dirname, '..', 'bin', 'command-center-state.js'));

// Quiet on success: tests/command-center.test.sh runs this and reports the
// count, so only failures need to speak.
let failures = 0, ran = 0;
function test(name, fn) {
  ran++;
  try {
    fn();
  } catch (err) {
    failures++;
    console.error('not ok - ' + name + '\n  ' + (err && err.message));
  }
}
process.on('exit', () => { if (!failures) console.log(ran); });

const NOW = 1_800_000_000;

// --- what a poll's answer means -------------------------------------------------

// A request merely being open is not an answer: a confirmed view stays confirmed
// until a resolved one says otherwise, and there is no answer kind for "open".
test('an in-flight poll cannot unconfirm a confirmed view', () => {
  const live = { confirmed: true, readAt: NOW - 5, connected: true };
  assert.deepStrictEqual(tense(live, NOW), { past: false, readAt: NOW });
  assert.throws(() => pollFacts({ kind: 'inflight' }, NOW), /unknown poll answer/,
    'a request being open decides nothing, so it is not an answer this accepts');
});

// A 304 IS a successful read: it proves the server is reachable and confirms the
// view on screen, so it must clear EVERY reachability alarm, not a subset.
test('a resolved 304 clears every reachability alarm', () => {
  const facts = pollFacts({ kind: 'unchanged' }, NOW);
  assert.strictEqual(facts.connected, true);
  assert.strictEqual(facts.offline, null);
  assert.strictEqual(facts.unread, null);
  assert.strictEqual(facts.error, null);
  assert.strictEqual(facts.confirmed, true);
  assert.strictEqual(facts.readAt, NOW);
});

// The server answered, so it is reachable - but no scan has ever published, so
// there is no list and it refuses sends too. This must not read as a list that
// can still be answered.
test('a never-scanned answer is reachable, unconfirmed and not an error', () => {
  const facts = pollFacts({ kind: 'unread', detail: 'not read yet' }, NOW);
  assert.strictEqual(facts.connected, true, 'the server did answer');
  assert.strictEqual(facts.offline, null, 'so no cannot-reach alarm may stand');
  assert.strictEqual(facts.unread, 'not read yet');
  assert.strictEqual(facts.error, null, 'not the failed-scan state');
  assert.strictEqual(facts.confirmed, false);
  assert.strictEqual('readAt' in facts, false, 'nothing was read');
});

// A body that carries an error is still a resolved READ. What is stale is the
// content, which `confirmed` carries on its own.
test('a failed scan over a published list still records a read time', () => {
  const facts = pollFacts({ kind: 'body', error: 'scan failed' }, NOW);
  assert.strictEqual(facts.confirmed, false);
  assert.strictEqual(facts.readAt, NOW);
  assert.strictEqual(facts.error, 'scan failed');
  assert.strictEqual(facts.connected, true);
  assert.strictEqual(facts.unread, null);
});

test('an unreachable answer forbids nothing but confirmation', () => {
  const facts = pollFacts({ kind: 'unreachable', detail: 'Failed to fetch' }, NOW);
  assert.strictEqual(facts.connected, false);
  assert.strictEqual(facts.offline, 'Failed to fetch');
  assert.strictEqual(facts.confirmed, false);
  assert.strictEqual('readAt' in facts, false, 'nothing was read');
});

// --- may a band speak in the present? --------------------------------------------

test('an unconfirmed view speaks in the past, from the last read', () => {
  const read = NOW - 600;
  assert.deepStrictEqual(
    tense({ confirmed: false, readAt: read }, NOW), { past: true, readAt: read });
});

// The view's own `generated` is when the records last CHANGED. A dead watcher
// freezes it, so a read time must never come from it - reading it as one turns
// the watcher's death into "heard moments ago".
test('a read time is never derived from unchanged content', () => {
  const lastBeat = NOW - 3600;
  const state = { confirmed: false, readAt: NOW - 3,
                  view: { generated: new Date(lastBeat * 1000).toISOString() } };
  const { readAt } = tense(state, NOW);
  assert.strictEqual(readAt, NOW - 3, 'the last READ, not the last change');
  assert.ok(readAt - lastBeat > 300,
    'a watcher silent for an hour must still classify as stale');
});

// --- what a dropped send means, per route -----------------------------------------

// A hold writes a local record with no delivery plane and fm-captain-hold.sh
// documents an exact retry as idempotent, so there is nothing to duplicate.
test('the hold route never receives a locking outcome', () => {
  const dropped = transportFailure('hold', 'Failed to fetch');
  assert.strictEqual(dropped.outcome, undefined, 'a plain failure, not unknown');
  assert.strictEqual(dropped.error, 'Failed to fetch');
  for (const outcome of ['unknown', 'failed', 'sent', undefined])
    assert.strictEqual(verdictFor('hold', outcome, 'why', 0), null,
      'no outcome may lock the hold route: ' + outcome);
});

// On the send route the steer may already sit on the worker's inbox, and a
// second try is a second steer.
test('a dropped send on the worker route is unknown, not failed', () => {
  const dropped = transportFailure('status', 'Failed to fetch');
  assert.strictEqual(dropped.outcome, 'unknown');
  assert.strictEqual(dropped.error, undefined, 'it must not read as a failure');
  assert.deepStrictEqual(verdictFor('status', 'unknown', 'why', 2),
    { outcome: 'unknown', detail: 'why', sent: 2 });
});

test('only an unknown delivery locks, and only off the hold route', () => {
  assert.strictEqual(verdictFor('status', 'failed', 'why', 0), null);
  assert.strictEqual(verdictFor('status', 'sent', '', 0), null);
});

// --- when a verdict ends ----------------------------------------------------------

const item = (over) => Object.assign(
  { home: 'main', source: 'status', id: 't-1', key: 'k', sent: [] }, over);

test('a verdict is released when the steering record it doubted appears', () => {
  const it = item();
  const verdicts = { [itemKey(it)]: { outcome: 'unknown', detail: '', sent: 0 } };
  const arrived = item({ sent: [{ seq: '001' }] });
  assert.deepStrictEqual(
    releaseVerdicts(verdicts, { items: [arrived] }), {},
    'the record proves the steer landed');
  assert.deepStrictEqual(
    releaseVerdicts(verdicts, { items: [it] }), verdicts,
    'with no new record there is no evidence, so the verdict stands');
});

test('a verdict is released when its item leaves the list', () => {
  const it = item();
  const verdicts = { [itemKey(it)]: { outcome: 'unknown', detail: '', sent: 0 } };
  assert.deepStrictEqual(releaseVerdicts(verdicts, { items: [] }), {});
});

// A view the scan did not publish knows no items, so it is not evidence that
// anything is gone - releasing against it would drop the do-not-resend guard.
test('a verdict survives a view that proves nothing', () => {
  const it = item();
  const verdicts = { [itemKey(it)]: { outcome: 'unknown', detail: '', sent: 0 } };
  assert.deepStrictEqual(
    releaseVerdicts(verdicts, { error: 'scan failed', items: [] }), verdicts);
  assert.deepStrictEqual(releaseVerdicts(verdicts, {}), verdicts);
});

// A task can be captain-held AND stopped on its own status record at once, and
// the two are answered by different commands.
test('an item is identified by its record as well as its task', () => {
  assert.notStrictEqual(
    itemKey(item({ source: 'hold', key: 't-1' })),
    itemKey(item({ source: 'status', key: 'k' })));
});

// --- the two lists are in different orders, and both are deliberate -----------
const msg = (id, at, over) => shapeMessage(Object.assign({ id, at }, over));
const M = [
  msg('m1', '2026-09-01T10:00:00Z'),
  msg('m2', '2026-09-02T10:00:00Z'),
  msg('m3', '2026-09-03T10:00:00Z'),
];
const ids = rows => rows.map(r => r.id).join(',');

test('a message is given the time and branch fields a row is grouped by', () => {
  const m = shapeMessage({ id: 'm', at: '2026-09-01T10:00:00Z', branch: 'fm/x' });
  assert.strictEqual(m.since_epoch, Math.floor(Date.parse('2026-09-01T10:00:00Z') / 1000));
  assert.strictEqual(m.branch_state, 'branch');
  assert.strictEqual(shapeMessage({ id: 'm', at: '' }).since_epoch, null,
    'a record with no usable time must not be given one');
  assert.strictEqual(shapeMessage({ id: 'm', at: '' }).branch_state, 'not-started');
});

// He opens the page to see the LAST thing firstmate said, while the waiting
// queue leads with what has waited longest. One rule, two defaults.
test('messages default to newest first and the waiting queue to oldest first', () => {
  assert.strictEqual(ids(orderRows(M, 'project', true)), 'm3,m2,m1');
  assert.strictEqual(ids(orderRows(M, 'project', false)), 'm1,m2,m3');
});

test('Latest and Oldest override both defaults', () => {
  assert.strictEqual(ids(orderRows(M, 'oldest', true)), 'm1,m2,m3');
  assert.strictEqual(ids(orderRows(M, 'latest', false)), 'm3,m2,m1');
});

test('the flat list claims no order at all', () => {
  assert.strictEqual(ids(orderRows(M, 'none', true)), 'm1,m2,m3');
});

test('a row with no usable time is never given a position among the dated', () => {
  const rows = [msg('m1', '2026-09-01T10:00:00Z'), msg('mx', ''),
                msg('m2', '2026-09-02T10:00:00Z')];
  assert.strictEqual(ids(orderRows(rows, 'project', true)), 'm2,m1,mx');
  assert.strictEqual(ids(orderRows(rows, 'oldest', true)), 'm1,m2,mx');
});

// A reply's verdict is not an item's to release: the message log is append-only,
// so a scan of the work records is no evidence that his reply did not land.
test('a scan never re-offers a reply whose delivery was unconfirmed', () => {
  const verdicts = { 'msg/m1': { outcome: 'unknown', detail: 'x', sent: 0 } };
  const kept = releaseVerdicts(verdicts, { items: [] });
  assert.deepStrictEqual(kept, verdicts,
    'a message verdict was released by a scan that knows nothing about it');
});

// --- where a reply is about to go ---------------------------------------------
// A task collects several messages over its life, so only the message the
// recorder marked as a question may be answered, and only against the decision
// it named. Everything else is a note.
const hold = { home: 'main', id: 't1', source: 'hold', key: '', title: 'Blue or green?' };
const stopped = { home: 'main', id: 't1', source: 'status', key: 'k1', title: 'Which shape?' };

test('a reply to a question answers that question and nothing else', () => {
  assert.deepStrictEqual(
    replyTarget({ question: true, task: 't1' }, [hold]),
    { kind: 'answer', item: hold });
  assert.deepStrictEqual(
    replyTarget({ question: true, task: 't1', question_key: 'k1' }, [stopped, hold]),
    { kind: 'answer', item: stopped });
});

test('a reply to a message that is not a question is a note', () => {
  assert.strictEqual(replyTarget({ task: 't1' }, [hold]).kind, 'note',
    'a message nobody recorded as a question was made answerable');
  assert.strictEqual(replyTarget({ question: true, task: 't1', question_key: 'other' },
                                 [stopped]).kind, 'note',
    'a question was answered against a decision it never named');
  assert.strictEqual(replyTarget({ question: true, task: 't1' }, []).kind, 'note',
    'a settled question still claimed the answer route');
});

test('a question is never answered against another home', () => {
  assert.strictEqual(
    replyTarget({ question: true, task: 't1' },
                [Object.assign({}, hold, { home: 'mate' })]).kind, 'note');
});

process.exit(failures ? 1 : 0);
