# Failed check sort verification

Audience: maintainer verification.

This record supports the key-gated failed check sort owned by [`../configuration.md`](../configuration.md) ("Failed check sort").
It records only facts that must be re-established when the typesafe.ai model, GitHub's check-run or job-log reads, or the rules and question in `bin/fm-check-sort-lib.sh` change.
The API shape itself is recorded in [`dispatch-resolve.md`](dispatch-resolve.md).

## Live answers on real failed checks

Run 2026-10-06 against `https://api.typesafe.ai`, model `jev-latest` answering as `jev-1.13.0`, timeout 5 s, with gh 2.100.0.
Each row is `fm_check_sort` from `bin/fm-check-sort-lib.sh` run three times on one real failed check of `talktejas/firstmate`, with its rules, question, and criteria unmodified, the key read from the environment by `bin/fm-jev-lib.sh`, and a fixture home whose `config/jev-code-projects` lists `firstmate`.
The list has since been matched as the exact `<owner>/<repo>`, so the same run now needs the entry `talktejas/firstmate`.
Every read of GitHub was real: the check runs of the commit, and the failed steps' log through `gh run view --job <id> --log-failed`.
No rule fired on any row, so each run is one real question; the 18 calls took 298 to 808 ms.

| Commit | Check | What its log shows | Choice and confidence, three runs | Printed label |
| --- | --- | --- | --- | --- |
| 30fc910f | Behavior portable serial 4 | one `not ok` test assertion | code_bug 0.88, 0.89, 0.89 | code bug |
| dfa2369b | Behavior portable serial 4 | one `not ok` test assertion | code_bug 0.99, 0.98, 0.99 | code bug |
| 30fc910f | Behavior portable serial 2 | one `not ok` test assertion among summary lines | code_bug 0.41, 0.48, 0.48 | unknown |
| f84f2f35 | Behavior portable serial 1 | one `not ok` timing assertion | flaky 0.33, 0.28, 0.37 | unknown |
| f84f2f35 | Behavior portable serial 3 | summary lines only | unclear 0.59, 0.55, 0.58 | unknown |
| 30fc910f | PR must be raised via no-mistakes | a pull request process check refusing a head it did not validate | environment 0.73, 0.72, 0.65 | unknown |

The last row is the reason `flaky` and `environment` need 0.8 rather than the shared 0.6: that failure is the author's to fix, and the model called it `environment` above 0.6 on every run.
The choice was the same on all three runs of every row, and the confidence moved by at most 0.09.

The same check on the same commit also has a passing run that a later pull request edit triggered.
Rule 1 does not call it flaky, because that pass belongs to a different workflow run:

```text
$ gh api "repos/talktejas/firstmate/commits/30fc910f8dac43b550cf46a9099d94ea90e2131b/check-runs?filter=all&per_page=100" --jq '.check_runs[] | select(.name|startswith("PR must")) | [.id,.conclusion,.details_url]|@tsv'
110078953481	failure	https://github.com/talktejas/firstmate/actions/runs/36771558348/job/110078953481
110071234065	success	https://github.com/talktejas/firstmate/actions/runs/36769277507/job/110071234065
110064348154	failure	https://github.com/talktejas/firstmate/actions/runs/36767230944/job/110064348154
```

With the same commit and check but a fixture home that lists no project, the label was `unknown` and no question was sent.

gh 2.100.0 refuses to print a job's raw log from `gh api /repos/<owner>/<repo>/actions/jobs/<id>/logs` ("the response contains terminal escape sequences"), which is why the log is read through `gh run view --log-failed`.

## Stub-only coverage

No open pull request had a failing required check on the run date, so these were not observed live.
`tests/fm-pr-state.test.sh` covers them with a fake `gh` that answers in GitHub's JSON shapes and `fm_jev_choice` stubbed at the library boundary, against fixture homes with no key in the environment:

- the `flaky` rule firing on a pass from another attempt of the same run, and not on a pass from a different run or from a same-named job of the same attempt;
- the `environment` rule firing on a connection error whose check also fails on the base branch;
- `bin/fm-pr-state.sh` itself printing the label beside its unchanged blocker lines, with a fake `curl` that fails, and the key reaching neither `curl`'s argv or environment nor any `gh` call;
- a call without `--sort-failed-checks`, key and listed repository present, making no check-run read, no log download, and no model call;
- no key meaning no extra GitHub read and no extra line;
- an unlisted or commented-out repository, a bare repository name, a same-named repository under another owner, a check with no job log, a failed call, an `unclear` choice, and an answer under either floor all printing `unknown`;
- only the failure-naming lines being sent, cut to the last 4000 characters, and only the first three failed checks being sorted, with a fourth printed as `unknown (not sorted)`.

`FM_PR_STATE_LIVE_E2E=1 bash tests/fm-pr-state-live-e2e.test.sh` is the command that confirms gh's own jq engine still accepts the script's pull-request read programs.
