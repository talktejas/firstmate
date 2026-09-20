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
# THE RULE. A project-targeted call is denied whatever its shape. Reading a
# project is how "one quick look" becomes a working session, and every fact a
# dispatch needs reaches the primary through its workers and through the
# always-allowed fleet tooling, so there is no allowance to pace. A firstmate
# home clone - a secondmate home, a pool or treehouse home - carries the home
# contract (AGENTS.md plus the bin dispatch scripts) and is the primary's own
# supervision territory, so it classifies with the home and not as a project.
# A narrow set of project-runtime verbs denies without a path at all: container
# tooling, database clients, and an http request aimed at a loopback address are
# work on a project's own service whatever their arguments look like.
# There is no release token: a bypass the primary can type is the primary
# choosing to comply, which is the failure this guard replaces.
# fm-*.sh scripts, no-mistakes, and the *-axi tools are the primary's own job
# and always allowed, whatever paths they carry.
# See docs/delegate-guard.md for the complete contract and validation record.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-delegate-pretool-check.sh
#   bin/fm-delegate-pretool-check.sh --tool Bash --command '<cmd>' [--cwd <dir>]
#   bin/fm-delegate-pretool-check.sh --tool Read --path '<file>'
#
# Stdin mode extracts .tool_name/.tool_input for Claude, Codex, and Cursor, or
# .toolName/.toolInput for Grok. Cursor's shell tool_name is "Shell" and Grok's
# is "run_terminal_command" (the names the tracked sibling seatbelt
# registrations already match), so both classify as command calls. CLI mode is
# for adapters that already hold the values (OpenCode, Pi) and for tests.
#
# Exit/output contract (identical shape to bin/fm-subagent-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   DENY, --cursor - exit 0 and Cursor's own decision object on stdout. Cursor
#          reads the returned object rather than the exit status.
#   INERT - not a genuine primary home (a crewmate/scout task worktree or a
#           non-firstmate repo): exit 0 with no output, exactly like ALLOW.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport, or
#               an unconfirmable home identity.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
# Cursor consumes the stdout decision object.
set -u
# Tokens from the command string are inspected verbatim; never glob-expand them.
set -f

# Per-segment lead words that are the primary's own job and release the whole
# segment, whatever project paths it carries: dispatch and lifecycle scripts
# take project directories as arguments by design.
ALLOW_WORDS=' no-mistakes gh-axi tasks-axi quota-axi lavish-axi chrome-devtools-axi '

# Lead words that mean project work whatever their arguments: a project's own
# containers and its database are a worker's territory, never the primary's.
RUNTIME_WORDS=' docker docker-compose podman podman-compose psql mysql mariadb mongosh redis-cli '

# http clients, denied only when the request targets a loopback address, which
# is a project's own running service.
HTTP_WORDS=' curl wget http https httpie xh '

TOOL=""
TOOL_SET=0
CMD=""
TPATH=""
CWD=""
CLAUDE_MODE=0
CURSOR_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-delegate-pretool-check.sh [--tool <name>] [--command <cmd>] [--path <p>] [--cwd <dir>] [--claude|--cursor]

