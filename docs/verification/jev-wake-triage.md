# Routine-wake triage verification

Audience: maintainer verification.

This record supports the key-gated routine-wake triage contract owned by [`../configuration.md`](../configuration.md) ("Routine-wake triage").
It records only facts that must be re-established when the typesafe.ai model, its API, or the triage question in `bin/fm-watch.sh` changes.
The API shape itself is recorded in [`dispatch-resolve.md`](dispatch-resolve.md).

## Live answers to the shipped question

Run 2026-10-05 against `https://api.typesafe.ai`, model `jev-latest` answering as `jev-1.13.0`, timeout 5 s, floor 0.6.
Each row is one real call made through the watcher's own `jev_triage_routine`, sourced from `bin/fm-watch.sh`, with the key read from a home `.env` by `fm_jev_key_load` and a synthetic wake as evidence.
The table was measured with exactly the shipped `JEV_TRIAGE_INSTRUCTIONS` and `JEV_TRIAGE_CRITERIA` text, put in place of the two constants and called through that function before the text was committed.
The evidence shape, the reason strings, the floor, and the rule that the confidence and the `routine` probability must both reach the floor were the shipped ones.

Acceptance: a recheck of a wait on an automatic external event may come back routine; a recheck of a wait whose own text shows the worker waiting on a person or on the supervisor to choose or unblock something, or stopped after failures, must be delivered.

Rows whose label ends in `-short` used the plain reason `stale: fm:fm-sample`.
The other `declared-pause-recheck` rows used the long cadence reason `stale: fm:fm-sample (paused 14520s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)`.

The newest evidence of each row:

- `pr-open-merge-word` and `pr-open-merge-word-short`: `paused: PR is open and green, waiting for the merge`, pull request note `open; no blocker reported`.
- `ci-running`: `paused: CI is running on the pull request, about 25 minutes, resuming on my own when it finishes`, pull request note `open; no blocker reported`.
- `rate-limit`: `paused: provider rate limit hit, resuming on my own when it resets until 2026-10-05T10:00Z`.
- `upstream-release`: `paused: waiting for the upstream 4.2 release to be published, nothing to do until then`.
- `told-which` and `told-which-short`: `paused: two ways to fix the schema, waiting to be told which`.
- `three-failures` and `three-failures-short`: `paused: the test suite failed three times, stopping here`.
- `credential-rejected`: `paused: cannot push, the credential was rejected`.
- `report-awaiting-review`: `paused: finished the report, waiting for review`.
- `pr-open-but-asks`: `paused: PR is open, waiting for you to decide whether the migration should also ship in this PR`, pull request note `open; no blocker reported`.
- `gh-timeout`: one diagnostic, `gh pr view timed out after 30s`.
- `gh-401`: one diagnostic, `gh pr view failed: HTTP 401: Bad credentials`.

The set was run three times; the table shows run 1.

