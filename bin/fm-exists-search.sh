#!/usr/bin/env bash
# fm-exists-search.sh - advisory "does this already exist?" search over a
# project's functions with typesafe.ai's System One model (Jev), opt-in.
#
# Usage (run inside the task worktree):
#   fm-exists-search.sh <project> "<yes/no question>" [<path>...]
#   fm-exists-search.sh <project> --change
#   fm-exists-search.sh --enabled <project>   (exit 0 when a run would ask Jev)
#
# Opt-in gate, both halves required, the same as bin/fm-house-rules-check.sh:
#   fm_jev_code_allowed finds <project> in jev-code-projects, and
#   TYPESAFE_API_KEY is available from the environment or $FM_HOME/.env.
#   bin/fm-jev-lib.sh owns the project list read, the key handling, the
#   request, the credential-line filter, and the answer validation, and is the
#   only Jev caller here. With either half absent this prints one "off" line on
#   stderr and exits 0 with no network call, and bin/fm-dod-lib.sh's
#   fm_brief_exists_search_step leaves the lines that offer it out of the brief.
#
# What it does when on: code decides every fact first. `git grep` finds each
#   line of the worktree's tracked text files that opens a function
#   (EXISTS_DEF), limited to <path>... when given; the paths
#   bin/fm-house-rules-check.sh never offers are dropped the same way. A
#   function's text runs from that line to the line before the next function in
#   the file, at most EXISTS_FN_LINES lines, each cut to EXISTS_LINE_CHARS
#   characters, so a long function keeps its start. Functions are then ordered
#   by how many of the probe's words their text holds, most first.
#   - With a question, the probe is the question. The first
#     EXISTS_MAX_FUNCTIONS functions in that order are asked, EXISTS_BATCH to a
#     request, each as its own yes/no Choice question through fm_jev_choices.
#   - With --change, each function whose opening line the worktree adds since
#     its merge base with the default branch (house_rules_base) is a probe, up
#     to EXISTS_CHANGE_MAX_NEW of them. Each is compared with the
#     EXISTS_CHANGE_CANDIDATES functions the change did not add that share
#     most words with it, asking of each whether it already does the new
#     one's job.
#   A function is a match only for a `yes` whose confidence and `yes`
#   probability both reach the shared FM_JEV_CONFIDENCE_FLOOR.
#
# Output: one line per match on stdout, most probable first:
#     <file>:<line>: yes <p>: <the function's opening line>
#   and under --change, grouped by new function in file order:
#     <new-file>:<line>: may repeat <file>:<line> (yes <p>): <that opening line>
#   plus one summary line on stderr.
#
# Authority: advice only. Every outcome exits 0 - no opt-in, no key, no base,
#   no function found, a timeout, a malformed answer, low confidence - so
#   nothing here can block, approve, merge, or discard anything; a failure
#   means no match, and the search by hand is still owed. Asking stops after
#   EXISTS_MAX_ERRORS failed requests or EXISTS_DEADLINE_SECS seconds, and the
#   summary says how many functions went unasked. Exit 2 only for a usage error.
set -u