With no --tool, reads a PreToolUse-style JSON payload on stdin (Claude/Codex
tool_name and tool_input, or Grok toolName and toolInput).
Denies a firstmate primary's Bash, Read, Grep, Glob, Edit, Write, or
NotebookEdit call whose target is inside a project: any git repository other
than the home's own or another firstmate home, or anything under
$FM_HOME/projects/. fm-*.sh, no-mistakes, and the *-axi tools are always
allowed.
Fires only in a genuine firstmate primary home; it is a silent no-op in a
crewmate/scout task worktree or any non-firstmate repo, where a worker
investigating project code is exactly right.
Exits 0 to allow and 2 to deny, naming the crewmate dispatch path instead.
With --cursor, a deny is Cursor's own decision object on stdout and exit 0,
because Cursor reads the returned object rather than the exit status.
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
    --cursor) CURSOR_MODE=1; shift ;;
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
  # shellcheck source=bin/fm-hook-host-lib.sh
  # shellcheck disable=SC1091
  . "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/fm-hook-host-lib.sh"
  # Cursor's own registration passes --cursor. Without it a Cursor-delivered
  # payload is the Claude-settings duplicate Cursor also loads, already
  # evaluated by that registration, so this copy allows without re-classifying.
  if [ "$CURSOR_MODE" -eq 0 ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  # One jq per payload: this hook fires on every classified tool call the
  # primary makes, so every field is read from a single parse. The command is
  # emitted last because it is the only field that can carry newlines.
  FIELDS=$(printf '%s' "$PAYLOAD" | jq -r '
    (.tool_name // .toolName // ""),
    (.tool_input.file_path // .tool_input.notebook_path // .tool_input.path
      // .toolInput.file_path // .toolInput.notebook_path // .toolInput.path // ""),
    (.tool_input.pattern // .toolInput.pattern // ""),
    (.cwd // ""),
    (.tool_input.command // .toolInput.command // "")' 2>/dev/null) || exit 0
  {
    read -r TOOL || true
    read -r TPATH || true
    read -r GLOB_PATTERN || true
    read -r CWD || true
    CMD=$(cat)
  } <<<"$FIELDS"
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
  bash|shell|run_terminal_command) KIND="command" ;;
  read|grep|glob) KIND="read" ;;
  edit|write|notebookedit|multiedit) KIND="write" ;;
  *) exit 0 ;;
esac

if [ "$KIND" = command ]; then
  [ -n "$CMD" ] || exit 0
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

# repo_info <dir>: print the toplevel of the repo containing <dir> and its
# physical git common dir, one per line, in a single git call. A relative
# common dir is relative to <dir>, which is the directory git was pointed at.
repo_info() {
  local dir=$1 out top c
  out=$(git -C "$dir" rev-parse --show-toplevel --git-common-dir 2>/dev/null) || return 1
  top=${out%%$'\n'*}
  c=${out#*$'\n'}
  [ -n "$top" ] && [ -n "$c" ] && [ "$top" != "$c" ] || return 1
  case "$c" in
    /*) ;;
    *) c=$dir/$c ;;
  esac
  c=$(CDPATH='' cd -- "$c" 2>/dev/null && pwd -P) || return 1
  printf '%s\n%s\n' "$top" "$c"
}

HOME_INFO=$(repo_info "$FM_ROOT") || exit 0
HOME_COMMON=${HOME_INFO#*$'\n'}
HOME_COMMON=${HOME_COMMON%%$'\n'*}
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
  local p=$1 dir top common info
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
  info=$(repo_info "$dir") || return 0
  top=${info%%$'\n'*}
  common=${info#*$'\n'}
  common=${common%%$'\n'*}
  [ "$common" != "$HOME_COMMON" ] || return 0
  # A firstmate home clone carries the home contract; supervising one is the
  # primary's own job, so it classifies with the home rather than as a project.
  [ -f "$top/AGENTS.md" ] && [ -f "$top/bin/fm-spawn.sh" ] && [ -f "$top/bin/fm-brief.sh" ] && return 0
  printf '%s\n' "$top"
}

# expand_token <token>: sanitize one whitespace token into an absolute path
# candidate, or print nothing.
expand_token() {
  local tok=$1
  tok=${tok#\$\(}
  case "$tok" in
    [0-9][\<\>]*|\&[\<\>]*) tok=${tok#?} ;;
  esac
  while :; do
    case "$tok" in
      [\<\>]*) tok=${tok#?} ;;
      *) break ;;
    esac
  done
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

ROOTS=""
BLOCKED_WORD=""
RUNTIME_HIT=""
PATHS_SEEN=0

note_root() {
  # note_root <root>: record a classified project root once.
  local root=$1
  case "$ROOTS" in
    *"|$root|"*) ;;
    *) ROOTS="$ROOTS|$root|" ;;
  esac
}

# quoted_scan <mode> <text>: walk <text> once, treating a single- or
# double-quoted span as data. Mode "strip" drops the quote characters and
# neutralizes separators inside the span, so a quoted argument - a steer
# message, a brief line - is never re-read as a new command while its words
# stay in their own segment. Mode "mask" replaces the span, quotes included,
# with the same number of spaces, so an operator written as prose inside a
# quoted argument is not an operator, while every offset outside the span still
# lines up with the original text.
quoted_scan() {
  local mode=$1 rest=$2 out='' pre q body pad
  while :; do
    case "$rest" in
      *[\'\"]*) ;;
      *) out=$out$rest; break ;;
    esac
    pre=${rest%%[\'\"]*}
    out=$out$pre
    rest=${rest#"$pre"}
    q=${rest%"${rest#?}"}
    rest=${rest#?}
    case "$rest" in
      *"$q"*) body=${rest%%"$q"*}; rest=${rest#"$body$q"}; pad=$((${#body} + 2)) ;;
      *) body=$rest; rest=''; pad=$((${#body} + 1)) ;;
    esac
    if [ "$mode" = mask ]; then
      printf -v body '%*s' "$pad" ''
      out=$out$body
    else
      out=$out${body//[$'\n\r;|&']/ }
    fi
  done
  printf '%s' "$out"
}

# heredoc_delim <line>: the terminator a heredoc redirection on <line> opens,
# or nothing when the line opens none. The opener is located in the masked copy
# of the line, so a "<<EOF" inside a quoted message is prose; the terminator is
# then read from the original line, so cat <<'EOF' still works.
heredoc_delim() {
  local line=$1 masked pre t
  masked=$(quoted_scan mask "$line")
  case "$masked" in
    *'<<'*) ;;
    *) return 0 ;;
  esac
  pre=${masked%%'<<'*}
  t=${line:$((${#pre} + 2))}
  case "$t" in
    \<*) return 0 ;;
  esac
  t=${t#-}
  t=${t#"${t%%[![:space:]]*}"}
  t=${t%%[[:space:]]*}
  t=${t//\"/}
  t=${t//\'/}
  printf '%s' "$t"
}

# strip_heredocs <cmd>: drop every heredoc body and terminator. A brief written
# into the primary's own home carries project paths in its body, and that body
# is data, not a command sequence.
strip_heredocs() {
  local rest=$1 line delim='' out=''
  while [ -n "$rest" ]; do
    line=${rest%%$'\n'*}
    if [ "$line" = "$rest" ]; then rest=''; else rest=${rest#*$'\n'}; fi
    if [ -n "$delim" ]; then
      [ "${line#"${line%%[![:space:]]*}"}" = "$delim" ] && delim=''
      continue
    fi
    out=$out$line$'\n'
    case "$line" in
      *'<<'*) delim=$(heredoc_delim "$line") ;;
    esac
  done
  printf '%s' "$out"
}

if [ "$KIND" = command ]; then
  # An unquoted newline separates commands; a newline inside a quoted argument,
  # inside a heredoc body, or after a backslash line continuation does not, so
  # the lines of a steer message and the tail of a continued dispatch line stay
  # with the command that owns them while a command on its own line is
  # classified on its own.
  SEGSTR=$(quoted_scan strip "$(strip_heredocs "$CMD")")
  SEGSTR=${SEGSTR//\\$'\n'/ }
  SEGSTR=${SEGSTR//\\$'\r'/ }
  SEGSTR=${SEGSTR//&&/;}
  SEGSTR=${SEGSTR//\|\|/;}
  SEGSTR=${SEGSTR//\|/;}
  SEGSTR=${SEGSTR//&/;}
  OLDIFS=$IFS
  IFS=$';\n\r'
  # shellcheck disable=SC2086
  set -- $SEGSTR
  IFS=$OLDIFS
  for SEG in "$@"; do
    # Lead word: first token that is not an assignment or a plain wrapper.
    # It decides only whether the segment is the primary's own fleet tooling;
    # every other project-targeted segment is denied, whatever it runs.
    LEAD=""
    WRAPPED=0
    SEG_PATHS=""
    SEG_LOOPBACK=0
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
        case "${RAW##*/}" in
          env|exec|command|nohup|time|sudo|timeout|bash|sh|zsh) WRAPPED=1; continue ;;
        esac
        case "$RAW" in
          ''|[A-Za-z_]*=*) continue ;;
        esac
        # A wrapper's own options and timeout's duration are not the lead word.
        if [ "$WRAPPED" -eq 1 ]; then
          case "$RAW" in
            -*|[0-9]*) continue ;;
          esac
        fi
        LEAD=${RAW##*/}
      fi
      case "$RAW" in
        *://localhost*|*://127.*|*://0.0.0.0*|*://\[::1\]*|localhost:[0-9]*|127.0.0.1:[0-9]*)
          SEG_LOOPBACK=1 ;;
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
    SEG_RUNTIME=0
    case "$RUNTIME_WORDS" in
      *" $LEAD "*) SEG_RUNTIME=1 ;;
    esac
    if [ "$SEG_LOOPBACK" -eq 1 ]; then
      case "$HTTP_WORDS" in
        *" $LEAD "*) SEG_RUNTIME=1 ;;
      esac
    fi
    [ -n "$SEG_PATHS" ] || [ "$SEG_RUNTIME" -eq 1 ] || continue
    case "$ALLOW_WORDS" in
      *" $LEAD "*) continue ;;
    esac
    case "$LEAD" in
      fm-*.sh) continue ;;
    esac
    BLOCKED_WORD=${BLOCKED_WORD:-$LEAD}
    [ "$SEG_RUNTIME" -eq 1 ] && RUNTIME_HIT=${RUNTIME_HIT:-$LEAD}
    OLDIFS2=$IFS
    IFS='|'
    # shellcheck disable=SC2086
    for ROOT in $SEG_PATHS; do
      IFS=$OLDIFS2
      [ -n "$ROOT" ] && note_root "$ROOT"
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
    BLOCKED_WORD=$NORMALIZED
    note_root "$ROOT"
  fi