| Class | Row | Expected | Verdict | Choice | Confidence | Probabilities | Latency |
| --- | --- | --- | --- | --- | --- | --- | --- |
| declared-pause-recheck | pr-open-merge-word | absorb | absorb | routine | 0.83 | needs_firstmate=0.08 routine=0.92 | 310 ms |
| declared-pause-recheck | pr-open-merge-word-short | absorb | absorb | routine | 0.94 | routine=0.97 needs_firstmate=0.03 | 309 ms |
| declared-pause-recheck | ci-running | absorb | absorb | routine | 0.92 | needs_firstmate=0.04 routine=0.96 | 350 ms |
| declared-pause-recheck | rate-limit | absorb | absorb | routine | 0.93 | routine=0.97 needs_firstmate=0.03 | 321 ms |
| declared-pause-recheck | upstream-release | absorb | absorb | routine | 0.98 | needs_firstmate=0.01 routine=0.99 | 300 ms |
| declared-pause-recheck | told-which | deliver | deliver | needs_firstmate | 1.0 | needs_firstmate=1.0 routine=0.0 | 349 ms |
| declared-pause-recheck | told-which-short | deliver | deliver | needs_firstmate | 1.0 | routine=0.0 needs_firstmate=1.0 | 330 ms |
| declared-pause-recheck | three-failures | deliver | deliver | needs_firstmate | 1.0 | routine=0.0 needs_firstmate=1.0 | 363 ms |
| declared-pause-recheck | three-failures-short | deliver | deliver | needs_firstmate | 1.0 | needs_firstmate=1.0 routine=0.0 | 298 ms |
| declared-pause-recheck | credential-rejected | deliver | deliver | needs_firstmate | 1.0 | needs_firstmate=1.0 routine=0.0 | 352 ms |
| declared-pause-recheck | report-awaiting-review | deliver | deliver | needs_firstmate | 0.99 | routine=0.0 needs_firstmate=1.0 | 332 ms |
| declared-pause-recheck | pr-open-but-asks | deliver | deliver | needs_firstmate | 0.99 | needs_firstmate=1.0 routine=0.0 | 340 ms |
| contributions-observation-timeout | gh-timeout | absorb | absorb | routine | 0.92 | routine=0.96 needs_firstmate=0.04 | 311 ms |
| contributions-observation-timeout | gh-401 | deliver | deliver | needs_firstmate | 0.87 | needs_firstmate=0.94 routine=0.06 | 352 ms |

Every row answered as `jev-1.13.0`.
No verdict changed in any of the three runs.
The lowest absorbed confidence was 0.83, on `pr-open-merge-word`.
The lowest delivered `needs_firstmate` confidence was 0.76, on `gh-401` in run 2.
Latency was 289 to 485 ms.
The `gh-401` row is also refused in code before any call, because the contributions class admits only diagnostics that say a read timed out.

## The rejected wording

The wording it replaced contained the sentence "Every status event listed in `wake` has already been delivered to the supervisor, so judge only whether anything has changed since."
It was run once over the same rows, with the same reasons and evidence, and failed the acceptance: it absorbed six rows that must be delivered.

| Row | Expected | Verdict | Choice | Confidence | Probabilities | Latency |
| --- | --- | --- | --- | --- | --- | --- |
| told-which | deliver | absorb | routine | 0.64 | needs_firstmate=0.18 routine=0.82 | 308 ms |
| three-failures | deliver | absorb | routine | 0.72 | needs_firstmate=0.14 routine=0.86 | 822 ms |
| credential-rejected | deliver | absorb | routine | 0.75 | needs_firstmate=0.13 routine=0.87 | 309 ms |
| report-awaiting-review | deliver | absorb | routine | 0.94 | routine=0.97 needs_firstmate=0.03 | 354 ms |
| pr-open-but-asks | deliver | absorb | routine | 0.86 | needs_firstmate=0.07 routine=0.93 | 301 ms |
| gh-401 | deliver | absorb | routine | 0.69 | needs_firstmate=0.15 routine=0.85 | 363 ms |

In that run `told-which-short` (routine, confidence 0.3) and `three-failures-short` (routine, confidence 0.54) were delivered only because the confidence fell below the floor, and the six rows expected to be absorbed were absorbed.

## Offline behavior

`tests/fm-jev-wake-triage.test.sh` proves the rest without the network.
With `fm_jev_choice` stubbed at the library boundary it proves each eligible class asks once and absorbs on a routine answer, each never-eligible case, a wait whose declaration was not yet delivered, and each deterministic pull-request outcome is delivered without asking, every fallback delivers the wake as before, and the consecutive-absorb bound delivers unasked.
With the real library, a fake `curl`, and a real watcher process it proves a first `paused:` declaration is delivered without any call and only its later recheck is absorbed, logged, and never queued, a bare turn-end from an already paused, already delivered worker is delivered without any call, a `needs_firstmate` answer and a timed-out call deliver the wake, the feature is off without the key, and the key reaches `curl` only on the file-descriptor header and no child environment, argv, or log.

```console
$ bash tests/fm-jev-wake-triage.test.sh | tail -1
# all fm-jev-wake-triage tests passed
```
