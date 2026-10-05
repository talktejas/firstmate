#!/usr/bin/env bash
# fm-intake-route.sh - advisory project and second mate for an incoming request
# or bug report, from typesafe.ai's System One model (Jev), opt-in.
#
# Usage:
#   fm-intake-route.sh [<request-file>]     (the request text on stdin when no
#                                            file, or `-`, is given)
#
# Run by firstmate at intake, before it resolves the request's project and
#   owner under AGENTS.md section 7, which owns that resolution. No worker
#   runs it.
#
# Opt-in gate: TYPESAFE_API_KEY is available under the same
#   environment-then-$FM_HOME/.env contract as bin/fm-dispatch-resolve.sh.
#   Absent: one "intake-route: off" line on stderr, nothing on stdout, exit 0,
#   no network call. bin/fm-jev-lib.sh owns the key handling, the request, the
#   credential-line filter, and the answer validation, and is the only Jev
#   caller here. No project's code is read or sent, so config/jev-code-projects
#   is not consulted.
#
# Where the choices come from, read fresh on every run and never hardcoded:
#   - projects: `bin/fm-project-mode.sh --list`, every entry of
#     data/projects.md not marked `finished`;
#   - second mates: every record of data/secondmates.md that
#     bin/fm-secondmate-registry-lib.sh parses.
#
# What it does when on: code decides every fact first. An empty request, a
#   request over INTAKE_ROUTE_MAX_BYTES bytes (nothing is cut to fit), or a
#   registry with no unfinished project is left by hand without a request.
#   Otherwise ONE request through fm_jev_choices carries the request text, each
#   project's registry description, and each second mate's registered scope as
#   state, and asks `project` (one option per project, plus `none`) and, only
#   when a second mate is registered, `secondmate` (one option per second mate,
#   plus `main`). Code then overrides the second-mate answer with `main` when
#   the advised project is registered `local-only`, which never leaves the
#   main home.
#
# Output (stdout), one line per question:
#     project: <name> (confidence <c>)
#     secondmate: <id> (confidence <c>)  |  secondmate: main (<why>)
#   only when that choice's confidence reaches the shared
#   FM_JEV_CONFIDENCE_FLOOR, or
#     project: by hand (<why>)           |  secondmate: by hand (<why>)
#   for every other answer, and one summary line on stderr.
#
# Authority: advice only. Every outcome exits 0 - no key, no registry, an
#   unusable request, a timeout, a malformed answer, low confidence - and
#   nothing here spawns, steers, files, or writes any record; a failure means
#   firstmate resolves the project and owner by hand, as without the feature.
#   Exit 2 only for a usage error.
set -u