fi

[ -n "$ROOTS$RUNTIME_HIT" ] || exit 0

if [ -f "$FM_ROOT/bin/fm-scout.sh" ]; then
  ROUTE='first classify the work under the AGENTS.md intake contract: work already classified as a scout goes to bin/fm-scout.sh "<question>" [project], while authorized ship work and its bounded research go to bin/fm-brief.sh then bin/fm-spawn.sh'
else
  ROUTE='first classify the work under the AGENTS.md intake contract, then use bin/fm-brief.sh followed by bin/fm-spawn.sh for dispatched work'
fi

deny() {
  local reason=$1 escaped
  escaped=$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  if [ "$CURSOR_MODE" -eq 1 ]; then
    printf '{"permission":"deny","user_message":"%s"}\n' "$escaped"
    exit 0
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

if [ -n "$ROOTS" ]; then
  FIRST_ROOT=${ROOTS#|}
  FIRST_ROOT=${FIRST_ROOT%%|*}
  deny "[delegate-project-work] the firstmate primary delegates project work instead of doing it: this $TOOL call ($BLOCKED_WORD) targets project $FIRST_ROOT, and project work - reading it included - belongs to a worker. Instead, $ROUTE (blocked tool: $TOOL)."
fi

deny "[delegate-project-work] the firstmate primary delegates project work instead of doing it: this $TOOL call ($RUNTIME_HIT) drives a project's containers, database, or running service, which is a worker's job. Instead, $ROUTE (blocked tool: $TOOL)."
