# Review finding sort verification

Audience: maintainer verification.

This record supports the opt-in review finding sort owned by [`../configuration.md`](../configuration.md) ("Review finding sort").
It records only facts that must be re-established when the typesafe.ai model, its API, or the instruction and criteria text in `bin/fm-finding-sort.sh` change.
The API shape itself is recorded in [`dispatch-resolve.md`](dispatch-resolve.md).

## Live sorts

Run 2026-10-06 against `https://api.typesafe.ai`, model `jev-latest`, timeout 5 s, floor 0.6.
Each run is one real request made by `bin/fm-finding-sort.sh <task-id>` with its instruction and criteria text unmodified, in a fixture home whose `config/jev-code-projects` lists the task's project, with the key passed in the environment.
The gate was synthetic: an intent of "Add a button on the members page that exports the member list as a CSV file with name, email and join date." and one findings file of eight findings, each written to be a clear case of one kind.
The set was run three times; the table shows run 1.

| Finding | Expected | Choice | Confidence | Printed |
| --- | --- | --- | --- | --- |
| The CSV has no header row | inside-task | inside-task | 0.99 | settle |
| The join date is read from the wrong column | inside-task | inside-task | 1.0 | settle |
| There is no test for the new export | inside-task | inside-task | 0.91 | settle |
| Rename `$tmp` to `$rows` | style-only | style-only | 1.0 | settle |
| A comment misspells a word | style-only | style-only | 1.0 | settle |
| Add an audit log table for exports | grows-task | grows-task | 1.0 | by hand |
| Add a rate limiter and a background job framework | grows-task | grows-task | 1.0 | by hand |
| Drop an unused table and delete its stored files | destructive | destructive | 0.98 | by hand |

All three runs printed the same eight lines and matched every expectation.
The weakest answer was the missing-test finding, at 0.90 to 0.93 across the runs.
One request carried all eight questions and each run finished in 443 to 524 ms of wall time.

This is eight findings written to be clear, not a measured accuracy on real review findings, where a finding often sits between two kinds.
That is the reason the sort stays advice only and firstmate reads every finding itself.

## Offline behavior

`tests/fm-finding-sort.test.sh` proves the rest without the network; none of the following was exercised live.
With `fm_jev_choices` stubbed at the library boundary it proves that a home without the key and a project outside `config/jev-code-projects` are never asked about, that only the newest gate line is sorted, the `settle` and `by hand` lines, that the confidence floor alone decides a clear case, that every named id is asked about, a finding with no usable answer, a failed call, that the state holds only the intent and the whole findings file, and that a file outside the task's data directory, in a subdirectory, symlinked, missing, or over the size bound, and a brief with no intent are all left by hand without a call.
With the real library and a fake `curl` it proves the request shape, that a malformed answer to one finding leaves only that finding by hand, that the key reaches `curl` only on the file-descriptor header and no child environment, argv, or output, and that the task's status record is not written.

```console
$ bash tests/fm-finding-sort.test.sh | tail -1
# all fm-finding-sort tests passed
```
