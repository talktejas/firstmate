# Primary-session delegate guard

This document is the authoritative human-readable contract for the guard that stops a firstmate primary from doing project work itself instead of delegating it.
The shipped mechanism is `bin/fm-delegate-pretool-check.sh`, a PreToolUse guard that denies any tool call whose target resolves into a project, reads included.

## Why this exists

The captain's standing order is that the primary session stays available to him and dispatches project work to workers.
On 2026-09-21 that order failed as an instruction for the Nth time in one day: the primary grepped project source for seeded credentials, read migration files, diagnosed a backend health failure, inspected dependency lock files, read module branch logs, and resolved a merge, all while the captain sat waiting and unable to reach it.
The primary agreed to stop each time and repeated the behavior within minutes, so the captain refused to continue until it was structurally impossible.
A rule that depends on an agent remembering is not a mechanism; this guard is the mechanism.

## Purpose and boundary

The guard addresses one mechanically identifiable event: the primary session pointing an ordinary work tool at project code.
It is the complement of [`subagent-guard.md`](subagent-guard.md): that guard fences the delegation-tool surface so work is created only through the fleet, while this one fences the direct-work surface so project work cannot be done in place instead of created at all.
It makes no judgment about dispatch quality, delivery mode, or whether a given investigation is worthwhile; it only refuses the primary doing that investigation itself.

## Shipped mechanism

`bin/fm-delegate-pretool-check.sh` classifies a `Bash`, `Read`, `Grep`, `Glob`, `Edit`, `Write`, `NotebookEdit`, or `MultiEdit` call in a genuine primary home.
Cursor's shell tool name `Shell` and Grok's `run_terminal_command` classify as command calls alongside `Bash`, so the non-Claude registrations below reach the same classifier.
Every other tool name is out of scope here, and a name beginning `mcp__` is never classified.

A target is a PROJECT when it resolves into any git repository other than the firstmate home's own repo or another firstmate home, or anywhere under `$FM_HOME/projects/` even when git cannot resolve it.
Clones, the captain's own copies, and task worktrees are all such repositories; the breadth is deliberate, because the primary's job description makes any other repo's code a worker's territory.
A linked worktree of the home's own repo shares its git common dir and counts as the home.
A firstmate home clone - a secondmate home, a pool or treehouse home - is a separate repo but carries the home contract (`AGENTS.md` plus `bin/fm-spawn.sh` and `bin/fm-brief.sh`), and supervising one is the primary's own job, so it counts as a home rather than a project; the check is the home's shape, never a path pattern.
Nonexistent paths resolve through their nearest existing ancestor, so an existence probe on a project path is classified while pattern junk that resolves back to the cwd is not.

The decision then follows one rule, stated in the refusal itself:

- **A project-targeted call is denied, whatever its shape.**
  Reading a project is not a cheaper kind of project work: a `Read`, `Grep`, `cat`, `git log`, existence probe, `npm test`, `cd`, `sed -i`, `git merge` or `Edit` pointed at a project is refused alike.
  There is no allowance and no window, so there is no rhythm a primary can pace itself into; the guard holds no state of any kind.
  Every fact a dispatch needs reaches the primary through its workers and through the always-allowed fleet tooling below.
- **The primary's own job is always allowed**, whatever project paths it carries: every `fm-*.sh` script, `no-mistakes`, and the `gh-axi`/`tasks-axi`/`quota-axi`/`lavish-axi` tools, because dispatch and lifecycle commands take project directories as arguments by design.
  Reads and writes inside the home itself (`data/`, `state/`, `config/`, tracked files) never touch the guard.

Bash commands are split into naive shell segments; a segment is refused when it carries a project path and its lead word is not the primary's own fleet tooling.
The lead word therefore only ever widens the refusal to an allowance, never the reverse, so an unrecognized wrapper or verb fails toward the deny.
Quoting subtleties and deliberate obfuscation are out of scope under the same agent-mistake threat model the cd guard records; the script header owns the exact token mechanics.

## Scope

