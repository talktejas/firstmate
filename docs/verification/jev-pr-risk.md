# Pull request risk level verification

Audience: maintainer verification.

This record supports the key-gated pull request risk level owned by [`../configuration.md`](../configuration.md) ("Pull request risk level").
It records only facts that must be re-established when the typesafe.ai model, its API, or the three questions in `bin/fm-pr-risk-lib.sh` change.
The API shape itself is recorded in [`dispatch-resolve.md`](dispatch-resolve.md).

## Live answers to the shipped questions

Run 2026-10-06 at commit `1f146bb` against `https://api.typesafe.ai`, model `jev-latest` answering as `jev-1.13.0`, timeout 5 s, floor 0.6.
Each row is one real `bin/fm-pr-check.sh <task> <url>` registration in a temporary home that was deleted afterwards, with the real `bin/fm-review-diff.sh`, git, and curl, and the key read from that home's `.env` by `fm_jev_key_load`.
The home's `config/jev-code-projects` listed the fixture project `alpha` beside two comment lines, a blank line, and another project name.
Every registration exited 0, recorded `pr=`, armed the merge poll, and printed its `risk:` line after the `armed:` line.

Two things on `PATH` were not the plain tools, and neither changed a request or an answer:

- `curl` was a pass-through that ran the real curl with the same arguments and descriptors against the real endpoint and copied each answer's choice and confidence into a log.
- `gh` answered the title and description from a file for the invented changes, which have no pull request, and ran the real `gh pr view` for the real ones.

### Invented changes

Each is a small fixture project change with an invented title and description:

- `rename`: one source file, a function and its locals renamed, described as a pure rename.
- `tested`: one source file gains a 10% discount above a total of 500, described as exactly that, plus a test file asserting it.
- `logic`: the same discount with no test file.
- `mismatch`: the same diff as `logic`, titled "Fix typo in README".
- `purge`: a nightly job that deletes stored files and their rows older than 30 days, with a test file, on a path no fact matches.
- `migration`: a new `db/migrations/*.sql` file that drops a column and a table, described as exactly that.

The set was run three times; each answer is shown as choice and confidence for runs 1, 2, and 3.

| Change | Line printed | `untested` | `mismatch` | `irreversible` |
| --- | --- | --- | --- | --- |
| rename | `risk: low - no risk fact found and all three questions answered no` | no 0.99, 0.99, 0.99 | no 0.96, 0.96, 0.96 | no 1.0, 1.0, 1.0 |
| tested | `risk: low - no risk fact found and all three questions answered no` | settled in code | no 0.99, 0.99, 0.98 | no 1.0, 1.0, 1.0 |
| logic | `risk: medium - behaviour changed with no test` | yes 1.0, 1.0, 1.0 | no 0.99, 0.99, 0.99 | no 1.0, 1.0, 1.0 |
| mismatch | `risk: medium - behaviour changed with no test, description does not match the change` | yes 1.0, 0.99, 1.0 | yes 1.0, 1.0, 1.0 | no 0.99, 0.99, 0.99 |
| purge | `risk: high - something hard to undo; unanswered: mismatch (Jev unsure)` | settled in code | no 0.44, 0.42, 0.5 (below the floor, not counted) | yes 0.87, 0.84, 0.84 |
| migration | `risk: high - database migration, behaviour changed with no test, something hard to undo` | yes 0.71, 0.68, 0.71 | no 0.99, 0.99, 0.99 | yes 0.84, 0.87, 0.83 |

Every printed line was identical in all three runs.
The lowest confidence on a counted answer was 0.68, on `untested` for `migration` in run 2, where the path fact had already set the level to high.
The lowest confidence on an answer that alone decided a level was 0.84, on `irreversible` for `purge`.
`purge` is a live case of an answer below the floor: the level a counted yes set is kept and the uncounted question is named.

### Real changes from this repository

