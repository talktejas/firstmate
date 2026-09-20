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

The tracked Claude registration in `.claude/settings.json` uses the anchored matcher `^(Bash|Read|Grep|Glob|Edit|Write|NotebookEdit|MultiEdit)$` and passes `--claude`, resolved through `"$CLAUDE_PROJECT_DIR"` so a linked worktree runs its own copy and scopes itself out.
Grok, OpenCode, Pi, Codex, Cursor, and omp are not wired, for the same reason recorded in [`subagent-guard.md`](subagent-guard.md): wiring an unverified matcher or field name is a guess, not coverage.
The script already accepts Grok's stdin shape and a `--tool`/`--command`/`--path` CLI form for OpenCode and Pi, so each wiring is the bounded matcher-verification follow-up described there.

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
It covers unconditional refusal of read, build, run, cd, write, and git-write shapes into a project, and that the guard writes no pacing state; the firstmate-home-clone exception and its lookalike counterexample; the always-allowed fleet scripts and `*-axi` tools with project arguments; classification of `Read`/`Grep`/`Glob`/`Edit`/`Write`/`NotebookEdit`; freedom of home, state, and non-repo paths; the `projects/` prefix without git; the per-invocation escape hatch including its refusal of ambient environment release and the refusal's silence about it; the dispatch-path message in both scout variants; inertness in a crewmate worktree and a non-firstmate repo; in-scope enforcement for a marked secondmate home; both stdin transports; the empty-stdout requirement; fail-open transport behavior; and the tracked registration's matcher and `--claude` flag.

Run:

```sh
bash -n bin/fm-delegate-pretool-check.sh
bin/fm-lint.sh
tests/fm-delegate-pretool-check.test.sh
FM_DELEGATE_GUARD_LIVE=1 tests/fm-delegate-guard-claude-live-e2e.test.sh
```

## Known residual gap

The tracked entry is deliberately unguarded against Grok's Claude-compatible settings loading, exactly like the subagent entry (docs/turnend-guard.md "Harness integrations"): no `.grok/hooks/` registration covers this event, so guarding it would remove the incidental reach entirely rather than deduplicate it.
That incidental reach is partial, since `--claude` suppresses the stdout object Grok consumes; Cursor likewise loads the tracked entry but reads a returned decision object rather than exit 2, so its coverage is nil until a `--cursor` rendering is wired and verified.
The classifier is a seatbelt against the observed mistake shapes, not a sandbox: redirection targets are not parsed, variable indirection is not resolved, and deliberate obfuscation is out of scope under the recorded threat model.