# Sourced before anything can start a child: through it bin/fm-jev-lib.sh takes
# the key out of the exported environment. It also brings the skipped-path
# list and the default-branch base, so neither has a second copy here.
_fm_exists_dir=${BASH_SOURCE[0]%/*}
[ "$_fm_exists_dir" != "${BASH_SOURCE[0]}" ] || _fm_exists_dir=.
# shellcheck source=bin/fm-house-rules-check.sh
. "$_fm_exists_dir/fm-house-rules-check.sh"

EXISTS_FN_LINES=60
EXISTS_LINE_CHARS=200
EXISTS_BATCH=8
EXISTS_MAX_FUNCTIONS=200
EXISTS_CHANGE_MAX_NEW=25
EXISTS_CHANGE_CANDIDATES=16
EXISTS_MAX_ERRORS=3
EXISTS_DEADLINE_SECS=120
# ponytail: one regular expression instead of a parser per language. It names
# the function openers of shell, Python, Ruby, PHP, JavaScript, TypeScript, Go,
# Rust, Java, C#, and Kotlin, and misses any other shape; add an alternative
# here when a project's functions are not found.
EXISTS_DEF='^[[:space:]]*((export|default|public|private|protected|internal|static|final|abstract|override|async|pub(\([a-z]+\))?)[[:space:]]+)*(function[[:space:]*]+&?[A-Za-z_$]|(def|fn|func|fun)[[:space:]]+[A-Za-z_(])|^[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\)[[:space:]]*(\{|$)|^[[:space:]]*(export[[:space:]]+)?(const|let|var)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*=[[:space:]]*(async[[:space:]]*)?(\([^)]*\)|[A-Za-z_$][A-Za-z0-9_$]*)[[:space:]]*=>|^[[:space:]]+(public|private|protected|internal)[[:space:]][^=;]*\([^;]*$'
EXISTS_STOPWORDS=' does this that already with from have what which there their when where into then else the and for its one whether function '
# shellcheck disable=SC2016 # Backticks are literal Markdown for the model.
EXISTS_ASK='`functions.%s` is one function of this project: `file` is its path and `code` is its text, which may be cut short. `question` is a yes/no question about what a function does. Answer it for that one function only. Choose `no` whenever the function does not clearly do it or you are unsure.'
EXISTS_ASK_CRITERIA='{"yes":"The code of this one function itself clearly does what the question asks about.","no":"The function does something else, only calls, mentions, or tests the thing asked about, or it is unclear."}'
# shellcheck disable=SC2016 # Backticks are literal Markdown for the model.
EXISTS_CHANGE='`new` is a function that a change adds to this project, and `functions.%s` is a function the project already had. Each has `file`, its path, and `code`, its text, which may be cut short. Decide whether the new function repeats work the existing function already does.'
EXISTS_CHANGE_CRITERIA='{"yes":"The new function does essentially the same thing as the existing one: the same inputs lead to the same kind of result by the same kind of steps, even if names, wording, or small details differ.","no":"The two do clearly different things, or there is not enough in the code to tell."}'

exists_usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

# Write each function's text to <dir>/fn/<n>, "<n>\t<line>\t<file>\t<opening
# line>" to <dir>/index, and its lower-cased opening line and text to
# <dir>/corpus, for the tracked text files under <pathspec>...
exists_index() {  # <dir> [<pathspec>...]
  local dir=$1 file line last='' skip=0
  shift
  mkdir "$dir/fn"
  git grep -n -I -E -e "$EXISTS_DEF" -- "$@" 2>/dev/null \
    | while IFS=: read -r file line _; do
        case "$line" in ''|*[!0-9]*) continue ;; esac
        case "$file" in *$'\t'*) continue ;; esac
        if [ "$file" != "$last" ]; then
          last=$file skip=0
          house_rules_path_skipped "$file" && skip=1
        fi
        [ "$skip" -eq 1 ] || printf '%s\t%s\n' "$file" "$line"
      done \
    | awk -F '\t' -v dir="$dir/fn" -v corpus="$dir/corpus" -v max="$EXISTS_FN_LINES" -v chars="$EXISTS_LINE_CHARS" '
        { f[NR] = $1; l[NR] = $2 }
        END {
          for (i = 1; i <= NR; i++) {
            if (f[i] != cur) { if (cur != "") close(cur); cur = f[i]; ln = 0 }
            end = l[i] + max - 1
            if (i < NR && f[i + 1] == cur && l[i + 1] - 1 < end) end = l[i + 1] - 1
            out = dir "/" i; def = ""; text = ""
            while (ln < end && (getline s < cur) > 0) {
              ln++
              if (ln < l[i]) continue
              if (ln == l[i]) def = s
              s = substr(s, 1, chars)
              print s > out
              text = text " " s
            }
            close(out)
            if (def == "") continue
            gsub(/[\t\r]/, " ", def); sub(/^ +/, "", def); sub(/ +$/, "", def)
            def = substr(def, 1, 160)
            gsub(/[\t\r]/, " ", text)
            printf "%d\t%d\t%s\t%s\n", i, l[i], cur, def
            printf "%d\t%s\t%s\n", i, tolower(def), tolower(text) > corpus
          }
        }' > "$dir/index"
}

# Print the functions of <dir>/corpus, those in <skip> left out, ordered by the
# words of <probe-file> their text holds, most telling first: a word counts for
# more the fewer functions hold it, three times over in a function's opening
# line, and for less in a long function. A plural probe word loses its s.
# ponytail: word overlap, not meaning; it only decides who is asked first when
# the bounds cut the list. A function that does the job in other words sorts
# late and can go unasked in a large project - narrow with <path>...
exists_rank() {  # <dir> <probe-file> <skip>
  awk -F '\t' -v stop="$EXISTS_STOPWORDS" -v skip=" $3 " '
    FNR == NR {
      s = $0
      gsub(/[A-Z]/, " &", s)
      s = tolower(s)
      n = split(s, a, /[^a-z0-9]+/)
      for (i = 1; i <= n; i++) {
        w = a[i]
        if (length(w) >= 5) sub(/s$/, "", w)
        if (length(w) >= 3 && index(stop, " " w " ") == 0) words[w] = 1
      }
      next
    }
    index(skip, " " $1 " ") { next }
    {
      id[++m] = $1
      size[m] = length($3)
      for (w in words) if (index($3, w)) {
        df[w]++
        hit[m] = hit[m] " " w
        if (index($2, w)) hit[m] = hit[m] " " w " " w
      }
    }
    END {
      for (i = 1; i <= m; i++) {
        score = 0
        n = split(hit[i], a, " ")
        for (j = 1; j <= n; j++) score += log((m + 1) / df[a[j]])
        printf "%.4f\t%d\n", score / sqrt(1 + size[i] / 1000), id[i]
      }
    }' "$2" "$1/corpus" | sort -t "$(printf '\t')" -k1,1nr -k2,2n | cut -f2
}

# One request asking <template> of each function <n>...; prints "<yes-p>\t<n>"
# for every match. 1 when the request failed.
exists_ask() {  # <dir> <probe-json-file> <template> <criteria> <n>...
  local dir=$1 probe=$2 template=$3 criteria=$4 n map='' files=()
  shift 4
  for n in "$@"; do
    map+="$n"$'\t'"${EXISTS_FILES[$n]}"$'\n'
    files+=("$dir/fn/$n")
  done
  jq -Rn --arg map "$map" --slurpfile probe "$probe" '
    ($map | split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries) as $file
    | reduce inputs as $line ({}; .[input_filename | sub(".*/"; "")] += $line + "\n")
    | $probe[0] + {functions: with_entries(.value = {file: $file[.key], code: .value} | .key = "f" + .key)}' \
    "${files[@]}" > "$dir/state" 2>/dev/null || return 1
  jq -n --arg t "$template" --argjson c "$criteria" '
    [$ARGS.positional[] | ("f" + .) as $k | {key: $k, value: {instructions: ($t | sub("%s"; $k)), criteria: $c}}]
    | from_entries' --args "$@" > "$dir/questions" 2>/dev/null || return 1
  fm_jev_choices "$dir/questions" "$dir/state" "f$1" || return 1
  jq -r --argjson floor "$FM_JEV_CONFIDENCE_FLOOR" '
    .answers | to_entries[]
    | select(.value != null and .value.choice == "yes"
        and .value.confidence >= $floor and .value.probabilities.yes >= $floor)
    | "\(.value.probabilities.yes)\t\(.key[1:])"' <<<"$FM_JEV_ANSWERS" 2>/dev/null
  return 0
}

