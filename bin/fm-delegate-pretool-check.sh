#!/usr/bin/env bash
# PreToolUse guard: the firstmate PRIMARY delegates project work, it never does it.
#
# The captain's standing order is that the primary session stays free for him
# and dispatches project work to workers. Instructions alone did not hold: the
# primary repeatedly slid from "one quick look" into grepping project source,
# reading migrations, running builds, and resolving merges while the captain
# waited. This guard makes that refused by mechanism rather than remembered.
#
# WHAT IT CLASSIFIES. A Bash, Read, Grep, Glob, Edit, Write, or NotebookEdit
# call in a genuine primary home whose target resolves into a PROJECT: any git
# repository other than the firstmate home's own repo, plus anything under
# $FM_HOME/projects/ even when git cannot resolve it. Clones under projects/,
# the captain's own copies, and task worktrees are all such repositories; the
# rule is deliberately broad because the primary's job description makes any
# other repo's code a worker's territory. A linked worktree of the home's own
# repo shares its git common dir and stays classified as the home.
#
# THE ONE-IDENTITY-CHECK RULE. A dispatch sometimes needs one cheap fact - a
# branch name, whether a path exists, one registry-confirming read - so ONE
# read-shaped project-targeted call per project per window (default 120s) is
# allowed and stamped in state/.delegate-guard-window. The second read-shaped
# call on the same project inside the window is a sequence, a sequence is an
# investigation, and an investigation is a worker's job, so it is denied.
# Build, run, and write shapes (package managers, test runners, interpreters
# on project code, file mutation, git write verbs) are never identity checks
# and are denied without consuming budget. Edit/Write/NotebookEdit into a
# project are write shapes. fm-*.sh scripts, no-mistakes, and the *-axi tools
# are the primary's own job and always allowed, whatever paths they carry.
# See docs/delegate-guard.md for the complete contract and validation record.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-delegate-pretool-check.sh
#   bin/fm-delegate-pretool-check.sh --tool Bash --command '<cmd>' [--cwd <dir>]
#   bin/fm-delegate-pretool-check.sh --tool Read --path '<file>'
#
# Stdin mode extracts .tool_name/.tool_input for Claude, Codex, and Cursor, or
# .toolName/.toolInput for Grok. CLI mode is for adapters that already hold the
# values (OpenCode, Pi) and for tests.
#
# Exit/output contract (identical shape to bin/fm-subagent-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   INERT - not a genuine primary home (a crewmate/scout task worktree or a
#           non-firstmate repo): exit 0 with no output, exactly like ALLOW.
#   ESCAPE - a Bash command whose leading assignments include the literal
#            FM_ALLOW_PROJECT_WORK=1 allows deliberately, per invocation. The
#            hook's own process environment is deliberately ignored so the
#            override can never be ambient for a whole session.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport, or
#               an unconfirmable home identity.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
set -u
# Tokens from the command string are inspected verbatim; never glob-expand them.
set -f

# Per-segment lead words that are the primary's own job and release the whole
# segment, whatever project paths it carries: dispatch and lifecycle scripts
# take project directories as arguments by design.
ALLOW_WORDS=' no-mistakes gh-axi tasks-axi quota-axi lavish-axi '

# Lead words whose project-targeted segment is a build/run shape, never an
# identity check: they execute project code or its toolchain.
RUN_WORDS=' npm npx yarn pnpm bun node deno php python python2 python3 pytest ruby rake bundle composer mvn gradle gradlew make cmake cargo go docker podman docker-compose phpunit jest vitest tsc gcc g++ cc javac java dotnet '

# Lead words whose project-targeted segment mutates files, never an identity
# check (hard rule 1 forbids the write regardless).
# ponytail: redirection targets (`> project/file`) are not parsed; sed -i, tee,
# and this list cover the observed mistake shapes. Parse redirects if a real
# miss ever shows up.
WRITE_WORDS=' rm mv cp mkdir rmdir touch tee ln chmod chown truncate install rsync patch dd shred '

# git verbs that change a project's tree, index, refs, or worktrees.
GIT_WRITE_VERBS=' merge rebase pull push commit checkout switch restore reset revert cherry-pick am apply stash clean mv rm worktree submodule filter-branch update-ref '

