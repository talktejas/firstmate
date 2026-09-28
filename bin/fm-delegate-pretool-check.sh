#!/usr/bin/env bash
# PreToolUse guard: the firstmate PRIMARY delegates project work, it never does it.
#
# The captain's standing order is that the primary session stays free for him
# and dispatches project work to workers. Instructions alone did not hold: the
# primary repeatedly slid from "one quick look" into grepping project source,
# reading migrations, running builds, and resolving merges while the captain
# waited. This guard makes that refused by mechanism rather than remembered.
#
# WHAT IT CLASSIFIES. A Bash, Read, Grep, Glob, Edit, Write, NotebookEdit, or
# MultiEdit call in a genuine primary home whose target resolves into a
# PROJECT: any git repository other than the firstmate home's own repo, plus
# anything under $FM_HOME/projects/ even when git cannot resolve it. Clones
# under projects/, the captain's own copies, and task worktrees are all such
# repositories; the rule is deliberately broad because the primary's job
# description makes any other repo's code a worker's territory. A linked
# worktree of the home's own repo shares its git common dir and stays
# classified as the home.
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
# work on a project's own service whatever their arguments look like; the home's
# own loopback services are the exception, listed once in HOME_SERVICE_PORTS.
# A path under projects/ that does not exist yet or is still empty is the
# onboarding surface, not a project: cloning and initializing a new project is
# the primary's own job until a real project is actually there.
# THE FORGE. The same work done over the network is the same work: a gh,
# gh-axi, or git command aimed at a project repository on the forge is refused
# unless it only reads pull-request, check, run, or issue state, which is how
# the primary decides to merge at all. firstmate's own repository - any slug
# among the home repo's remotes - is not a project. The forge classifier below
# owns the exact verbs; what it cannot place it refuses.
# There is no release token: a bypass the primary can type is the primary
# choosing to comply, which is the failure this guard replaces.
# fm-*.sh scripts (fm-pr-merge.sh and fm-pr-check.sh included), no-mistakes,
# and the *-axi tools are the primary's own job and always allowed, whatever
# paths they carry; gh-axi alone still meets the forge rule, because it is the
# forge.
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

# The home's own loopback services: the command center (docs/command-center.md)
# and the lavish review server (docs/lavish-connection-limit.md). Requests to
# these ports are the primary's own tooling, never a project's runtime. Every
# other loopback port belongs to a project's service.
HOME_SERVICE_PORTS=' 8765 4387 '

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
Denies a firstmate primary's Bash, Read, Grep, Glob, Edit, Write,
NotebookEdit, or MultiEdit call whose target is inside a project: any git
repository other than the home's own or another firstmate home, or anything
under $FM_HOME/projects/. Also denies gh, gh-axi, and git work on a project
repository through the forge, except reading pull-request, check, run, and
issue state. fm-*.sh, no-mistakes, and the *-axi tools are always allowed with
project paths; gh-axi still meets the forge rule.
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

