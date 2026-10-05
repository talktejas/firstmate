# Commit check verification

Audience: maintainer verification.

This record supports the key-gated commit check owned by [`../configuration.md`](../configuration.md) ("Commit check").
It records only facts that must be re-established when git's hook lookup, the typesafe.ai model, or the questions in `bin/fm-commit-check.sh` change.
The API shape itself is recorded in [`dispatch-resolve.md`](dispatch-resolve.md).

## Live evidence

The request the final code sends - the commit message and the staged file names only, with the `filler`, `contradicts`, and `unmentioned` questions - has not been run against the live endpoint.
Earlier live runs sent the staged change's content and judged a `contradicts` criterion worded for it, so they are not evidence for this request and are not recorded here.
How the model answers `contradicts` and `unmentioned` from file names alone must be established live before the advisories are relied on.

The credential stop does not involve the model.
Run 2026-10-06 with git 2.53.0, after `--install` wrote the hooks directory and with the printed value exported as `GIT_CONFIG_PARAMETERS`; the stop's closing line has since been reworded and is left out:

```text
$ git commit -q -m 'Add the client key'                  # staged: a line holding a GitHub-token-shaped literal
commit-check: commit stopped, an added line looks like a credential:
  src/conf.py:1: GitHub token
$ echo $?
1
```

The commit was not made.

A Claude Code worker's shell was observed the same day to carry the task marker that `bin/fm-spawn.sh` exports on the same channel as this setting; no other harness was launched for this record.

## Portable coverage

`tests/fm-commit-check.test.sh` covers the rest with no network, against a fixture home.
With `fm_jev_choices` stubbed at the library boundary it asserts: nothing asked or said without a key; nothing sent, and filler not judged, for a project that is not listed; that the request holds exactly a message and file names, with no line of any staged file's content, for new code files, for a secret-shaped path and a lockfile, for a renamed file with an appended line, and for a file with a flagged literal; that `unmentioned` is left out for one staged file; that filler is always asked for a listed project, including for a subject with no ASCII letters; silence for a low-confidence answer and for a failed call; that a long message is sent as its end; the skipped commit kinds; the credential stop for a token format and a private-key header, including that it never prints the value, never suggests skipping the hooks, and does nothing without a key or for a project that is not listed; that a quoted password literal and four ordinary lines naming a token or secret do not stop a commit; that the literal advisory still fires on a line holding a byte that is invalid in a UTF-8 locale; that removing a tracked credential is not stopped; that a stop for a path holding a space names its line; and that the stop still fires for a file whose name git quotes and for a symlink replaced by a regular file.
With the real library and a fake `curl` it asserts that `--install` writes nothing without a key, for a project that is not listed, or for a directory that is not a git work tree, then makes real commits through the installed hooks and asserts one request per commit, that the key reaches neither `curl`'s argv nor its environment, that a git without the exported setting is untouched, that a commit in an unrelated repository or in another worktree of the same repository is not stopped, is told nothing, has nothing sent, and still runs that repository's own hook, and that the project's own hooks still run and still decide.
It then runs `bin/fm-spawn.sh` on a fake tmux and asserts the pane is sent the setting only when the home holds a key and lists the project, that every line sent for an unlisted project with a key equals the keyless launch, that the filtered launch environment retains the setting only for the listed project, that a commit made under the sent line in the task's worktree is checked, and that one made under it in another repository is not.
The timeout, transport-error, and malformed-answer paths were exercised only there and in the library's own callers' suites, not against the live endpoint.
