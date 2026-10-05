# Finished check verification

Audience: maintainer verification.

This record supports the key-gated finished check owned by [`../configuration.md`](../configuration.md) ("Finished check").
It records only facts that must be re-established when Claude Code's Stop hook contract, the typesafe.ai model, or the questions in `bin/fm-finished-check.sh` change.
The API shape itself is recorded in [`dispatch-resolve.md`](dispatch-resolve.md).

## Claude Code Stop hook contract

Run 2026-10-06 on Claude Code 2.1.289.
The Stop payload carried `last_assistant_message`, `stop_hook_active`, `background_tasks`, and `transcript_path`; a `{"decision":"block"}` reply continued the turn, and the following stop arrived with `stop_hook_active` true and ended the turn.

```text
$ FM_FINISHED_CHECK_LIVE_E2E=1 bash tests/fm-finished-check-live-e2e.test.sh
ok - 2.1.289 (Claude Code): Stop payload fields, block continuation, and stop_hook_active all hold
```

That guard is the command that refreshes this section after a Claude Code upgrade.
It answers Jev with a fake `curl`, so it needs no key.

## Live answers to the shipped questions

Run 2026-10-06 against `https://api.typesafe.ai`, model `jev-latest`, timeout 5 s, floor 0.6.
Each cell is one real call made through the script's own question helper, sourced from `bin/fm-finished-check.sh` with its instructions and criteria unmodified and the key read from a home `.env` by `fm_jev_key_load`.
Each cell is the choice and its confidence.
The six `claims_checks_passed` calls carried the closing message alone and took 323 to 367 ms.
The other 18 cells come from a 24-call run that took 291 to 733 ms, median 326 ms; its six calls on an earlier form of the `claims_checks_passed` question are not shown.

| Closing message | `claims_finished` | `asks_question` | `partial_or_blocked` | `claims_checks_passed` |
| --- | --- | --- | --- | --- |
| The fix is implemented and committed on the branch. All tests pass and lint is clean. The work is complete. | yes 1.0 | no 1.0 | no 0.99 | yes 1.0 |
| I found two ways to store the setting: a column on the accounts table or a row in settings. Which one do you want me to use? | no 0.99 | yes 1.0 | yes 0.07 | no 1.0 |
| I updated the parser but the migration step is not done yet; the database container would not start so I could not run it. | no 1.0 | no 1.0 | yes 1.0 | no 1.0 |
| The current branch is fm/fm-example and the last commit is 08a3a5cd. | no 1.0 | no 1.0 | no 1.0 | no 1.0 |
| The validation pipeline is running in the background; I will pick it up when it reports the next gate. | no 1.0 | no 0.98 | yes 0.93 | no 0.99 |
| Done. I committed the change. I did not run the test suite. | yes 0.79 | no 1.0 | yes 0.96 | no 0.99 |

The `yes 0.07` cell is below the floor and counts as no mismatch.
The background-pipeline row reads as partial work, so a worker that stops that way with no live background task and no reported state is sent back once toward a `paused:` line.

The executable against the same endpoint, with an armed busy record, no status line, and a clean worktree:

```text
$ jq -cn '{stop_hook_active:false,background_tasks:[],last_assistant_message:"I found two ways to store the setting: a column on the accounts table or a row in settings. Which one do you want me to use?"}' | bin/fm-finished-check.sh <home> <state-dir> t1 <worktree>
{"decision":"block","reason":"Firstmate finished check: your closing message asks a question, but nobody was told; append needs-decision: with the question to the status file, or decide and continue."}
$ jq -cn '{stop_hook_active:false,background_tasks:[],last_assistant_message:"The current branch is fm/fm-example and the last commit is 08a3a5cd."}' | bin/fm-finished-check.sh <home> <state-dir> t1 <worktree>
$
```

## Portable coverage

`tests/fm-finished-check.test.sh` stubs `fm_jev_choice` at the library boundary against a fixture home and asserts every fact gate by which questions were asked, then runs the executable with a fake `curl` that records whether the key reached its argv or environment.
`tests/fm-busy-adapter-wiring.test.sh` runs the Stop hook command that `bin/fm-spawn.sh` writes.