TOOL=""
TOOL_SET=0
CMD=""
TPATH=""
CWD=""
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-delegate-pretool-check.sh [--tool <name>] [--command <cmd>] [--path <p>] [--cwd <dir>] [--claude]

With no --tool, reads a PreToolUse-style JSON payload on stdin (Claude/Codex
tool_name and tool_input, or Grok toolName and toolInput).
Denies a firstmate primary's investigation- or build-shaped Bash, Read, Grep,
Glob, Edit, Write, or NotebookEdit call whose target is inside a project: any
git repository other than the home's own, or anything under $FM_HOME/projects/.
One read-shaped call per project per window (default 120s) is allowed as a
dispatch identity check; build, run, and write shapes are always denied.
fm-*.sh, no-mistakes, and the *-axi tools are always allowed.
Fires only in a genuine firstmate primary home; it is a silent no-op in a
crewmate/scout task worktree or any non-firstmate repo, where a worker
investigating project code is exactly right.
Exits 0 to allow and 2 to deny, naming the crewmate dispatch path instead.
A Bash command prefixed with the literal assignment FM_ALLOW_PROJECT_WORK=1
allows deliberately, per invocation; the hook's own environment is ignored.
Malformed transport and an unconfirmable home identity fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool)
      [ "$#" -gt 1 ] || { echo "error: --tool requires a value" >&2; exit 2; }
      TOOL=$2; TOOL_SET=1; shift 2 ;;
    --tool=*) TOOL=${1#--tool=}; TOOL_SET=1; shift ;;
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2; shift 2 ;;
    --command=*) CMD=${1#--command=}; shift ;;
    --path)
      [ "$#" -gt 1 ] || { echo "error: --path requires a value" >&2; exit 2; }
      TPATH=$2; shift 2 ;;
    --path=*) TPATH=${1#--path=}; shift ;;
    --cwd)
      [ "$#" -gt 1 ] || { echo "error: --cwd requires a value" >&2; exit 2; }
      CWD=$2; shift 2 ;;
    --cwd=*) CWD=${1#--cwd=}; shift ;;
    --claude) CLAUDE_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [ "$TOOL_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  TOOL=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_name // .toolName // empty)' 2>/dev/null) || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.command // .toolInput.command // empty)' 2>/dev/null) || exit 0
  TPATH=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // .toolInput.file_path // .toolInput.notebook_path // .toolInput.path // empty)' 2>/dev/null) || exit 0
  GLOB_PATTERN=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.pattern // .toolInput.pattern // empty)' 2>/dev/null) || GLOB_PATTERN=""
  CWD=$(printf '%s' "$PAYLOAD" | jq -r '(.cwd // empty)' 2>/dev/null) || CWD=""
else
  GLOB_PATTERN=""
fi

[ -n "$TOOL" ] || exit 0
case "$TOOL" in
  mcp__*) exit 0 ;;
esac
LC_ALL=C NORMALIZED=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]')

# Only these tools are classified; every other tool name is out of scope here
# (bin/fm-subagent-pretool-check.sh owns the delegation-tool surface).
KIND=""
case "$NORMALIZED" in
  bash) KIND="command" ;;
  read|grep|glob) KIND="read" ;;
  edit|write|notebookedit|multiedit) KIND="write" ;;
  *) exit 0 ;;
esac

if [ "$KIND" = command ]; then
  [ -n "$CMD" ] || exit 0
  # The single escape hatch: a leading literal assignment in the command text.
  # Per invocation and visible in the transcript by construction; the hook's
  # own process environment is deliberately never consulted.
  REST=$CMD
  while :; do
    REST=${REST#"${REST%%[![:space:]]*}"}
    TOK=${REST%%[[:space:]]*}
    case "$TOK" in
      FM_ALLOW_PROJECT_WORK=1) exit 0 ;;
      [A-Za-z_]*=*) REST=${REST#"$TOK"} ;;
      *) break ;;
    esac
  done
else
  [ -n "$TPATH" ] || [ -n "$GLOB_PATTERN" ] || exit 0
fi