The hook fires only in a genuine firstmate primary home, through the shared predicate `fm_primary_scope_matches` from `bin/fm-primary-scope-lib.sh`, the same predicate the subagent and turn-end guards use.
A marked secondmate home is in scope on purpose: it operates its own fleet and delegates the same way.
A crewmate or scout task worktree is a linked git worktree and stays inert: a worker investigating project code is exactly right and must never be blocked.
Any failure to confirm the home - missing git, malformed transport, an unresolvable repo identity - is inert or fail-open, never a block.

## Escape hatch

A Bash command whose leading assignments include the literal `FM_ALLOW_PROJECT_WORK=1` is allowed, deliberately, for that invocation only.
Unlike the subagent guard's session-environment hatch, the hook's own process environment is deliberately ignored, so the override can never be ambient for a whole session: each use is typed into the specific command and is visible in the transcript by construction.
It exists for the concrete captain-approved exception hard rule 1 already recognizes; the primary using it routinely is a failure of exactly the kind this guard exists to stop.
The refusal never names it: telling the refused agent the one token that releases the guard turns the mechanism back into a choice, which is the failure mode this guard exists to end.

## Output contract

- Allow returns exit 0 with both streams empty.
- Deny returns exit 2 and writes `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[delegate-project-work] ..."}` to stderr.
- Default deny mode also writes `{"decision":"deny","reason":"[delegate-project-work] ..."}` to stdout for Grok; `--claude` suppresses stdout completely, because Claude Code ignores a PreToolUse deny when stdout is nonempty ([`arm-pretool-check.md`](arm-pretool-check.md)).
- The refusal names the intake classification, `bin/fm-scout.sh` when present, `bin/fm-brief.sh` then `bin/fm-spawn.sh`, the blocked tool, and the project it refused - and nothing about the escape hatch.
- Malformed or empty stdin, invalid JSON, a payload with no target, and missing `jq` all fail open with exit 0 and no output.

## Harness wiring

Every registration below reuses a matcher, field name, and transport shape already tracked and verified for the sibling cd guard ([`cd-guard.md`](cd-guard.md) "Harness wiring"); none was derived or guessed.

| Harness | Entry | Adapter behavior on checker exit 2 |
| --- | --- | --- |
| Claude | `.claude/settings.json` PreToolUse hook on `^(Bash\|Read\|Grep\|Glob\|Edit\|Write\|NotebookEdit\|MultiEdit)$` forwarding stdin with `--claude`, resolved through `"$CLAUDE_PROJECT_DIR"` so a linked worktree runs its own copy and scopes itself out | Blocks the tool call; stderr deny object, stdout empty. |
| Codex | `.codex/hooks.json` PreToolUse Bash hook that anchors from `pwd -P`, verifies the hook-loaded firstmate root, and forwards the payload | Blocks on exit 2 and displays stderr. |
| Grok | `.grok/hooks/fm-primary-delegate-check.json` PreToolUse Bash hook anchored on `${GROK_WORKSPACE_ROOT:-}` | Consumes the stdout `decision=deny` object. |
| Cursor | `.cursor/hooks.json` `preToolUse` hook matching `tool_name` `Shell`, forwarding stdin with `--cursor` | Prints Cursor's own `{"permission":"deny","user_message":...}` object on stdout and exits 0, because Cursor reads the returned object rather than the exit status. Without `--cursor` the Cursor-delivered payload is the Claude-settings duplicate Cursor also loads, and stands down through the shared predicate in `bin/fm-hook-host-lib.sh`. |
| OpenCode | `.opencode/plugins/fm-primary-delegate-check.js` `tool.execute.before` calling the CLI form | Throws, which surfaces as the failed tool result. |

Pi and omp are not wired: neither carries a tracked PreToolUse registration for this guard's sibling seatbelts to reuse, so a wiring there would be a new matcher rather than a reused one.
Their shell surface is the bounded follow-up described in [`subagent-guard.md`](subagent-guard.md); the `--tool`/`--command`/`--path` CLI form they would use already exists.
Every shell variable reference in the Grok hook command carries an inline default (`${GROK_WORKSPACE_ROOT:-}`) because Grok expands the raw hook command before `bash -lc` runs it, the same requirement documented in [`arm-pretool-check.md`](arm-pretool-check.md).

