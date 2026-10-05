# Routine-wake triage verification

Audience: maintainer verification.

This record supports the opt-in routine-wake triage contract owned by [`../configuration.md`](../configuration.md) ("Routine-wake triage").
It records only facts that must be re-established when the typesafe.ai model, its API, or the triage question in `bin/fm-watch.sh` changes.
The API shape itself is recorded in [`dispatch-resolve.md`](dispatch-resolve.md).

## Live answers to the shipped question

Run 2026-10-05 against `https://api.typesafe.ai`, model `jev-latest` answering as `jev-1.13.0`, timeout 5 s, floor 0.6.
Each row is one real call made through the watcher's own `jev_triage_routine`, sourced from `bin/fm-watch.sh`, with the key read from a home `.env` by `fm_jev_key_load` and a synthetic wake as evidence.
The whole set was run twice; the second run's confidences differed from the first by at most 0.07 and no verdict changed.

| Class | Newest evidence | Expected | Choice | Confidence | `routine` probability | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| declared-pause-recheck | `paused:` PR is open and green, waiting for the merge; pull request open | absorb | routine | 0.97 | 0.99 | absorbed |
| paused-status-signal | `paused:` provider rate limit hit, resuming on its own at a stated time | absorb | routine | 0.93 | 0.96 | absorbed |
| paused-turn-end | `paused:` waiting for an upstream release, nothing to do until then | absorb | routine | 0.98 | 0.99 | absorbed |
| contributions-observation-timeout | one `gh pr view timed out after 30s` diagnostic | absorb | routine | 0.97 | 0.99 | absorbed |
| paused-status-signal | `paused:` two ways to fix the schema, waiting to be told which | deliver | needs_firstmate | 0.91 | 0.05 | delivered |
| paused-status-signal | `paused:` cannot push, the credential was rejected | deliver | needs_firstmate | 0.86 | 0.07 | delivered |
| declared-pause-recheck | `paused:` the test suite failed three times, stopping here | deliver | routine | 0.22 | 0.61 | delivered |
| paused-turn-end | `paused:` finished the report, waiting for review | deliver | routine | 0.21 | 0.60 | delivered |
| contributions-observation-timeout | one `gh pr view failed: HTTP 401` diagnostic | deliver | routine | 0.48 | 0.74 | delivered |

Latency was 283 to 454 ms per call across both runs, and no call errored.
No wake that should have reached firstmate was absorbed.
The last three rows are why the watcher requires the answer's confidence and its `routine` probability both at or above the floor: the model named `routine` with a probability of 0.60 to 0.77 and a confidence of 0.21 to 0.53, so the probability alone would have absorbed them.
The HTTP 401 row is the closest any counter-example came to the floor, and it is refused in code before any call, because the contributions class admits only diagnostics that say a read timed out.
An earlier wording of the question, without the sentence saying a reminder to confirm a declared wait is not by itself a reason to interrupt, answered the open pull-request recheck at 0.55 confidence and delivered it, so that sentence is load-bearing for the first row.

## Offline behavior

`tests/fm-jev-wake-triage.test.sh` proves the rest without the network.
With `fm_jev_choice` stubbed at the library boundary it proves each eligible class asks once and absorbs on a routine answer, each never-eligible class and each deterministic pull-request outcome is delivered without asking, every fallback delivers the wake as before, and the consecutive-absorb bound delivers unasked.
With the real library, a fake `curl`, and a real watcher process it proves an absorbed wake is logged and never queued, a `needs_firstmate` answer and a timed-out call deliver the wake, the feature is off unless both the flag and the key are present, and the key reaches `curl` only on the file-descriptor header and no child environment, argv, or log.

```console
$ bash tests/fm-jev-wake-triage.test.sh | tail -1
# all fm-jev-wake-triage tests passed
```
