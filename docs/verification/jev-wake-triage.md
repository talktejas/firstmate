# Routine-wake triage verification

Audience: maintainer verification.

This record supports the key-gated routine-wake triage contract owned by [`../configuration.md`](../configuration.md) ("Routine-wake triage").
It records only facts that must be re-established when the typesafe.ai model, its API, or the triage question in `bin/fm-watch.sh` changes.
The API shape itself is recorded in [`dispatch-resolve.md`](dispatch-resolve.md).

## Live answers to the shipped question

Run 2026-10-06 against `https://api.typesafe.ai`, model `jev-latest` answering as `jev-1.13.0`, timeout 5 s, floor 0.6.
Each row is one real call made through the watcher's own `jev_triage_pause_routine`, sourced from `bin/fm-watch.sh` at commit 3ac9b3d with its question text and criteria unmodified, with the key read from a home `.env` by `fm_jev_key_load` and a synthetic wake as evidence.
Every `declared-pause-recheck` row carried the pull request note `open; no blocker reported`, as the class always does, from a pull-request read that printed `CHECKS: none reported yet`, and the reason `stale: fm:fm-sample (paused 14520s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)`.
The agent column is the `worker_agent` value the row carried: `exited` for an endpoint whose agent state read `dead`, `running` for `alive`.

The newest evidence of each row:

- `merge-word`: `paused: pull request <url> open, waiting for the captain's merge word`.
- `merge`: `paused: PR is open and green, waiting for the merge`.
- `ci`: `paused: CI is running on the pull request, about 25 minutes, resuming on my own when it finishes`.
- `release`: `paused: waiting on the upstream release, then I will rebase and finish the follow-up`.
- `told-which`: `paused: two ways to fix the schema, waiting to be told which`.
- `three-failures`: `paused: the test suite failed three times, stopping here`.
- `credential-rejected`: `paused: cannot push the follow-up commit, the credential was rejected`.
- `pr-open-but-asks`: `paused: PR is open, waiting for you to decide whether the migration should also ship in this PR`.
- `review-question`: `paused: a reviewer asked on the pull request whether the old flag should keep working, waiting for an answer before I change anything`.
- `review-wait`: `paused: PR is open, waiting for the captain to review the approach before I continue`.

The set was run three times; the table shows run 1.

| Class | Row | Agent | Expected | Verdict | Choice | Confidence | `routine` probability |
| --- | --- | --- | --- | --- | --- | --- | --- |
| declared-pause-recheck | merge-word | exited | absorb | absorb | routine | 0.97 | 0.99 |
| declared-pause-recheck | merge-word | running | absorb | absorb | routine | 0.98 | 0.99 |
| declared-pause-recheck | merge | exited | absorb | absorb | routine | 0.99 | 0.99 |
| declared-pause-recheck | merge | running | absorb | absorb | routine | 0.97 | 0.99 |
| declared-pause-recheck | ci | exited | deliver | deliver | routine | 0.12 | 0.56 |
| declared-pause-recheck | ci | running | absorb | absorb | routine | 0.92 | 0.96 |
| declared-pause-recheck | release | exited | deliver | deliver | needs_firstmate | 0.58 | 0.21 |
| declared-pause-recheck | release | running | absorb | absorb | routine | 0.89 | 0.95 |
| declared-pause-recheck | told-which | exited | deliver | deliver | needs_firstmate | 1.0 | 0.0 |
| declared-pause-recheck | told-which | running | deliver | deliver | needs_firstmate | 1.0 | 0.0 |
| declared-pause-recheck | three-failures | exited | deliver | deliver | needs_firstmate | 1.0 | 0.0 |
| declared-pause-recheck | three-failures | running | deliver | deliver | needs_firstmate | 1.0 | 0.0 |
| declared-pause-recheck | credential-rejected | running | deliver | deliver | needs_firstmate | 1.0 | 0.0 |
| declared-pause-recheck | pr-open-but-asks | exited | deliver | deliver | needs_firstmate | 0.98 | 0.01 |
| declared-pause-recheck | pr-open-but-asks | running | deliver | deliver | needs_firstmate | 0.97 | 0.02 |
| declared-pause-recheck | review-question | running | deliver | deliver | needs_firstmate | 1.0 | 0.0 |
| declared-pause-recheck | review-wait | running | deliver | deliver | needs_firstmate | 0.98 | 0.01 |