# classify_projects_child <path>: print the project directory under the
# projects root that <path> falls into, or nothing when that directory does not
# exist yet or is still empty. Onboarding a new project - cloning into it, then
# initializing it - is the primary's own job, and the only honest way to tell
# onboarding from project work is the state of the target: the moment a real
# project is checked out there, the ordinary rule applies again.
classify_projects_child() {
  local p=$1 child
  child=${p#"$PROJECTS_ROOT"/}
  child=${child%%/*}
  [ -n "$child" ] || { printf '%s\n' "$PROJECTS_ROOT"; return 0; }
  child=$PROJECTS_ROOT/$child
  [ -e "$child" ] || return 0
  if [ -d "$child" ] && [ -z "$(ls -A "$child" 2>/dev/null)" ]; then
    return 0
  fi
  printf '%s\n' "$child"
}

# classify_path <path>: print the project root when <path> resolves into a
# project, print nothing when it belongs to the home or to no repo at all.
# Nonexistent paths resolve through their nearest existing ancestor, so an
# existence check on a project path is still classified while pattern junk
# that resolves back to the cwd is not.
classify_path() {
  local p=$1 dir top common info
  case "$p" in
    "$PROJECTS_ROOT") printf '%s\n' "$PROJECTS_ROOT"; return 0 ;;
    "$PROJECTS_ROOT"/*) classify_projects_child "$p"; return 0 ;;
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
    "$PROJECTS_ROOT") printf '%s\n' "$PROJECTS_ROOT"; return 0 ;;
    "$PROJECTS_ROOT"/*) classify_projects_child "$dir"; return 0 ;;
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

# trailing_escape <text>: true when <text> ends in an odd number of
# backslashes, so the character that follows it is escaped rather than syntax.
trailing_escape() {
  local t=$1 n=0
  while [ "${t%\\}" != "$t" ]; do
    t=${t%\\}
    n=$((n + 1))
  done
  [ $((n % 2)) -eq 1 ]
}

# quoted_scan <mode> <text>: walk <text> once, treating a single- or
# double-quoted span as data. Quote state carries across newlines, because a
# quoted argument - a steer message, a brief line - is routinely multi-line. An
# escaped quote neither opens nor closes a span, so the apostrophe idiom
# 'don'\''t' and an ANSI-C $'it\'s' argument both pair the way the shell pairs
# them - a backslash is syntax inside "..." and $'...', literal inside '...'.
# A span that never closes is not
# a span at all: its text is kept verbatim, so an unbalanced command falls back
# to ordinary separator and operator handling and fails toward the deny.
# Mode "strip" drops the quote characters and neutralizes separators inside the
# span so its words stay in their own segment. Mode "mask" blanks the span,
# quotes included, keeping its length and its newlines, so an operator written
# as prose inside a quoted argument is not an operator while every line and
# offset outside the span still lines up with the original text.
quoted_scan() {
  local mode=$1 rest=$2 out='' pre q body chunk span closed escapes word prev
  while [ -n "$rest" ]; do
    pre=''
    while :; do
      case "$rest" in
        *[\'\"]*) ;;
        *) pre=$pre$rest; rest=''; break ;;
      esac
      chunk=${rest%%[\'\"]*}
      if trailing_escape "$chunk"; then
        pre=$pre$chunk${rest:${#chunk}:1}
        rest=${rest:$((${#chunk} + 1))}
        continue
      fi
      pre=$pre$chunk
      rest=${rest#"$chunk"}
      break
    done
    out=$out$pre
    [ -n "$rest" ] || break
    q=${rest%"${rest#?}"}
    rest=${rest#?}
    escapes=0
    if [ "$q" = '"' ]; then
      escapes=1
    else
      case "$pre" in
        *\$) escapes=1 ;;
      esac
    fi
    body=''
    closed=0
    while :; do
      case "$rest" in
        *"$q"*) ;;
        *) break ;;
      esac
      chunk=${rest%%"$q"*}
      if [ "$escapes" -eq 1 ] && trailing_escape "$chunk"; then
        body=$body$chunk$q
        rest=${rest:$((${#chunk} + 1))}
        continue
      fi
      body=$body$chunk
      rest=${rest#"$chunk$q"}
      closed=1
      break
    done
    if [ "$closed" -eq 0 ]; then
      out=$out$q$body$rest
      break
    fi
    span=$q$body$q
    if [ "$mode" = mask ]; then
      out=$out${span//[!$'\n']/ }
    else
      # A shell wrapper's -c operand is a COMMAND, so its separators keep their
      # segmenting effect: an allow-listed lead word inside it must not release
      # the project commands that follow it. Every other quoted span, including
      # the operand of any other tool's -c flag, is data.
      word=${pre%"${pre##*[![:space:]]}"}
      prev=${word%"${word##*[[:space:]]}"}
      word=${word##*[[:space:]]}
      prev=${prev%"${prev##*[![:space:]]}"}
      prev=${prev##*[[:space:]]}
      case "$word/${prev##*/}" in
        -c/bash|-c/sh|-c/zsh|-lc/bash|-lc/sh|-lc/zsh) out=$out$body ;;
        *) out=$out${body//[$'\n\r;|&']/ } ;;
      esac
    fi
  done
  printf '%s' "$out"
}

