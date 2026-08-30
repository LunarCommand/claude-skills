#!/usr/bin/env bash
# mutation_test_changed_lines.sh — turn a unified diff into the lines worth
# mutating.
#
#   gh pr diff 277 | mutation_test_changed_lines.sh --suffix .py
#   git diff main...HEAD | mutation_test_changed_lines.sh > /tmp/changed.tsv
#
# Emits one "<path><TAB><line>" per line ADDED or MODIFIED in the new file,
# sorted and deduplicated. Deleted lines are not reported: there is nothing left
# to mutate. Paths are as the diff spells them, with the leading `b/` removed.
#
# It reads a diff on stdin and writes a list on stdout. It opens no file for
# writing, executes nothing, and needs no knowledge of the language — it only
# ever parses diff syntax. That is why, unlike the other two scripts here, it
# can carry a permission rule: there is no payload for one to approve, and no
# path for one to truncate.
#
# It had an --out option once. A permission rule pre-approving this script then
# pre-approved truncating any path the caller named, with no prompt — so the
# claim above was false while it was written down in three places. Redirect
# stdout instead: that is the caller's write, and their prompt.
#
# The output is a candidate list, not a work order. Choosing WHICH of these
# lines to mutate, and to what, is a judgement about the code that belongs to
# whoever reads it — see SKILL.md. Ten chosen mutants beat a hundred generated
# ones, and a generated edit that breaks the syntax goes red for the wrong
# reason.
#
# Refusals print `mutation_test_changed_lines: refused: <slug>` before exiting:
#   40 usage   41 missing dependency   42 cannot read the diff
set -uo pipefail

DIFF_FILE=''
SUFFIXES=''

usage() {
  cat <<'USAGE'
Usage:
  mutation_test_changed_lines.sh [--file <diff>] [--suffix <sfx>]...

Reads a unified diff on stdin, or from --file, and writes "<path>\t<line>" for
every added or modified line to stdout. A count summary goes to stderr.

  --file   <path>   read the diff from a file instead of stdin
  --suffix <sfx>    keep only paths ending in this (repeatable, e.g. --suffix .py)

To save the list, redirect stdout. This script never opens a file for writing.
USAGE
}

say()    { printf '%s\n' "$*" >&2; }
refuse() { local slug=$1 code=$2; shift 2; say "mutation_test_changed_lines: refused: $slug"; say "Error: $*"; exit "$code"; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || \
      refuse missing-dependency 41 "missing required command: $c (install it; do not work around this)"
  done
}

while [ $# -gt 0 ]; do
  case $1 in
    --file)   [ $# -ge 2 ] || refuse file-needs-value 40 "--file needs a value";     DIFF_FILE=$2; shift 2 ;;
    --suffix) [ $# -ge 2 ] || refuse suffix-needs-value 40 "--suffix needs a value"; SUFFIXES="$SUFFIXES$2
"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; refuse unknown-argument 40 "unknown argument: $1" ;;
  esac
done

require_cmd awk sort

if [ -n "$DIFF_FILE" ]; then
  [ -f "$DIFF_FILE" ] || refuse no-such-diff 42 "no such file: $DIFF_FILE"
  [ -r "$DIFF_FILE" ] || refuse unreadable-diff 42 "cannot read: $DIFF_FILE"
  exec < "$DIFF_FILE"
fi

# Diff syntax only. `+++ /dev/null` marks a deleted file, whose lines cannot be
# mutated; the hunk header gives the first line number in the NEW file, and a
# context line advances it while a `+` line both records and advances it.
#
# The diff is UNTRUSTED INPUT: it is written by the author of the PR under
# review, who controls the text of every line they add. An added line reading
# `++ foo` renders as `+++ foo` in a unified diff, so matching `^\+\+\+ `
# anywhere let that author reassign their own subsequent lines to a path of
# their choosing -- reproduced: a hunk on src/auth.py whose middle line was
# `+++ b/README.md` reported the line after it under README.md, so the line went
# unmutated and unreported while the summary still read as a complete inventory.
# Two pieces of state close it: a `+++ ` line is a header only DIRECTLY after a
# `--- ` or `diff --git` line, and the hunk header's declared new-file length is
# a budget, so content past it is attributed nowhere.
pairs=$(awk '
  /^diff --git / { hdr = 1; path = ""; left = 0; next }
  /^--- / { hdr = 1; next }
  /^\+\+\+ / {
    if (!hdr) { if (left > 0) { print path "\t" lineno; lineno++; left-- } next }
    hdr = 0
    path = substr($0, 5)
    sub(/[ \t]+$/, "", path)
    if (path == "/dev/null") { path = "" } else { sub(/^b\//, "", path) }
    left = 0
    next
  }
  /^@@/ {
    hdr = 0
    if (match($0, /\+[0-9]+/)) { lineno = substr($0, RSTART + 1, RLENGTH - 1) + 0 }
    # `+c` alone means a one-line hunk; `+c,d` gives the length explicitly.
    if (match($0, /\+[0-9]+,[0-9]+/)) {
      left = substr($0, RSTART + 1, RLENGTH - 1)
      sub(/^[0-9]+,/, "", left)
      left = left + 0
    } else { left = 1 }
    next
  }
  { hdr = 0 }
  path == "" { next }
  left <= 0 { next }
  /^\+/ { print path "\t" lineno; lineno++; left--; next }
  /^ /  { lineno++; left--; next }
')

# Suffix filter, done here rather than in awk so the suffixes stay literal —
# a suffix like ".py" is not a pattern, and treating it as one matched "apy".
if [ -n "$SUFFIXES" ]; then
  pairs=$(printf '%s\n' "$pairs" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    p=${line%	*}
    printf '%s\n' "$SUFFIXES" | while IFS= read -r sfx; do
      [ -n "$sfx" ] || continue
      # Leading '(': bash 3.2 scans $( ) for the matching paren, so an
      # unbalanced case pattern ends the substitution early.
      case $p in (*"$sfx") printf '%s\n' "$line"; break ;; esac
    done
  done)
fi

result=$(printf '%s\n' "$pairs" | sort -u -t'	' -k1,1 -k2,2n | sed '/^$/d')

files=$(printf '%s\n' "$result" | sed '/^$/d' | cut -f1 | sort -u | grep -c . || true)
lines=$(printf '%s\n' "$result" | grep -c . || true)
say "$files file(s), $lines changed line(s)"
printf '%s\n' "$result" | sed '/^$/d'