# Ask about the functions <n>... in requests of EXISTS_BATCH, within the
# bounds; prints exists_ask's matches and counts into asked/errors/unasked.
exists_ask_all() {  # <dir> <probe-json-file> <template> <criteria> <n>...
  local dir=$1 probe=$2 template=$3 criteria=$4 batch
  shift 4
  while [ $# -gt 0 ]; do
    batch=("${@:1:$EXISTS_BATCH}")
    shift "${#batch[@]}"
    if [ -z "$stop" ]; then
      if [ "$errors" -ge "$EXISTS_MAX_ERRORS" ]; then stop="$errors requests failed, last: $FM_JEV_ERROR"
      elif [ "$SECONDS" -ge "$EXISTS_DEADLINE_SECS" ]; then stop="the ${EXISTS_DEADLINE_SECS}s bound was reached"
      fi
    fi
    if [ -n "$stop" ]; then
      unasked=$((unasked + ${#batch[@]}))
    elif exists_ask "$dir" "$probe" "$template" "$criteria" "${batch[@]}" > "$dir/batch"; then
      asked=$((asked + ${#batch[@]}))
      cat "$dir/batch"
    else
      errors=$((errors + 1))
      unasked=$((unasked + ${#batch[@]}))
    fi
  done
}

exists_main() {
  local project='' question='' mode='' enabled=0 fm_root tmp n c line file def p
  local asked=0 errors=0 unasked=0 stop='' matches=0 total new=() ranked=() paths=()
  EXISTS_FILES=()
  local lines=() defs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --enabled) enabled=1; shift ;;
      --change) mode=change; shift ;;
      -h|--help) exists_usage; return 0 ;;
      -*) echo "error: unknown argument $1 (see --help)" >&2; return 2 ;;
      *)
        if [ -z "$project" ]; then project=$1
        elif [ -z "$mode" ]; then mode=ask question=$1
        elif [ "$mode" = ask ]; then paths+=("$1")
        else echo "error: --change takes no question or path (see --help)" >&2; return 2
        fi
        shift ;;
    esac
  done
  [ -n "$project" ] || { echo "error: a project name is required (see --help)" >&2; return 2; }
  fm_root=${FM_ROOT_OVERRIDE:-$(cd "$_fm_exists_dir/.." && pwd)}
  FM_HOME=${FM_HOME:-$fm_root}
  if [ "$enabled" -eq 0 ]; then
    [ -n "$mode" ] || { echo "error: a yes/no question or --change is required (see --help)" >&2; return 2; }
    if [ "$mode" = ask ] && [ -z "$(printf '%s' "$question" | tr -d '[:space:]')" ]; then
      echo "error: the question is empty (see --help)" >&2; return 2
    fi
  fi

  if ! fm_jev_key_load "$FM_HOME"; then
    [ "$enabled" -eq 1 ] || echo "exists-search: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env); search by hand" >&2
    return "$enabled"
  fi
  if ! fm_jev_code_allowed "$project"; then
    [ "$enabled" -eq 1 ] || echo "exists-search: off (project \"$project\" is not a line of ${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/jev-code-projects); search by hand" >&2
    return "$enabled"
  fi
  if ! command -v jq >/dev/null 2>&1; then
    [ "$enabled" -eq 1 ] || echo "exists-search: not run (jq not installed); search by hand" >&2
    return "$enabled"
  fi
  [ "$enabled" -eq 0 ] || return 0

  if [ "$mode" = change ]; then
    house_rules_base
    if [ -z "$HOUSE_RULES_MERGE_BASE" ]; then
      echo "exists-search: not run (no merge base with a default branch)" >&2
      return 0
    fi
  fi
  tmp=$(mktemp -d) || { echo "exists-search: not run (mktemp failed); search by hand" >&2; return 0; }
  EXISTS_TMP=$tmp
  exists_index "$tmp" ${paths[@]+"${paths[@]}"}
  while IFS=$'\t' read -r n line file def; do
    EXISTS_FILES[n]=$file lines[n]=$line defs[n]=$def
  done < "$tmp/index"
  total=${#lines[@]}
  SECONDS=0

  if [ "$mode" = ask ]; then
    printf '%s\n' "$question" > "$tmp/probe"
    jq -n --arg q "$question" '{question: $q}' > "$tmp/probe.json"
    while IFS= read -r n; do ranked+=("$n"); done < <(exists_rank "$tmp" "$tmp/probe" '')
    exists_ask_all "$tmp" "$tmp/probe.json" "$EXISTS_ASK" "$EXISTS_ASK_CRITERIA" \
      ${ranked[@]+"${ranked[@]:0:$EXISTS_MAX_FUNCTIONS}"} > "$tmp/hits"
    while IFS=$'\t' read -r p n; do
      matches=$((matches + 1))
      printf '%s:%s: yes %s: %s\n' "${EXISTS_FILES[$n]}" "${lines[$n]}" "$p" "${defs[$n]}"
    done < <(sort -t "$(printf '\t')" -k1,1nr -k2,2n "$tmp/hits")
    if [ -z "$stop" ]; then
      if [ "$errors" -gt 0 ]; then stop="$errors request(s) failed, last: $FM_JEV_ERROR"
      else stop="the $EXISTS_MAX_FUNCTIONS-function bound was reached"
      fi
    fi
    [ "$asked" -lt "$total" ] || stop=''
    echo "exists-search: $matches advisory match(es) from $asked of $total function(s) asked${stop:+; $((total - asked)) not asked because $stop}; a match is a place to read, and no match is not proof" >&2
  else
    # Every line the worktree adds since the base, as "<file>\t<line>".
    git -c core.quotePath=false diff --no-color --no-ext-diff --diff-filter=AMR -U0 --src-prefix=a/ --dst-prefix=b/ \
      "$HOUSE_RULES_MERGE_BASE" -- 2>/dev/null | awk '
        /^\+\+\+ / { file = ($0 == "+++ /dev/null" || $0 ~ /^\+\+\+ "/) ? "" : substr($0, 7); next }
        /^@@ / && file != "" {
          at = $0; sub(/^@@ -[0-9,]+ \+/, "", at); sub(/ .*$/, "", at)
          count = (at ~ /,/) ? substr(at, index(at, ",") + 1) + 0 : 1
          for (i = 0; i < count; i++) printf "%s\t%d\n", file, at + i
        }' > "$tmp/added"
    while IFS= read -r n; do new+=("$n"); done < <(awk -F '\t' '
      FNR == NR { added[$1 "\t" $2] = 1; next }
      ($3 "\t" $2) in added { print $1 }' "$tmp/added" "$tmp/index")
    for n in ${new[@]+"${new[@]:0:$EXISTS_CHANGE_MAX_NEW}"}; do
      jq -n --arg file "${EXISTS_FILES[$n]}" --rawfile code "$tmp/fn/$n" '{new: {file: $file, code: $code}}' > "$tmp/probe.json"
      ranked=()
      while IFS= read -r p; do ranked+=("$p"); done < <(exists_rank "$tmp" "$tmp/fn/$n" "${new[*]}" | head -n "$EXISTS_CHANGE_CANDIDATES")
      [ "${#ranked[@]}" -gt 0 ] || continue
      exists_ask_all "$tmp" "$tmp/probe.json" "$EXISTS_CHANGE" "$EXISTS_CHANGE_CRITERIA" "${ranked[@]}" > "$tmp/hits"
      while IFS=$'\t' read -r p c; do
        matches=$((matches + 1))
        printf '%s:%s: may repeat %s:%s (yes %s): %s\n' "${EXISTS_FILES[$n]}" "${lines[$n]}" \
          "${EXISTS_FILES[$c]}" "${lines[$c]}" "$p" "${defs[$c]}"
      done < <(sort -t "$(printf '\t')" -k1,1nr -k2,2n "$tmp/hits")
    done
    n=$(( ${#new[@]} > EXISTS_CHANGE_MAX_NEW ? ${#new[@]} - EXISTS_CHANGE_MAX_NEW : 0 ))
    echo "exists-search: $matches advisory match(es) for ${#new[@]} function(s) added since $HOUSE_RULES_BASE, from $asked comparison(s)${stop:+; stopped because $stop, $unasked comparison(s) not made}$( [ "$n" -eq 0 ] || printf '%s' "; $n added function(s) over the $EXISTS_CHANGE_MAX_NEW bound not compared"); a match is a place to read, and no match is not proof" >&2
  fi
  rm -rf "$tmp"
  return 0
}

EXISTS_TMP=
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  trap '[ -z "$EXISTS_TMP" ] || rm -rf "$EXISTS_TMP"' EXIT
  exists_main "$@"
  exit
fi