# heredoc_delim <line> <masked-line>: the terminator a heredoc redirection on
# <line> opens, or nothing when the line opens none. The opener is located in
# the masked line, so a "<<EOF" inside a quoted message is prose wherever that
# message began; the terminator is then read from the original line, so
# cat <<'EOF' still works.
heredoc_delim() {
  local line=$1 masked=$2 pre t
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
  local rest=$1 masked line mline delim='' out=''
  masked=$(quoted_scan mask "$rest")
  while [ -n "$rest" ]; do
    line=${rest%%$'\n'*}
    mline=${masked%%$'\n'*}
    if [ "$line" = "$rest" ]; then
      rest=''
    else
      rest=${rest#*$'\n'}
      masked=${masked#*$'\n'}
    fi
    if [ -n "$delim" ]; then
      [ "${line#"${line%%[![:space:]]*}"}" = "$delim" ] && delim=''
      continue
    fi
    out=$out$line$'\n'
    case "$mline" in
      *'<<'*) delim=$(heredoc_delim "$line" "$mline") ;;
    esac
  done
  printf '%s' "$out"
}

# join_continuations <text>: join a line to the next one when it ends in an
# unescaped backslash. An escaped backslash is a literal argument, so the
# newline after it genuinely ends the command and still separates segments.
join_continuations() {
  local rest=$1 out='' chunk
  while :; do
    case "$rest" in
      *\\$'\n'*) ;;
      *) out=$out$rest; break ;;
    esac
    chunk=${rest%%\\$'\n'*}
    rest=${rest:$((${#chunk} + 2))}
    if trailing_escape "$chunk"; then
      out=$out$chunk\\$'\n'
    else
      out=$out$chunk' '
    fi
  done
  printf '%s' "$out"
}

# ---- Forge classification ------------------------------------------------
# THE FORGE RULE, in one sentence: through the forge a primary may do anything
# to firstmate's own repository, but on any other repository it may only read
# pull-request, check, run, and issue state - every write and every read of
# repository contents is refused. fm-*.sh scripts (fm-pr-merge.sh and
# fm-pr-check.sh included) release their segment before this runs, and a
# worker session is out of scope entirely. A command this classifier cannot
# place is refused, because the safe failure is an unneeded dispatch.

# Lead words that start a forge command wherever they sit in a segment, so an
# xargs, eval, or watch wrapper cannot launder one.
FORGE_WORDS=' gh gh-axi git '

# Hosts a curl/wget request reaches repository contents or the API through.
FORGE_HTTP_HOSTS=' github.com api.github.com raw.githubusercontent.com codeload.github.com '

HOME_SLUGS=""
HOME_SLUGS_SET=0
FORGE_WORD=""
FORGE_TARGET=""
FORGE_UNSURE=""

# forge_slug <url-or-repo>: print the lowercased OWNER/REPO a forge URL, an
# scp-style remote, or a gh [HOST/]OWNER/REPO argument names, or nothing.
forge_slug() {
  local t=$1 rest host path owner repo
  case "$t" in
    file://*) return 0 ;;
    *://*)
      rest=${t#*://}
      host=${rest%%/*}
      path=${rest#*/}
      [ "$path" != "$rest" ] || return 0
      host=${host##*@}
      host=${host%%:*}
      if [ "$host" = api.github.com ]; then
        case "$path" in
          repos/*) path=${path#repos/} ;;
          *) return 0 ;;
        esac
      fi ;;
    /*|.*) return 0 ;;
    *@*:*) path=${t#*:} ;;
    */*/*) path=${t#*/} ;;
    */*) path=$t ;;
    *) return 0 ;;
  esac
  owner=${path%%/*}
  repo=${path#*/}
  [ "$repo" != "$path" ] || return 0
  repo=${repo%%[/?#]*}
  repo=${repo%.git}
  [ -n "$owner" ] && [ -n "$repo" ] || return 0
  printf '%s/%s\n' "$owner" "$repo" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

# is_home_slug <slug>: true when <slug> is one of the home repo's own remotes.
# The set is read from the home's current remotes, and adding a remote for any
# other repository is itself refused below, so a project cannot join it.
is_home_slug() {
  local url s
  if [ "$HOME_SLUGS_SET" -eq 0 ]; then
    HOME_SLUGS_SET=1
    while IFS= read -r url; do
      s=$(forge_slug "$url")
      [ -n "$s" ] && HOME_SLUGS="$HOME_SLUGS $s "
    done <<<"$(git -C "$FM_ROOT" remote -v 2>/dev/null | awk '{print $2}')"
  fi
  case "$HOME_SLUGS" in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

forge_refuse() {
  # forge_refuse <word> <target> [unsure-reason]: record the first forge hit.
  [ -z "$FORGE_WORD" ] || return 0
  FORGE_WORD=$1
  FORGE_TARGET=$2
  FORGE_UNSURE=${3:-}
}

# forge_cwd_target: the project an implicit gh or git target falls into, taken
# from the directory the command runs in, or nothing for the home or no repo.
forge_cwd_target() {
  classify_path "${1:-$CWD}"
}

# classify_gh <word> <GH_REPO value> <args...>
classify_gh() {
  local word=$1 env_repo=$2 group='' sub='' pos3='' method='' fields=0 targets='' tok s op path t owner repo project=''
  local apiargs='' apipaths='' n=0 rawmedia=0
  shift 2
  for tok in "$@"; do
    case "$(printf '%s' "$tok" | LC_ALL=C tr '[:upper:]' '[:lower:]')" in
      *vnd.github*.diff*|*vnd.github*.patch*|*vnd.github*.raw*) rawmedia=1 ;;
    esac
    case "$tok" in
      repos/*/*|/repos/*/*|*://*) apipaths="$apipaths $tok" ;;
    esac
  done
  [ -z "$env_repo" ] || targets=" ${env_repo}"
  while [ "$#" -gt 0 ]; do
    tok=$1
    shift
    case "$tok" in
      --repo|-R) targets="$targets ${1:-?}"; shift ;;
      --repo=*) targets="$targets ${tok#--repo=}" ;;
      -R?*) targets="$targets ${tok#-R}" ;;
      -X|--method) method=${1:-}; shift ;;
      --method=*) method=${tok#--method=} ;;
      -X?*) method=${tok#-X} ;;
      -f|-F|--field|--raw-field|--input) fields=1; shift ;;
      --field=*|--raw-field=*|--input=*|-f?*|-F?*) fields=1 ;;
      -q|--jq|-t|--template|-H|--header|--hostname|--json|-L|--limit|-s|--state|-b|--body|--body-file|--title|-B|--base|--head|-l|--label|-a|--assignee|-m|--milestone|--cache|-p|--preview|-w|--workflow|--branch|-u|--user|-c|--commit|-e|--event|-j|--job|-A|--author|-S|--search)
        shift ;;
      -*) ;;
      *)
        [ "$group" != api ] || apiargs="$apiargs $tok"
        if [ -z "$group" ]; then group=$tok
        elif [ -z "$sub" ]; then sub=$tok
        elif [ -z "$pos3" ]; then pos3=$tok
        fi
        case "$tok" in
          *://*) [ "$group" = api ] || targets="$targets $tok" ;;
        esac ;;
    esac
  done
  op="$word $group${sub:+ $sub}"
  case "$group" in
    ''|auth|config|version|help|extension|alias|completion|status|gist|org|codespace|ssh-key|gpg-key|setup|project|attestation)
      return 0 ;;
  esac
  if [ "$group" = api ]; then
    op="$word api"
    path=''
    for t in $apipaths; do
      n=$((n + 1))
      [ -n "$path" ] || path=$t
      case "$t" in
        repos/\{owner\}/\{repo\}*|/repos/\{owner\}/\{repo\}*) ;;
        *://*) targets="$targets $(forge_slug "$t")" ;;
        *) t=${t#/}; t=${t#repos/}; owner=${t%%/*}; t=${t#*/}; targets="$targets $owner/${t%%/*}" ;;
      esac
    done
    if [ -z "$path" ]; then
      path=$sub
      for t in $apiargs; do n=$((n + 1)); done
      [ "$path" = graphql ] || [ "$n" -le 1 ] || {
        forge_refuse "$op" "" "its api path cannot be told apart from its option values"
        return 0
      }
      n=0
    fi
    case "$path" in
      graphql) forge_refuse "$op graphql" "" "a GraphQL request can reach any repository"; return 0 ;;
      *://*) path=${path#*://}; path=${path#*/} ;;
    esac
    path=${path#/}
    path=${path%%\?*}
    method=$(printf '%s' "${method:-}" | LC_ALL=C tr '[:lower:]' '[:upper:]')
    [ -n "$method" ] || { [ "$fields" -eq 1 ] && method=POST || method=GET; }
    case "$path" in
      repos/\{owner\}/\{repo\}*) path=${path#repos/\{owner\}/\{repo\}} ;;
      repos/*/*)
        t=${path#repos/}
        t=${t#*/}
        path=${t#*/}
        [ "$path" != "$t" ] || path='' ;;
      *)
        if [ "$n" -le 1 ]; then
          [ "$method" = GET ] && return 0
          forge_refuse "$op $method" "" "it writes outside a repository the guard can name"
          return 0
        fi ;;
    esac
    [ "$n" -le 1 ] || path='?'
    path=${path#/}
    sub="$method /$path"
  elif [ "$group" = repo ]; then
    case "$sub" in
      create|list|clone) return 0 ;;
    esac
    case "$pos3" in
      */*) targets="$targets $pos3" ;;
    esac
  elif [ "$group" = search ]; then
    [ "$sub" = code ] || return 0
  fi
  # Resolve every named target; no named target means gh's own default, the
  # repository of the directory it runs in.
  if [ -z "${targets// /}" ]; then
    project=$(forge_cwd_target)
  else
    for t in $targets; do
      if [ "$t" = '?' ]; then project='an unnamed repository'; break; fi
      s=$(forge_slug "$t")
      [ -n "$s" ] || { project=$t; break; }
      is_home_slug "$s" || { project=$s; break; }
    done
  fi
  [ -n "$project" ] || return 0
  # Supervision reads: the state of a pull request, a check, a run, or an issue.
  case "$group $sub" in
    'pr view'|'pr list'|'pr status'|'pr checks'|'run list'|'run view'|'run watch'|'issue view'|'issue list'|'issue status'|'workflow list'|'stack view')
      return 0 ;;
    'api GET /'*)
      [ "$rawmedia" -eq 0 ] || { forge_refuse "$op" "$project"; return 0; }
      path=${sub#GET /}
      case "$path" in
        pulls/*/files*|pulls/*/comments*|pulls/comments*) ;;
        pulls|pulls/*|issues|issues/*|check-runs/*|check-suites/*|actions/runs|actions/runs/*|actions/jobs/*|actions/workflows|actions/workflows/*|statuses/*|commits/*/check-runs*|commits/*/check-suites*|commits/*/status|commits/*/statuses*)
          return 0 ;;
      esac ;;
  esac
  forge_refuse "$op" "$project"
}

# classify_git <args...>: refuse a network git command aimed at a repository
# other than the home's own, named by URL, by remote name, or implied by the
# default remote of the directory it runs in.
classify_git() {
  local dir=$CWD sub='' tok s url explicit=0 remotes root
  while [ "$#" -gt 0 ]; do
    tok=$1
    shift
    case "$tok" in
      -C) dir=${1:-.}; shift ;;
      -C?*) dir=${tok#-C} ;;
      -c|--git-dir|--work-tree|--namespace|--exec-path) shift ;;
      -*) ;;
      *) sub=$tok; break ;;
    esac
  done
  case "$sub" in
    push|fetch|pull|ls-remote|remote|archive) ;;
    *) return 0 ;;
  esac
  case "$dir" in
    /*) ;;
    "~") dir=$HOME ;;
    \~/*) dir=$HOME/${dir#\~/} ;;
    *) dir=$CWD/$dir ;;
  esac
  root=$(forge_cwd_target "$dir")
  if [ -n "$root" ]; then
    forge_refuse "git $sub" "$root"
    return 0
  fi
  remotes=$(git -C "$dir" remote -v 2>/dev/null | awk '{print $1" "$2}')
  for tok in "$@"; do
    url=""
    case "$tok" in
      --remote=*|--repo=*) url=${tok#*=} ;;
      -*) continue ;;
      *://*|*@*:*) url=$tok ;;
      *)
        url=$(printf '%s\n' "$remotes" | awk -v n="$tok" '$1 == n {print $2; exit}') ;;
    esac
    [ -n "$url" ] || continue
    explicit=1
    s=$(forge_slug "$url")
    if [ -n "$s" ] && ! is_home_slug "$s"; then
      forge_refuse "git $sub" "$s"
      return 0
    fi
  done
  [ "$explicit" -eq 0 ] || return 0
  # No named remote: git uses a default remote, so every remote this directory
  # has must be the home's own.
  while IFS=' ' read -r tok url; do
    [ -n "$url" ] || continue
    s=$(forge_slug "$url")
    if [ -n "$s" ] && ! is_home_slug "$s"; then
      forge_refuse "git $sub" "$s" "its default remote may be another repository"
      return 0
    fi
  done <<<"$remotes"
}

# forge_segment <lead> <segment>: classify the forge command in one segment.
forge_segment() {
  local lead=$1 seg=$2 tok raw env_repo='' i=0 start=-1 word='' host s
  local -a toks=()
  # shellcheck disable=SC2086
  for tok in $seg; do
    raw=$tok
    raw=${raw#\$\(}
    while :; do
      case "$raw" in
        \(*|\"*|\'*|\`*|\\*) raw=${raw#?} ;;
        *) break ;;
      esac
    done
    while :; do
      case "$raw" in
        *\)|*\"|*\'|*\`) raw=${raw%?} ;;
        *) break ;;
      esac
    done
    toks+=("$raw")
  done
  [ "${#toks[@]}" -gt 0 ] || return 0
  case "$HTTP_WORDS" in
    *" $lead "*)
      for tok in "${toks[@]}"; do
        case "$tok" in
          *://*) ;;
          *) continue ;;
        esac
        host=${tok#*://}
        host=${host%%/*}
        host=${host##*@}
        case "$FORGE_HTTP_HOSTS" in
          *" $host "*) ;;
          *) continue ;;
        esac
        s=$(forge_slug "$tok")
        if [ -n "$s" ] && ! is_home_slug "$s"; then
          forge_refuse "$lead" "$s"
          return 0
        fi
      done ;;
  esac
  for tok in "${toks[@]}"; do
    case "$tok" in
      GH_REPO=*) [ "$start" -ge 0 ] || env_repo=${tok#GH_REPO=} ;;
    esac
    if [ "$start" -lt 0 ]; then
      case "$FORGE_WORDS" in
        *" ${tok##*/} "*) start=$i; word=${tok##*/} ;;
      esac
    fi
    i=$((i + 1))
  done
  [ "$start" -ge 0 ] || return 0
  if [ "$word" = git ]; then
    classify_git "${toks[@]:$((start + 1))}"
  else
    classify_gh "$word" "$env_repo" "${toks[@]:$((start + 1))}"
  fi
}

