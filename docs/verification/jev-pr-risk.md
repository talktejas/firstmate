# Pull request risk level verification

Audience: maintainer verification.

This record supports the key-gated pull request risk level owned by [`../configuration.md`](../configuration.md) ("Pull request risk level").
It records only facts that must be re-established when the typesafe.ai model, its API, or the three questions in `bin/fm-pr-risk-lib.sh` change.
The API shape itself is recorded in [`dispatch-resolve.md`](dispatch-resolve.md).

## Live answers to the shipped questions

Run 2026-10-06 against `https://api.typesafe.ai`, model `jev-latest` answering as `jev-1.13.0`, timeout 5 s, floor 0.6.
Each row is one real `fm_pr_risk` call from `bin/fm-pr-risk-lib.sh` with its questions and criteria unmodified and the key read from a home `.env` by `fm_jev_key_load`.
The change and the title and description were synthetic, supplied through `FM_REVIEW_DIFF_BIN` and a stand-in `gh`, so the facts, the request, and the answers are the shipped path and only the pull request is invented.

The six changes:

- `rename`: one source file, a function and its locals renamed, described as a pure rename.
- `logic`: one source file gains a 10% discount above a total of 500, described as exactly that, with no test file.
- `mismatch`: the same diff as `logic`, titled "Fix typo in README".
- `tested`: the `logic` change plus a test file asserting the discount.
- `migration`: a new `db/migrations/*.sql` file that drops a column and a table, described as exactly that.
- `purge`: a nightly job that deletes stored files and their rows older than 30 days, with a test file, on a path no fact matches.

The set was run three times; the table shows run 1, with each answer as choice and confidence.

| Change | Expected | Line printed | `untested` | `mismatch` | `irreversible` |
| --- | --- | --- | --- | --- | --- |
| rename | low | `risk: low - no risk fact found and all three questions answered no` | no 0.79 | no 1.0 | no 0.95 |
| logic | medium | `risk: medium - behaviour changed with no test` | yes 1.0 | no 0.97 | no 0.99 |
| mismatch | medium | `risk: medium - behaviour changed with no test, description does not match the change` | yes 0.99 | yes 1.0 | no 0.99 |
| tested | low | `risk: low - no risk fact found and all three questions answered no` | settled in code | no 0.98 | no 1.0 |
| migration | high | `risk: high - database migration, behaviour changed with no test, something hard to undo` | yes 0.79 | no 0.97 | yes 0.77 |
| purge | high | `risk: high - something hard to undo` | settled in code | no 0.96 | yes 0.96 |

Every printed line was identical in all three runs and matched its expectation.
The lowest confidence on a counted answer was 0.70, on `irreversible` for `migration` in run 2, where the path fact had already set the level to high.
The lowest confidence on an answer that alone decided a level was 0.79, on `untested` for `rename`.
Latency was 307 to 408 ms per call.

## Offline behavior

`tests/fm-pr-risk.test.sh` proves the rest without the network.
With `fm_jev_choice` stubbed at the library boundary it proves each path, deletion, and size fact sets its level in code, a changed test file or a documentation-only change settles `untested` without a call, a counted yes only raises, and an answer below the floor, a choice outside the fixed list, a failed call, an unreadable description, and an unreadable change each print `risk: not rated` or leave a level the facts set untouched.
With the real library, a fake `curl`, and the real `bin/fm-pr-check.sh` it proves the output is exactly the registration with the key absent, the level is printed beside it with the key present, a timeout still records the pull request and arms its poll, a second mate's ready line carries a rated level, and the key reaches `curl` on a file descriptor and no child environment or argv.

```console
$ bash tests/fm-pr-risk.test.sh | tail -1
# all fm-pr-risk tests passed
```