Each is a merged pull request of this repository, rebuilt as a fixture project named `alpha` whose default branch is the commit's parent tree and whose task branch is the commit's tree, so the change read is the merged diff.
The title and description were read from the real pull request by the real `gh`.
Each was run once.

| Pull request | Line printed | `untested` | `mismatch` | `irreversible` |
| --- | --- | --- | --- | --- |
| #37 (`7eec922`), 4 files, 56 lines, tests changed | `risk: low - no risk fact found and all three questions answered no` | settled in code | no 0.91 | no 0.99 |
| #35 (`0024c57`), 2 files, 81 lines, tests changed | `risk: low - no risk fact found and all three questions answered no` | settled in code | no 0.95 | no 0.94 |
| #34 (`9d1590f`), 2 files, 124 lines, tests changed | `risk: not rated - no risk fact found; unanswered: mismatch (Jev unsure)` | settled in code | no 0.4 (below the floor, not counted) | no 1.0 |
| #11 (`e80a29a`), 3 files, 16 lines, no test | `risk: medium - behaviour changed with no test` | yes 0.98 | no 0.98 | no 1.0 |

#34 is a live case of `not rated` instead of `low`: Jev was unsure whether a long description matched a test and workflow change, nothing else raised the level, and the line says so.

### Unlisted project with the real key

In the same home with `config/jev-code-projects` holding only `# alpha` and `alpha-web`, four registrations made no request and no description read:

| Change | Line printed |
| --- | --- |
| `docs/authors.md` | `risk: not rated - no risk fact found; unanswered: mismatch (project not listed), irreversible (project not listed)` |
| `my schema.sql` | `risk: high - database migration; unanswered: untested (project not listed), mismatch (project not listed), irreversible (project not listed)` |
| `café.sql`, which git prints quoted | `risk: high - database migration; unanswered: untested (project not listed), mismatch (project not listed), irreversible (project not listed)` |
| a logic change beside `src/my cart.test.js` | `risk: not rated - no risk fact found; unanswered: mismatch (project not listed), irreversible (project not listed)` |

`docs/authors.md` is not read as login, and the test file with a space settles `untested` in code.

### Not driven live

These rest on `tests/fm-pr-risk.test.sh` alone, because the live service cannot be made to produce them on demand or no such project exists here:

- a choice outside yes and no, a reply that is not JSON, HTTP 500, and a timeout;
- an answer below the floor on a chosen input (the two live cases above were not forced);
- an unreadable forge description;
- a GitLab merge request, because no GitLab project exists here.

## Offline behavior

`tests/fm-pr-risk.test.sh` proves the rest without the network.
Both layers read the change through the real `bin/fm-review-diff.sh` from a fixture project and task worktree.
With `fm_jev_choice` stubbed at the library boundary it proves each path, deletion, and size fact sets its level in code, a path git prints quoted is still classified, a changed test file or a documentation-only change settles `untested` without a call, a counted yes only raises, and an answer below the floor, a choice outside the fixed list, a failed call, an unreadable description, and an unreadable change each print `risk: not rated` or leave a level the facts set untouched.
It proves the per-project list the same way: with `config/jev-code-projects` absent, empty, or naming the project only on a `#` line the model is asked nothing, the forge is not read for a description, a level the facts set is kept with the unanswered questions named, and nothing else is rated; a project listed beside comment lines is asked.
With the real library, a fake `curl`, and the real `bin/fm-pr-check.sh` it proves the output is exactly the registration with the key absent, the level is printed beside it with the key present, a timeout still records the pull request and arms its poll, an unlisted project registers with no request made, and the key reaches `curl` on a file descriptor and no child environment or argv.
`tests/fm-pr-merge.test.sh` (`test_merge_registration_never_rates_risk`) proves a merge with the key present re-registers the pull request and prints no `risk:` line.

```console
$ bash tests/fm-pr-risk.test.sh | tail -1
# all fm-pr-risk tests passed
```