if [ "$KIND" = command ]; then
  # An unquoted newline separates commands; a newline inside a quoted argument,
  # inside a heredoc body, or after a backslash line continuation does not, so
  # the lines of a steer message and the tail of a continued dispatch line stay
  # with the command that owns them while a command on its own line is
  # classified on its own.
  SEGSTR=$(join_continuations "$(quoted_scan strip "$(strip_heredocs "$CMD")")")
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
      AUTH=${RAW#*://}
      AUTH=${AUTH%%[/?#]*}
      AUTH=${AUTH##*@}
      case "$AUTH" in
        localhost|localhost:*|127.*|0.0.0.0|0.0.0.0:*|\[::1\]|\[::1\]:*)
          PORT=${AUTH##*:}
          PORT=${PORT%%[!0-9]*}
          case "$HOME_SERVICE_PORTS" in
            *" $PORT "*) ;;
            *) SEG_LOOPBACK=1 ;;
          esac ;;
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
    # The forge is classified for every segment except one the primary's own
    # fleet tooling leads; gh-axi is the exception, because it is the forge.
    FORGE_EXEMPT=0
    case "$LEAD" in
      fm-*.sh) FORGE_EXEMPT=1 ;;
    esac
    case "$ALLOW_WORDS" in
      *" $LEAD "*) [ "$LEAD" = gh-axi ] || FORGE_EXEMPT=1 ;;
    esac
    [ "$FORGE_EXEMPT" -eq 1 ] || [ -n "$FORGE_WORD" ] || forge_segment "$LEAD" "$SEG"
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

[ -n "$ROOTS$RUNTIME_HIT$FORGE_WORD" ] || exit 0

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

if [ -n "$FORGE_UNSURE" ]; then
  deny "[delegate-project-work] the firstmate primary delegates project work instead of doing it: this $TOOL call ($FORGE_WORD) reaches the forge in a way the guard cannot confidently classify as firstmate's own repository or a supervision read - $FORGE_UNSURE - so it is refused rather than guessed at. Instead, $ROUTE (blocked tool: $TOOL)."
fi
if [ -n "$FORGE_WORD" ]; then
  deny "[delegate-project-work] the firstmate primary delegates project work instead of doing it: this $TOOL call ($FORGE_WORD) works on project repository $FORGE_TARGET through the forge, where only reading pull-request, check, run, and issue state is the primary's own; merging goes through bin/fm-pr-merge.sh and recording through bin/fm-pr-check.sh. Instead, $ROUTE (blocked tool: $TOOL)."
fi

deny "[delegate-project-work] the firstmate primary delegates project work instead of doing it: this $TOOL call ($RUNTIME_HIT) drives a project's containers, database, or running service, which is a worker's job. Instead, $ROUTE (blocked tool: $TOOL)."
