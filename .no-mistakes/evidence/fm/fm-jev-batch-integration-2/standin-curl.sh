#!/usr/bin/env bash
# Stand-in for the TypeSafe endpoint: records what the product sends, answers from $STANDIN_JQ.
set -u
log=${STANDIN_LOG:?}
n=$(( $(cat "$log/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$log/calls"
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then echo key-in-child-env >> "$log/env"; else echo clean >> "$log/env"; fi
out=''
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) printf '%s\n' "$1" >> "$log/argv"; shift ;; esac; done
cat > "$log/body.$n"
cat /dev/fd/3 > "$log/header" 2>/dev/null
[ "${STANDIN_FAIL:-0}" = 0 ] || exit 28
jq -f "${STANDIN_JQ:?}" "$log/body.$n" > "$out"
printf 200