Every row answered as `jev-1.13.0`.
No verdict changed in any of the three runs, and every row matched its expectation.
The narrowest delivery was `ci` with an exited agent, which the model kept choosing as `routine` at a confidence of 0.10 to 0.12 and a `routine` probability of 0.56, so only the floor delivered it.

## The rejected wording

The wording it replaced contained the sentence "Every status event listed in `wake` has already been delivered to the supervisor, so judge only whether anything has changed since."
It was measured before the class was narrowed to tasks with a recorded pull request, in one run over an earlier row set in which only some rows carried a pull request note, and it is kept only as the recorded reason for the wording.
Acceptance: a recheck of a wait on an automatic external event may come back routine; a recheck of a wait whose own text shows the worker waiting on a person or on the supervisor to choose or unblock something, or stopped after failures, must be delivered.
That wording failed the acceptance: it absorbed six rows that must be delivered.
In that row set `credential-rejected` read `paused: cannot push, the credential was rejected`, `report-awaiting-review` read `paused: finished the report, waiting for review`, and of the rows below only `pr-open-but-asks` carried the pull request note.

| Row | Expected | Verdict | Choice | Confidence | Probabilities | Latency |
| --- | --- | --- | --- | --- | --- | --- |
| told-which | deliver | absorb | routine | 0.64 | needs_firstmate=0.18 routine=0.82 | 308 ms |
| three-failures | deliver | absorb | routine | 0.72 | needs_firstmate=0.14 routine=0.86 | 822 ms |
| credential-rejected | deliver | absorb | routine | 0.75 | needs_firstmate=0.13 routine=0.87 | 309 ms |
| report-awaiting-review | deliver | absorb | routine | 0.94 | routine=0.97 needs_firstmate=0.03 | 354 ms |
| pr-open-but-asks | deliver | absorb | routine | 0.86 | needs_firstmate=0.07 routine=0.93 | 301 ms |
| gh-401 | deliver | absorb | routine | 0.69 | needs_firstmate=0.15 routine=0.85 | 363 ms |

In that run `told-which-short` (routine, confidence 0.3) and `three-failures-short` (routine, confidence 0.54) were delivered only because the confidence fell below the floor.

The wording shipped before the current one read a wait on a named person's merge word as a wait on a person.
Measured 2026-10-06 over three runs, it answered the `merge-word` row `needs_firstmate` at a confidence of 0.62 to 0.69 with a running agent, so the commonest wait the class exists for was always delivered.

## Offline behavior

`tests/fm-jev-wake-triage.test.sh` proves the rest without the network.
With `fm_jev_choice` stubbed at the library boundary it proves each eligible class asks once and absorbs on a routine answer, each never-eligible case, a worker whose agent has exited beside an open pull request in a repository with no checks is offered with that fact in the evidence, a paused task with no recorded pull request at each of the three pause sites, and each pull request that is no longer open, has a blocker, or cannot be read is delivered without asking, every fallback delivers the wake as before, and the consecutive-absorb bound delivers unasked.
With the real library, a fake `curl`, and a real watcher process it proves a new `paused:` status signal is delivered without any call, a later stale recheck of a task with an open recorded pull request is absorbed, logged, and never queued, a bare turn-end from a paused worker is delivered without any call, a paused task with no recorded pull request is still delivered without any call while real heartbeats are being absorbed, a `needs_firstmate` answer and a timed-out call deliver the wake, the feature is off without the key, and the key reaches `curl` only on the file-descriptor header and no child environment, argv, or log.

```console
$ bash tests/fm-jev-wake-triage.test.sh | tail -1
# all fm-jev-wake-triage tests passed
```