# Sourced before anything can start a child: it takes the key out of the
# exported environment. The path is derived with builtins for the same reason.
_fm_route_dir=${BASH_SOURCE[0]%/*}
[ "$_fm_route_dir" != "${BASH_SOURCE[0]}" ] || _fm_route_dir=.
# shellcheck source=bin/fm-jev-lib.sh
. "$_fm_route_dir/fm-jev-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$_fm_route_dir/fm-secondmate-registry-lib.sh"

INTAKE_ROUTE_MAX_BYTES=20000
# shellcheck disable=SC2016 # Backticks are literal Markdown for the model.
INTAKE_ROUTE_QUESTIONS='{
  project: {
    instructions: "`request` is an incoming work request or bug report. `projects` describes each registered project. Which ONE project is `request` about? Choose `none` whenever no project clearly fits, more than one fits equally well, or you are unsure.",
    criteria: (($projects | with_entries(.value = "`request` is about the project described at `projects.\(.key)`."))
      + {none: "No single project in `projects` is clearly the one `request` is about."})
  }
} + (if ($secondmates | length) == 0 then {} else {
  secondmate: {
    instructions: "`request` is an incoming work request or bug report. `secondmates` gives the scope of work each second mate owns. Whose scope covers the work `request` asks for? Choose `main` whenever no scope clearly covers it, more than one covers it equally well, or you are unsure.",
    criteria: (($secondmates | with_entries(.value = "The work `request` asks for falls inside the scope at `secondmates.\(.key)`."))
      + {main: "No single scope in `secondmates` clearly covers the work `request` asks for."})
  }
} end)'

intake_route_usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

intake_route_main() {
  local src=- fm_root data request projects mates='' line tmp=''
  if [ $# -gt 0 ]; then
    case "$1" in
      -h|--help) intake_route_usage; return 0 ;;
      -) ;;
      -*) echo "error: unknown argument $1 (see --help)" >&2; return 2 ;;
      *) src=$1 ;;
    esac
    [ $# -eq 1 ] || { echo "error: one request file only (see --help)" >&2; return 2; }
  fi
  fm_root=$(cd "$_fm_route_dir/.." && pwd)
  FM_HOME=${FM_HOME:-$fm_root}
  data=${FM_DATA_OVERRIDE:-$FM_HOME/data}

  if ! fm_jev_key_load "$FM_HOME"; then
    echo "intake-route: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env)" >&2
    return 0
  fi
  by_hand() {  # <why>
    [ -z "$tmp" ] || rm -rf "$tmp"
    printf 'project: by hand (%s)\nsecondmate: by hand (%s)\n' "$1" "$1"
    echo "intake-route: by hand; $1" >&2
    return 0
  }
  if [ "$src" != - ] && [ ! -r "$src" ]; then
    echo "error: request file not readable: $src" >&2; return 2
  fi
  command -v jq >/dev/null 2>&1 || { by_hand "jq not installed"; return; }
  tmp=$(mktemp -d) || { by_hand "mktemp failed"; return; }
  INTAKE_ROUTE_TMP=$tmp
  # One byte past the bound is enough to know the request is over it.
  if [ "$src" = - ]; then head -c $((INTAKE_ROUTE_MAX_BYTES + 1)) > "$tmp/request"
  else head -c $((INTAKE_ROUTE_MAX_BYTES + 1)) "$src" > "$tmp/request"; fi
  request=$(cat "$tmp/request")
  if [ -z "$(printf '%s' "$request" | tr -d '[:space:]')" ]; then
    by_hand "the request is empty"; return
  fi
  if [ "$(wc -c < "$tmp/request")" -gt "$INTAKE_ROUTE_MAX_BYTES" ]; then
    by_hand "the request is over $INTAKE_ROUTE_MAX_BYTES bytes"; return
  fi
  projects=$(FM_HOME=$FM_HOME "$_fm_route_dir/fm-project-mode.sh" --list 2>/dev/null)
  if [ -z "$projects" ]; then
    by_hand "no unfinished project in $data/projects.md"; return
  fi
  if [ -r "$data/secondmates.md" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      secondmate_registry_parse_line "$line" || continue
      mates+="$SECONDMATE_REGISTRY_ID"$'\t'"${SECONDMATE_REGISTRY_SCOPE//$'\t'/ }"$'\n'
    done < "$data/secondmates.md"
  fi

  # Every piece of registry text goes in the state, where the library withholds
  # credential-looking lines; the criteria only point at it by option key.
  jq -n --rawfile request "$tmp/request" --arg projects "$projects" --arg mates "$mates" '
    def rows($t; $p): [$t | split("\n")[] | select(length > 0) | split("\t")]
      | to_entries | map({key: "\($p)\(.key + 1)", value: .value}) | from_entries;
    {request: $request,
     projects: (rows($projects; "p") | map_values({name: .[0], mode: .[1], about: .[2]})),
     secondmates: (rows($mates; "s") | map_values({id: .[0], scope: .[1]}))}' > "$tmp/all" \
    || { by_hand "request could not be built"; return; }
  jq 'del(.projects[].mode)' "$tmp/all" > "$tmp/state"
  jq -n --argjson projects "$(jq .projects "$tmp/all")" --argjson secondmates "$(jq .secondmates "$tmp/all")" \
    "$INTAKE_ROUTE_QUESTIONS" > "$tmp/questions" \
    || { by_hand "request could not be built"; return; }
  if ! fm_jev_choices "$tmp/questions" "$tmp/state" project; then
    by_hand "no answer: $FM_JEV_ERROR"; return
  fi

  jq -r --argjson floor "$FM_JEV_CONFIDENCE_FLOOR" --slurpfile all "$tmp/all" '
    $all[0] as $s | .answers.project as $p | .answers.secondmate as $m |
    ($s.projects[$p.choice // ""] // null) as $proj |
    ($p != null and $proj != null and $p.confidence >= $floor) as $sure |
    (if $p == null then "by hand (no usable answer)"
     elif $proj == null then "by hand (no single project fits, confidence \($p.confidence))"
     elif $sure then "\($proj.name) (confidence \($p.confidence))"
     else "by hand (\($proj.name) below the confidence floor, \($p.confidence))" end) as $pline |
    ($s.secondmates[$m.choice // ""] // null) as $mate |
    (if ($s.secondmates | length) == 0 then "main (no second mate registered)"
     elif $sure and $proj.mode == "local-only" then "main (\($proj.name) is local-only)"
     elif $m == null then "by hand (no usable answer)"
     elif $m.confidence < $floor then "by hand (\($mate.id // "main") below the confidence floor, \($m.confidence))"
     elif $mate == null then "main (no scope fits, confidence \($m.confidence))"
     else "\($mate.id) (confidence \($m.confidence))" end) as $mline |
    "project: \($pline)", "secondmate: \($mline)"' <<<"$FM_JEV_ANSWERS"
  rm -rf "$tmp"
  echo "intake-route: advice only, from one request; firstmate resolves the project and owner itself" >&2
  return 0
}

INTAKE_ROUTE_TMP=
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  trap '[ -z "$INTAKE_ROUTE_TMP" ] || rm -rf "$INTAKE_ROUTE_TMP"' EXIT
  intake_route_main "$@"
  exit
fi
