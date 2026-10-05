# Commit check verification

Audience: maintainer verification.

This record supports the key-gated commit check owned by [`../configuration.md`](../configuration.md) ("Commit check").
It records only facts that must be re-established when git's hook lookup, the typesafe.ai model, or the questions in `bin/fm-commit-check.sh` change.
The API shape itself is recorded in [`dispatch-resolve.md`](dispatch-resolve.md).

## Live answers to the shipped questions

Run 2026-10-06 against `https://api.typesafe.ai`, model `jev-latest`, timeout 5 s, floor 0.6, git 2.53.0.
Each row is one real request made by `fm_commit_check`, sourced from `bin/fm-commit-check.sh` with its instructions and criteria unmodified, over a change staged in a throwaway repository of synthetic files, with the key taken from the environment by the library and the project named in a fixture `config/jev-code-projects`.
Each cell is the choice and its confidence; a dash means code left the question out.
Each request took between 314 and 364 ms.

| Staged change | Message | `filler` | `contradicts` | `leftovers` | `unmentioned` | Advisory lines |
| --- | --- | --- | --- | --- | --- | --- |
| One file adding a three-attempt retry loop | Retry a timed-out fetch up to three times | no 0.99 | no 0.97 | no 1.0 | - | none |
| The same file | Remove the retry loop from fetch | no 0.96 | yes 0.92 | no 1.0 | - | contradicts |
| A price function with a debug print and a commented-out block, and a test marked skipped | Multiply each price by its quantity in total | no 0.98 | no 0.95 | yes 1.0 | no 0.94 | leftovers |
| A date parser fix and an unrelated invoice late-fee function | Strip whitespace before parsing a date | no 0.98 | no 0.89 | no 0.99 | yes 0.9 | unmentioned |
| The date parser fix alone | Finalize things | yes 0.98 | no 0.97 | no 0.99 | - | filler |

## Live commits through the installed hooks

Run the same day against the same endpoint: `--install` wrote the hooks directory, and `git commit` ran with the printed value exported as `GIT_CONFIG_PARAMETERS`.
The transcript shows only the lines the final code still prints for these two commits; the worktree scoping, the stop's closing line, the secret-literal advisory, and the withheld diff lines were not run live and are covered by the portable suite below.

```text
$ git commit -q -m 'Remove the retry loop from fetch'    # staged: the retry loop added
commit-check: advisory, the commit goes through: the message appears to contradict the staged change. (Jev confidence 0.91)
$ echo $?
0
$ git commit -q -m 'Add the client key'                  # staged: a line holding a GitHub-token-shaped literal
commit-check: commit stopped, an added line looks like a credential:
  src/conf.py:1: GitHub token
$ echo $?
1
```

The first commit was made and the second was not.

A Claude Code worker's shell was observed the same day to carry the task marker that `bin/fm-spawn.sh` exports on the same channel as this setting; no other harness was launched for this record.

## Portable coverage

`tests/fm-commit-check.test.sh` covers the rest with no network, against a fixture home.
With `fm_jev_choices` stubbed at the library boundary it asserts: nothing asked or said without a key; nothing sent, and filler not judged, for a project that is not listed; which questions each code fact leaves out; that filler is always asked for a listed project, including for a subject with no ASCII letters; silence for a low-confidence answer and for a failed call; the path filter; that a long diff and a long message are sent as their ends; the skipped commit kinds; the credential stop for a token format and a private-key header, including that it never prints the value, never suggests skipping the hooks, and does nothing without a key or for a project that is not listed; that a quoted password literal and four ordinary lines naming a token or secret do not stop a commit; that the flagged literal line is sent as `[line withheld]` while the rest of the change is sent; and that a stop for a path holding a space names its line.
With the real library and a fake `curl` it asserts that `--install` writes nothing without a key, for a project that is not listed, or for a directory that is not a git work tree, then makes real commits through the installed hooks and asserts one request per commit, that the key reaches neither `curl`'s argv nor its environment, that a git without the exported setting is untouched, that a commit in an unrelated repository or in another worktree of the same repository is not stopped, is told nothing, has nothing sent, and still runs that repository's own hook, and that the project's own hooks still run and still decide.
It then runs `bin/fm-spawn.sh` on a fake tmux and asserts the pane is sent the setting only when the home holds a key and lists the project, that every line sent for an unlisted project with a key equals the keyless launch, that the filtered launch environment retains the setting only for the listed project, that a commit made under the sent line in the task's worktree is checked, and that one made under it in another repository is not.
The timeout, transport-error, and malformed-answer paths were exercised only there and in the library's own callers' suites, not against the live endpoint.
