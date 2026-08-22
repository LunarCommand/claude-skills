#!/usr/bin/env bash
# Extract changed line numbers from a unified diff.
#
# Reads a diff on stdin (or --file) and emits JSON mapping each path to the
# lines ADDED or MODIFIED in the new file. Deleted lines are not reported --
# there is nothing left to mutate.
#
#   gh pr diff 55 | mutation_test_changed_lines.sh --suffix .py
#   git diff HEAD | mutation_test_changed_lines.sh --out changed.json
#
# Language-agnostic: this only ever parses diff syntax.

set -euo pipefail

DIFF_FILE=""
OUT=""
SUFFIXES=()

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)   DIFF_FILE="$2"; shift 2 ;;
    --out)    OUT="$2"; shift 2 ;;
    --suffix) SUFFIXES+=("$2"); shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 2; }

if [[ -n "$DIFF_FILE" ]]; then
  exec < "$DIFF_FILE"
fi

# Emit "path<TAB>lineno" for every added/modified line.
pairs=$(awk '
  /^\+\+\+ / {
    path = substr($0, 5)
    sub(/[ \t]+$/, "", path)
    if (path == "/dev/null") { path = "" } else { sub(/^b\//, "", path) }
    next
  }
  /^@@/ {
    # @@ -old,cnt +new,cnt @@
    if (match($0, /\+[0-9]+/)) {
      lineno = substr($0, RSTART + 1, RLENGTH - 1) + 0
    }
    next
  }
  path == "" { next }
  /^\+/ { print path "\t" lineno; lineno++; next }
  /^ /  { lineno++; next }
')

sfx_json='[]'
if [[ ${#SUFFIXES[@]} -gt 0 ]]; then
  sfx_json=$(printf '%s\n' "${SUFFIXES[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')
fi

# endswith, not a regex -- a suffix like ".py" is not a pattern and escaping it
# into one produced an invalid jq string ("\.py") that failed to compile.
json=$(printf '%s\n' "$pairs" \
  | jq -R -s --argjson sfx "$sfx_json" '
      split("\n") | map(select(length > 0) | split("\t"))
      | reduce .[] as $p ({}; .[$p[0]] += [$p[1] | tonumber])
      | with_entries(.value |= (unique | sort))
      | if ($sfx | length) == 0 then .
        else with_entries(select(.key as $k | $sfx | any(. as $s | $k | endswith($s))))
        end
    ')

if [[ -n "$OUT" ]]; then
  printf '%s\n' "$json" > "$OUT"
  files=$(printf '%s' "$json" | jq 'length')
  total=$(printf '%s' "$json" | jq '[.[] | length] | add // 0')
  echo "$files file(s), $total changed line(s) -> $OUT"
else
  printf '%s\n' "$json"
fi