case "$CWD" in
  /*) ;;
  *) CWD=$PWD ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

# Scope to a genuine primary home, exactly as the subagent and turn-end guards
# do. A crewmate/scout task worktree is a linked git worktree and stays inert:
# a worker investigating project code is exactly right. Any failure to confirm
# the home is inert (exit 0), never a block.
command -v git >/dev/null 2>&1 || exit 0
# shellcheck source=bin/fm-primary-scope-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# Physical git common dir of a repo containing $1, or failure.
repo_common_dir() {
  local dir=$1 top c
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  c=$(git -C "$top" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$c" in
    /*) ;;
    *) c=$top/$c ;;
  esac
  CDPATH='' cd -- "$c" 2>/dev/null && pwd -P
}

HOME_COMMON=$(repo_common_dir "$FM_ROOT") || exit 0
if [ -d "$FM_HOME/projects" ]; then
  PROJECTS_ROOT=$(CDPATH='' cd -- "$FM_HOME/projects" 2>/dev/null && pwd -P) || exit 0
else
  PROJECTS_ROOT=$FM_HOME/projects
fi

# classify_path <path>: print the project root when <path> resolves into a
# project, print nothing when it belongs to the home or to no repo at all.
# Nonexistent paths resolve through their nearest existing ancestor, so an
# existence check on a project path is still classified while pattern junk
# that resolves back to the cwd is not.
classify_path() {
  local p=$1 dir top common
  case "$p" in
    "$PROJECTS_ROOT"|"$PROJECTS_ROOT"/*) printf '%s\n' "$PROJECTS_ROOT"; return 0 ;;
  esac
  dir=$p
  while [ ! -d "$dir" ]; do
    case "$dir" in
      */*) dir=${dir%/*}; [ -n "$dir" ] || dir=/ ;;
      *) dir=. ;;
    esac
  done
  dir=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || return 0
  case "$dir" in
    "$PROJECTS_ROOT"|"$PROJECTS_ROOT"/*) printf '%s\n' "$PROJECTS_ROOT"; return 0 ;;
  esac
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 0
  common=$(repo_common_dir "$dir") || return 0
  [ "$common" != "$HOME_COMMON" ] || return 0
  printf '%s\n' "$top"
}

# expand_token <token>: sanitize one whitespace token into an absolute path
# candidate, or print nothing.
expand_token() {
  local tok=$1
  tok=${tok#\$\(}
  while :; do
    case "$tok" in
      \(*|\"*|\'*|\`*) tok=${tok#?} ;;
      *) break ;;
    esac
  done
  while :; do
    case "$tok" in
      *\)|*\"|*\'|*\`) tok=${tok%?} ;;
      *) break ;;
    esac
  done
  case "$tok" in
    *=*) tok=${tok#*=} ;;
  esac
  [ -n "$tok" ] || return 0
  case "$tok" in
    *://*) return 0 ;;
    -*) return 0 ;;
    "~") tok=$HOME ;;
    \~/*) tok=$HOME/${tok#\~/} ;;
    /*) ;;
    */*) tok=$CWD/$tok ;;
    *) return 0 ;;
  esac
  printf '%s\n' "$tok"
}

HARD_ROOTS=""
SOFT_ROOTS=""
HARD_WORD=""
PATHS_SEEN=0

note_root() {
  # note_root <shape> <root>: record a classified project root once per shape.
  local shape=$1 root=$2
  case "$shape" in
    hard)
      case "$HARD_ROOTS" in
        *"|$root|"*) ;;
        *) HARD_ROOTS="$HARD_ROOTS|$root|" ;;
      esac ;;
    soft)
      case "$SOFT_ROOTS" in
        *"|$root|"*) ;;
        *) SOFT_ROOTS="$SOFT_ROOTS|$root|" ;;
      esac ;;
  esac
}