## Live validation record, 2026-09-21

Harness version: `2.1.278 (Claude Code)`.
Every run used a scratch primary-shaped home under a task worktree, with the hook registered exactly as tracked and a scratch project repo beside it; no live fleet state was touched.

- A payload logger under matcher `^(Bash|Read|Grep|Glob|Edit|Write|NotebookEdit|MultiEdit)$` captured live `Read` payloads carrying `tool_name`, `tool_input.file_path`, and `cwd`, the exact fields the extractor reads.
- In the primary-shaped home, a `Read` of a project file was denied end to end: Claude honored the deny and quoted the `[delegate-project-work]` message, including the dispatch route. The run was recorded while a first read was still an allowed identity check, so the denied call was the second one; the allowance has since been removed and the automated live test now denies the first read, exercising the identical vendor surface.
- `npm --prefix <project> test` was denied as a build shape while `bin/fm-crew-state.sh <task> <project>` ran untouched in the same session.
- In a linked worktree of that home carrying the identical tracked bytes, both `Read` calls reached the worktree's own copy of the checker and were allowed (a block seen there came from an operator-global duplicate-read hook, not this guard).
- This session type offered no separate `Grep` tool and routed content search through `Bash`, which the guard covers; the matcher still names `Grep`/`Glob` for the session types that do offer them.
- The escape hatch and the remaining classification matrix are pure command-text logic with no vendor surface, owned by the portable suite below.

`tests/fm-delegate-guard-claude-live-e2e.test.sh` automates the deny and inert cases against the installed claude and is the command that refreshes this record; it is opt-in through `FM_DELEGATE_GUARD_LIVE=1` because it submits prompts.

## Automated validation

`tests/fm-delegate-pretool-check.test.sh` owns the acceptance matrix and is registered in the `pure-contract-unit` family in `bin/fm-test-run.sh`.
It covers unconditional refusal of read, build, run, cd, write, redirection, and git-write shapes into a project, and that the guard writes no pacing state; wrapper handling (`timeout`, `bash -c`) in both the allow and deny directions; the Grok and Cursor shell tool names, the `--cursor` decision object, and the Cursor duplicate stand-down; that each tracked Grok, Codex, and Cursor registration reaches the guard with the harness payload and that the OpenCode plugin surfaces its refusal; the firstmate-home-clone exception and its lookalike counterexample; the always-allowed fleet scripts and `*-axi` tools with project arguments; classification of `Read`/`Grep`/`Glob`/`Edit`/`Write`/`NotebookEdit`; freedom of home, state, and non-repo paths; the `projects/` prefix without git; the per-invocation escape hatch including its refusal of ambient environment release and the refusal's silence about it; the dispatch-path message in both scout variants; inertness in a crewmate worktree and a non-firstmate repo; in-scope enforcement for a marked secondmate home; both stdin transports; the empty-stdout requirement; fail-open transport behavior; and the tracked registration's matcher and `--claude` flag.

Run:

```sh
bash -n bin/fm-delegate-pretool-check.sh
bin/fm-lint.sh
tests/fm-delegate-pretool-check.test.sh
FM_DELEGATE_GUARD_LIVE=1 tests/fm-delegate-guard-claude-live-e2e.test.sh
```

## Known residual gap

The tracked Claude entry stays deliberately unguarded against Grok's Claude-compatible settings loading, unlike the sibling seatbelt entries (docs/turnend-guard.md "Harness integrations"): the Grok registration matches the shell tool only, while the Claude-shaped entry also reaches Grok's compatibility mapping for the read and write tools, so standing it down would shrink coverage rather than deduplicate it.
A duplicate evaluation costs nothing here because the guard holds no state and both copies reach the same verdict, and `--claude` keeps the duplicate off the stdout channel Grok consumes.
Pi and omp remain uncovered for the reason recorded under "Harness wiring", and the Cursor and OpenCode entries cover their shell surface only.
The classifier is a seatbelt against the observed mistake shapes, not a sandbox: redirection targets are not parsed, variable indirection is not resolved, and deliberate obfuscation is out of scope under the recorded threat model.
