# Helper model pick verification

Audience: maintainer verification.

This record supports the key-gated helper model pick owned by [`../configuration.md`](../configuration.md) ("Helper model pick").
It records only facts that must be re-established when Claude Code's pre-tool hook contract, the typesafe.ai model, or the question in `bin/fm-helper-model.sh` changes.
The API shape itself is recorded in [`dispatch-resolve.md`](dispatch-resolve.md).

## Live evidence

### The hook can lower one helper's model

Run 2026-10-06 with Claude Code 2.1.290, in a scratch repository whose `.claude/settings.local.json` held one `PreToolUse` hook with matcher `Agent|Task`.
The hook printed `{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":<the tool input plus "model":"haiku">}}` and named no permission decision.
The session ran with `claude -p ... --model sonnet --dangerously-skip-permissions` and made one general-purpose hand-off with no model named.

- The hook received `tool_name` `Agent` and a `tool_input` of `description`, `prompt`, `subagent_type`, and `run_in_background`.
- Every assistant message in the session's own transcript carried model `claude-sonnet-5-5`.
- Every assistant message in the helper's transcript, under the session's `subagents/` directory, carried model `claude-haiku-4-5-20251001`.

So a hook answer holding only `updatedInput` changes the helper's model on that version.
That run used a permission mode that asks about nothing, so it does not show how the changed input is presented when Claude Code asks for approval of the helper-agent tool.
No other harness was launched for this record.

### The question, against the live endpoint

Run 2026-10-06, six real calls through `bin/fm-helper-model.sh --hook` with invented hand-offs, each a general-purpose helper with no model named.
The columns are the recorded outcome, answer, confidence, and latency in milliseconds.

```text
cheaper  mechanical  1.0  346  Find callers       "List every file under src/ that calls parse_rate and report file and line. Do not change anything."
cheaper  mechanical  1.0  299  Run lint           "Run bin/fm-lint.sh and report its output verbatim."
cheaper  mechanical  1.0  299  Rename constant    "In tests/rates.test.sh replace every occurrence of OLD_RATE with BASE_RATE. Change nothing else."
kept     judgement   1.0  322  Debug flaky test   "The settlement test fails one run in five. Work out why and propose a fix."
kept     judgement   1.0  335  Design the schema  "Design the database tables for multi-currency ledgers and justify the trade-offs."
kept     judgement   1.0  339  Rotate credentials "Update the production deploy script so it reads the new signing key and removes the old one."
```

The three `cheaper` calls printed a hook answer with model `sonnet`; the three `kept` calls printed nothing.
Six clear-cut cases are not an accuracy figure.
How the model answers real, mixed hand-offs is unmeasured; `state/.helper-model.log` is where that evidence accumulates.

## Portable coverage

`tests/fm-helper-model.test.sh` covers the rest with no network, against a fixture home.
With `fm_jev_choice` stubbed at the library boundary it asserts: nothing asked, printed, or recorded without a key or for a project that is not listed; that the request holds exactly a description, a helper type, and a prompt; that a confident `mechanical` sets the model and leaves every other input field intact with no permission decision; that `judgement`, a low-confidence answer, and a failed call print nothing; that a hand-off naming a model or using a helper type that does not inherit the worker's model is never asked about; that a long prompt is sent as its end and handed on whole; that the record never holds the prompt; and the `--enabled` gate.
It then runs `bin/fm-spawn.sh` on a fake tmux and asserts that the worker's settings file is the keyless file for a key without the project listed and for a worker launched on a cheaper model, that with a key and a listed project it differs only by the one hook, and that the written command, run with the real library and a fake `curl`, makes one request, withholds a credential line, keeps the key off `curl`'s argv and environment, and records the pick in the home's state.
The timeout, transport-error, and malformed-answer paths were exercised only there and in the library's own callers' suites, not against the live endpoint.