if [ "$KIND" = command ]; then
  # Split into naive shell segments; quoting subtleties are out of scope under
  # the same agent-mistake threat model the sibling guards use.
  SEGSTR=${CMD//$'\n'/;}
  SEGSTR=${SEGSTR//$'\r'/;}
  SEGSTR=${SEGSTR//&&/;}
  SEGSTR=${SEGSTR//\|\|/;}
  SEGSTR=${SEGSTR//\|/;}
  SEGSTR=${SEGSTR//&/;}
  OLDIFS=$IFS
  IFS=';'
  # shellcheck disable=SC2086
  set -- $SEGSTR
  IFS=$OLDIFS
  for SEG in "$@"; do
    # Lead word: first token that is not an assignment or a plain wrapper.
    LEAD=""
    GIT_VERB=""
    WANT_GIT_VERB=0
    SKIP_NEXT=0
    HAS_DASH_I=0
    SEG_PATHS=""
    # shellcheck disable=SC2086
    for TOK in $SEG; do
      RAW=$TOK
      while :; do
        case "$RAW" in
          \(*|\"*|\'*|\`*) RAW=${RAW#?} ;;
          *) break ;;
        esac
      done
      RAW=${RAW#\$\(}
      if [ -z "$LEAD" ]; then
        case "$RAW" in
          ''|[A-Za-z_]*=*) continue ;;
          env|exec|command|nohup|time|sudo|bash|sh|zsh) continue ;;
          *) LEAD=${RAW##*/} ;;
        esac
        [ "$LEAD" = git ] && WANT_GIT_VERB=1
      elif [ "$WANT_GIT_VERB" -eq 1 ] && [ -z "$GIT_VERB" ]; then
        if [ "$SKIP_NEXT" -eq 1 ]; then
          SKIP_NEXT=0
        else
          case "$RAW" in
            -C|-c) SKIP_NEXT=1 ;;
            -*) ;;
            [A-Za-z_]*=*) ;;
            *) GIT_VERB=$RAW ;;
          esac
        fi
      fi
      case "$RAW" in
        -i|-i?*) HAS_DASH_I=1 ;;
      esac
      if [ "$PATHS_SEEN" -lt 32 ]; then
        CAND=$(expand_token "$TOK") || CAND=""
        if [ -n "$CAND" ]; then
          PATHS_SEEN=$((PATHS_SEEN + 1))
          ROOT=$(classify_path "$CAND")
          [ -n "$ROOT" ] && SEG_PATHS="$SEG_PATHS|$ROOT|"
        fi
      fi
    done
    [ -n "$SEG_PATHS" ] || continue
    case "$ALLOW_WORDS" in
      *" $LEAD "*) continue ;;
    esac
    case "$LEAD" in
      fm-*.sh) continue ;;
    esac
    SHAPE=soft
    case "$RUN_WORDS" in
      *" $LEAD "*) SHAPE=hard ;;
    esac
    case "$WRITE_WORDS" in
      *" $LEAD "*) SHAPE=hard ;;
    esac
    if [ "$LEAD" = git ] && [ -n "$GIT_VERB" ]; then
      case "$GIT_WRITE_VERBS" in
        *" $GIT_VERB "*) SHAPE=hard ;;
      esac
    fi
    if [ "$HAS_DASH_I" -eq 1 ]; then
      case "$LEAD" in
        sed|perl) SHAPE=hard ;;
      esac
    fi
    # Entering a project directory is never needed for an identity check
    # (absolute paths and git -C answer those), and it is how "one quick look"
    # becomes a working session, so a cd-shaped segment is hard.
    case "$LEAD" in
      cd|pushd|popd) SHAPE=hard ;;
    esac
    [ "$SHAPE" = hard ] && HARD_WORD=${HARD_WORD:-$LEAD}
    OLDIFS2=$IFS
    IFS='|'
    # shellcheck disable=SC2086
    for ROOT in $SEG_PATHS; do
      IFS=$OLDIFS2
      [ -n "$ROOT" ] && note_root "$SHAPE" "$ROOT"
      IFS='|'
    done
    IFS=$OLDIFS2
  done
