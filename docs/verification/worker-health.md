# Worker health verification

Audience: maintainer verification.

This record supports the opt-in worker health line owned by [`../configuration.md`](../configuration.md) ("Worker health").
It records only facts that must be re-established when the typesafe.ai model, its API, or the instruction and criteria text in `bin/fm-worker-health.sh` change.
The API shape itself is recorded in [`dispatch-resolve.md`](dispatch-resolve.md).

## Live answers

Run 2026-10-06 against `https://api.typesafe.ai`, model `jev-latest`, timeout 5 s, floor 0.6.
Each run is one real request made by `health_main` of `bin/fm-worker-health.sh` with its instruction and criteria text unmodified and the key loaded by `bin/fm-jev-lib.sh` itself.
The task records were synthetic, in a fixture state directory, and the deterministic read was a fixed line of the shape `bin/fm-crew-state.sh` prints, because no live worker was involved.
Each task was written to be a clear case of one kind.

| Deterministic read | Newest report, and what else was true | Expected | Choice | Confidence | Printed |
| --- | --- | --- | --- | --- | --- |
| working, `pane`, harness busy | "fix implemented, running the test suite" 4 minutes ago, activity 1 minute ago | working | working | 0.98 | health line |
| working, `status-log` | "setup done" 190 minutes ago, nothing since | stuck | stuck | 0.61 | health line |
| working, `status-log` | "bug reproduced" 130 minutes ago, one steering message unacknowledged for 95 minutes | stuck | stuck | 0.9 | health line |
| blocked, `status-log` | a `needs-decision` between two named options 20 minutes ago | waiting | waiting | 0.91 | health line |
| paused, `status-log` | "rate limit reached, resets within the hour" 15 minutes ago | waiting | waiting | 0.98 | health line |
| done, `status-log` | a pull request reported with checks green 12 minutes ago | finished | finished | 0.98 | health line |
| blocked, `status-log` | "the same migration test fails a second time after the retry" 35 minutes ago | stuck | stuck | 1.0 | health line |

All seven matched, and each request finished in 317 to 372 ms of wall time.
The weakest answer is the one the feature exists for: a worker that went quiet after a `working` report cleared the floor by 0.01, with the rest of the probability on `finished` and `working`.
An earlier wording of the question, which did not say that a `status-log` read means the worker's tool is idle, left that case at 0.46 for `working` and the decision case at 0.58, so both printed no health line; the current wording states that fact.

This is seven tasks written to be clear, run once, not a measured accuracy on real workers.
That is the reason the line stays advice only and the recovery playbook's own reading still decides.

## Offline behavior

`tests/fm-worker-health.test.sh` proves the rest without the network; none of the following was exercised live.
With the deterministic read fixed and `fm_jev_choice` stubbed at the library boundary it proves that a home without the key prints the crew-state line alone, that a read from a validation run, a gone, unreachable, or remote endpoint, and a secondmate are never asked about, the health line for each of the four choices at the floor, that a low-confidence answer and a failed call print no health line, and that the evidence holds only the read, the kind, the newest six status lines with a long line keeping its head and its end, the ages, and the unacknowledged-message count, never a message's text.
With the real library and a fake `curl` it proves the request shape, that an answer outside the four choices prints no health line, that a status line holding a credential is withheld, that the key reaches `curl` only on the file-descriptor header and no child environment, argv, or output, and that the task's status record is not written.
The real executable is run on a task with no record, where the real `bin/fm-crew-state.sh` decides alone.

```console
$ bash tests/fm-worker-health.test.sh | tail -1
# all fm-worker-health tests passed
```