else
  TARGET=$TPATH
  if [ -z "$TARGET" ] && [ "$NORMALIZED" = glob ] && [ -n "$GLOB_PATTERN" ]; then
    # A bare Glob pattern can carry the directory itself; classify its literal
    # prefix before the first glob character.
    TARGET=$GLOB_PATTERN
  fi
  case "$TARGET" in
    *[\*\?\[]*)
      TARGET=${TARGET%%[\*\?\[]*}
      TARGET=${TARGET%/*} ;;
  esac
  case "$TARGET" in
    "~") TARGET=$HOME ;;
    \~/*) TARGET=$HOME/${TARGET#\~/} ;;
  esac
  [ -n "$TARGET" ] || exit 0
  case "$TARGET" in
    /*) ;;
    *) TARGET=$CWD/$TARGET ;;
  esac
  ROOT=$(classify_path "$TARGET")
  if [ -n "$ROOT" ]; then
    if [ "$KIND" = write ]; then
      HARD_WORD=$NORMALIZED
      note_root hard "$ROOT"
    else
      note_root soft "$ROOT"
    fi
  fi
fi

[ -n "$HARD_ROOTS$SOFT_ROOTS" ] || exit 0

if [ -f "$FM_ROOT/bin/fm-scout.sh" ]; then
  ROUTE='first classify the work under the AGENTS.md intake contract: work already classified as a scout goes to bin/fm-scout.sh "<question>" [project], while authorized ship work and its bounded research go to bin/fm-brief.sh then bin/fm-spawn.sh'
else
  ROUTE='first classify the work under the AGENTS.md intake contract, then use bin/fm-brief.sh followed by bin/fm-spawn.sh for dispatched work'
fi

first_root() {
  local list=$1 r
  r=${list#|}
  printf '%s' "${r%%|*}"
}

deny() {
  local reason=$1 escaped
  escaped=$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

HATCH='For a deliberate captain-approved exception, re-run the exact command through Bash prefixed with FM_ALLOW_PROJECT_WORK=1.'

if [ -n "$HARD_ROOTS" ]; then
  deny "[delegate-project-work] the firstmate primary delegates project work instead of doing it: this $TOOL call is build-, run-, or write-shaped work ($HARD_WORD) inside project $(first_root "$HARD_ROOTS"), which is never a dispatch identity check. Instead, $ROUTE (blocked tool: $TOOL). $HATCH"
fi

# Budget: one read-shaped call per project per window is an identity check
# that makes a dispatch accurate; the second is an investigation.
WINDOW=${FM_DELEGATE_WINDOW:-120}
case "$WINDOW" in
  ''|*[!0-9]*) WINDOW=120 ;;
esac
NOW=${EPOCHSECONDS:-$(date +%s)}
BUDGET_FILE=$STATE/.delegate-guard-window
KEEP=""
SPENT=""
if [ -f "$BUDGET_FILE" ]; then
  while IFS=' ' read -r TS RROOT; do
    [ -n "$TS" ] && [ -n "$RROOT" ] || continue
    case "$TS" in *[!0-9]*) continue ;; esac
    [ $((NOW - TS)) -lt "$WINDOW" ] || continue
    KEEP="$KEEP$TS $RROOT
"
    SPENT="$SPENT|$RROOT|"
  done < "$BUDGET_FILE"
fi

OLDIFS=$IFS
IFS='|'
# shellcheck disable=SC2086
for ROOT in $SOFT_ROOTS; do
  IFS=$OLDIFS
  [ -n "$ROOT" ] || { IFS='|'; continue; }
  case "$SPENT" in
    *"|$ROOT|"*)
      deny "[delegate-project-work] the firstmate primary delegates project investigation instead of doing it: one read-shaped call per project per ${WINDOW}s is allowed as a dispatch identity check, and project $ROOT has spent it, so a second look this soon is a sequence - an investigation, which is a worker's job. Instead, $ROUTE (blocked tool: $TOOL). $HATCH" ;;
  esac
  KEEP="$KEEP$NOW $ROOT
"
  IFS='|'
done
IFS=$OLDIFS

# Stamp the allowed identity checks. Lost races only ever grant one extra read.
TMPFILE=$(mktemp "$STATE/.delegate-guard-window.XXXXXX" 2>/dev/null) || exit 0
printf '%s' "$KEEP" > "$TMPFILE" 2>/dev/null || { rm -f "$TMPFILE"; exit 0; }
mv -f "$TMPFILE" "$BUDGET_FILE" 2>/dev/null || rm -f "$TMPFILE"
exit 0
