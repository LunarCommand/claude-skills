#!/usr/bin/env bash
# mutation_test_run_mutants.sh — apply mutations one at a time, run the tests,
# and report which ones nothing caught.
#
#   mutation_test_run_mutants.sh --spec mutants.txt --test 'uv run pytest'
#
# It does NOT invent mutations. Choosing a semantically meaningful edit needs
# reading the code, and a generated edit that breaks the syntax goes red for the
# wrong reason — the confound that defeated three generations of this skill's
# wiring gates. You choose; this runs them.
#
# INTENDED USE: as the command handed to `mutation_test_worktree.sh run`, so it
# operates on a throwaway checkout whose baseline is already known green:
#
#   mutation_test_worktree.sh run --test 'make test' -- \
#       mutation_test_run_mutants.sh --spec mutants.txt --test 'make test'
#
# It also runs standalone, in which case it is mutating YOUR files. It restores
# each one and verifies byte-for-byte, but the worktree is what makes a failed
# restore harmless rather than merely unlikely.
#
# SPEC FORMAT. Blank-line-separated records of `key: value`. The value is
# everything after the first ": ", verbatim, so leading spaces in `find` or
# `replace` are significant. find/replace are LITERAL — no regex — and apply to
# the single line given, so a common token like ">=" needs no uniqueness games.
#
#   file: src/pkg/limits.py
#   line: 42
#   find: >=
#   replace: >
#   desc: trip boundary >= -> >
#
#   file: src/pkg/limits.py
#   line: 51
#   find: return True
#   replace: return False
#
# `desc` is optional. Everything else is required.
#
# WHAT A RESULT MEANS. A mutant the suite catches is KILLED — that line is
# covered. A mutant nothing catches SURVIVED, which is a coverage gap, not a
# bug: the code is usually correct as written, and the finding is that a future
# edit could change behaviour with the suite still green.
#
# THE ONE RESULT THAT IS NOT A FINDING: if EVERY mutant survives, suspect the
# environment before believing the coverage. That is what a test suite resolving
# to a different copy of the source looks like, and it is indistinguishable from
# real absence of coverage except by its implausibility. This refuses rather
# than reporting it, because reporting it is the false clean run this skill
# exists to prevent.
#
# Serial by design: two mutants in one working tree cannot be told apart.
#
# Refusals print `mutation_test_run_mutants: refused: <slug>` before exiting:
#   50 usage   51 missing dependency   52 spec or apply problem
#   53 baseline red                    54 every mutant survived
#   55 a test run never reached a verdict
set -uo pipefail

SPEC=''
TEST_CMD=''
ROOT='.'
DRY=no
SAVED=''
CUR_FILE=''

usage() {
  cat <<'USAGE'
Usage:
  mutation_test_run_mutants.sh --spec <file> --test <cmd> [--root <dir>] [--dry-run]

  --spec <file>  blank-line-separated records: file/line/find/replace[/desc]
  --test <cmd>   the command that judges a mutant; must exit 0 on clean source
  --root <dir>   directory the spec's paths are relative to (default: .)
  --dry-run      resolve and check every mutant, run nothing

Exit codes 50-55 are this script's own.
USAGE
}

say()    { printf '%s\n' "$*" >&2; }
refuse() { local slug=$1 code=$2; shift 2; say "mutation_test_run_mutants: refused: $slug"; say "Error: $*"; exit "$code"; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || \
      refuse missing-dependency 51 "missing required command: $c (install it; do not work around this)"
  done
}

# Restore whatever is currently mutated. Called from the traps as well as the
# normal path, because an interrupt between apply and restore is the one moment
# a file is left altered.
restore_current() {
  [ -n "$SAVED" ] || return 0
  [ -f "$SAVED" ] || return 0
  if [ -n "$CUR_FILE" ] && [ -f "$CUR_FILE" ]; then
    cat "$SAVED" > "$CUR_FILE" 2>/dev/null || true
  fi
  rm -f "$SAVED"
  SAVED=''
  CUR_FILE=''
}
on_signal() { restore_current; trap - EXIT; say ""; say "interrupted — restored the file in progress"; exit 130; }
trap on_signal INT TERM HUP QUIT
trap restore_current EXIT

while [ $# -gt 0 ]; do
  case $1 in
    --spec)    [ $# -ge 2 ] || refuse spec-needs-value 50 "--spec needs a value"; SPEC=$2;     shift 2 ;;
    --test)    [ $# -ge 2 ] || refuse test-needs-value 50 "--test needs a value"; TEST_CMD=$2; shift 2 ;;
    --root)    [ $# -ge 2 ] || refuse root-needs-value 50 "--root needs a value"; ROOT=$2;     shift 2 ;;
    --dry-run) DRY=yes; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; refuse unknown-argument 50 "unknown argument: $1" ;;
  esac
done

[ -n "$SPEC" ]     || { usage; refuse no-spec 50 "--spec is required"; }
[ -n "$TEST_CMD" ] || { usage; refuse no-test 50 "--test is required"; }
[ -f "$SPEC" ]     || refuse no-such-spec 52 "no such spec file: $SPEC"
[ -d "$ROOT" ]     || refuse no-such-root 52 "no such directory: $ROOT"
require_cmd awk cmp mktemp

ROOT=$( cd "$ROOT" && pwd -P ) || refuse unresolvable-root 52 "cannot resolve --root"

# --- read the spec -----------------------------------------------------------
# Parallel arrays rather than one structure: bash 3.2 has no associative arrays,
# and macOS ships bash 3.2.
M_FILE=''; M_LINE=''; M_FIND=''; M_REPL=''; M_DESC=''; M_COUNT=0
flush_record() {
  [ -n "$r_file$r_line$r_find$r_repl" ] || return 0
  [ -n "$r_file" ] || refuse spec-no-file 52 "record $((M_COUNT + 1)) has no 'file:'"
  [ -n "$r_line" ] || refuse spec-no-line 52 "record $((M_COUNT + 1)) ($r_file) has no 'line:'"
  [ -n "$r_find" ] || refuse spec-no-find 52 "record $((M_COUNT + 1)) ($r_file) has no 'find:'"
  case $r_line in *[!0-9]*|'') refuse spec-bad-line 52 "record $((M_COUNT + 1)) ($r_file): 'line: $r_line' is not a number" ;; esac
  M_FILE="$M_FILE$r_file
"; M_LINE="$M_LINE$r_line
"; M_FIND="$M_FIND$r_find
"; M_REPL="$M_REPL$r_repl
"; M_DESC="$M_DESC${r_desc:-$r_find -> $r_repl}
"
  M_COUNT=$((M_COUNT + 1))
  r_file=''; r_line=''; r_find=''; r_repl=''; r_desc=''
}
r_file=''; r_line=''; r_find=''; r_repl=''; r_desc=''
while IFS= read -r sl || [ -n "$sl" ]; do
  case $sl in
    '') flush_record; continue ;;
    '#'*) continue ;;
    'file: '*)    r_file=${sl#file: } ;;
    'line: '*)    r_line=${sl#line: } ;;
    'find: '*)    r_find=${sl#find: } ;;
    'replace: '*) r_repl=${sl#replace: } ;;
    'desc: '*)    r_desc=${sl#desc: } ;;
    *) refuse spec-unparsed 52 "cannot parse spec line: $sl" ;;
  esac
done < "$SPEC"
flush_record

[ "$M_COUNT" -gt 0 ] || refuse spec-empty 52 "$SPEC contains no mutants"

nth() { printf '%s\n' "$1" | sed -n "$2p"; }

# --- resolve every mutant before running any of them -------------------------
# A typo in the spec should surface in a second, not after ten test runs.
i=1
while [ "$i" -le "$M_COUNT" ]; do
  f=$(nth "$M_FILE" "$i"); ln=$(nth "$M_LINE" "$i"); fd=$(nth "$M_FIND" "$i")
  case $f in
    /*)               refuse spec-absolute-path 52 "mutant $i: file must be relative to --root: $f" ;;
    ..|../*|*/../*|*/..) refuse spec-dotdot-path 52 "mutant $i: file may not contain '..': $f" ;;
  esac
  [ -f "$ROOT/$f" ] || refuse no-such-target 52 "mutant $i: no such file under $ROOT: $f"
  total_lines=$(awk 'END{print NR}' "$ROOT/$f")
  [ "$ln" -le "$total_lines" ] || refuse line-out-of-range 52 "mutant $i: $f has $total_lines lines, spec says line $ln"
  MT_FIND="$fd" awk -v ln="$ln" 'NR==ln && index($0, ENVIRON["MT_FIND"]) > 0 { found=1 } END{ exit(found?0:1) }' "$ROOT/$f" \
    || refuse find-not-on-line 52 "mutant $i: line $ln of $f does not contain: $fd"
  i=$((i + 1))
done

if [ "$DRY" = yes ]; then
  say "$M_COUNT mutant(s) resolve cleanly against $ROOT; nothing was run"
  i=1
  while [ "$i" -le "$M_COUNT" ]; do
    printf '%s:%s\t%s\n' "$(nth "$M_FILE" "$i")" "$(nth "$M_LINE" "$i")" "$(nth "$M_DESC" "$i")"
    i=$((i + 1))
  done
  exit 0
fi

# --- baseline ----------------------------------------------------------------
# The SAME command that will judge the mutants. The withheld predecessor
# evaluated a different one, so a red baseline read as every mutant being
# killed.
run_test() { ( cd "$ROOT" && bash -c "$TEST_CMD" ) </dev/null >/dev/null 2>&1; }
check_ran() { # rc, what
  case $1 in
    126|127) refuse test-not-runnable 55 "$2 exited $1: not executable or not found" ;;
  esac
  [ "$1" -gt 128 ] && refuse test-killed 55 "$2 was killed by a signal (exit $1)"
  return 0
}
say "baseline: $TEST_CMD"
rc=0; run_test || rc=$?
check_ran "$rc" "the --test command"
[ "$rc" -ne 0 ] && refuse baseline-red 53 "the baseline is RED (exit $rc). A red baseline cannot judge a mutant."

# --- run them ----------------------------------------------------------------
killed=0; survived=0
RESULTS=''
i=1
while [ "$i" -le "$M_COUNT" ]; do
  f=$(nth "$M_FILE" "$i"); ln=$(nth "$M_LINE" "$i")
  fd=$(nth "$M_FIND" "$i"); rp=$(nth "$M_REPL" "$i"); ds=$(nth "$M_DESC" "$i")
  target="$ROOT/$f"

  SAVED=$(mktemp "${TMPDIR:-/tmp}/mutation-test-orig.XXXXXX") || refuse tmpfile 52 "cannot create a temporary file"
  CUR_FILE="$target"
  cat "$target" > "$SAVED" || refuse unreadable-target 52 "cannot read $f"

  # Literal replace of the FIRST occurrence, on that line only. find/replace
  # travel through the environment, not `awk -v`, which would process backslash
  # escapes in the value and silently alter it.
  MT_FIND="$fd" MT_REPL="$rp" awk -v ln="$ln" '
    NR == ln {
      f = ENVIRON["MT_FIND"]; r = ENVIRON["MT_REPL"]
      i = index($0, f)
      if (i > 0) { $0 = substr($0, 1, i - 1) r substr($0, i + length(f)) }
    }
    { print }
  ' "$SAVED" > "$target" || refuse apply-failed 52 "mutant $i: could not write $f"

  rc=0; run_test || rc=$?

  cat "$SAVED" > "$target" || refuse restore-failed 52 "mutant $i: COULD NOT RESTORE $f — its original is at $SAVED"
  cmp -s "$SAVED" "$target" || refuse restore-mismatch 52 "mutant $i: $f did not restore byte-for-byte — original at $SAVED"
  rm -f "$SAVED"; SAVED=''; CUR_FILE=''

  check_ran "$rc" "the --test command (mutant $i)"
  if [ "$rc" -eq 0 ]; then
    survived=$((survived + 1)); verdict=SURVIVED
  else
    killed=$((killed + 1)); verdict=killed
  fi
  RESULTS="$RESULTS$verdict	$f:$ln	$ds
"
  printf '%-9s %s:%s\t%s\n' "$verdict" "$f" "$ln" "$ds"
  i=$((i + 1))
done

say ""
say "$M_COUNT mutant(s): $killed killed, $survived survived"

# --- the one result that is not a finding ------------------------------------
if [ "$survived" -eq "$M_COUNT" ] && [ "$M_COUNT" -ge 2 ]; then
  refuse all-survived 54 "every one of the $M_COUNT mutants survived.

       Read that as the environment before believing it is coverage. A test
       suite resolving to a DIFFERENT copy of the source produces exactly this
       — an editable install records an absolute path, so the tests import the
       tree you did not mutate — and it is indistinguishable from genuine
       absence of coverage except by how unlikely it is.

       Check that --test actually exercises these files, and that it runs
       against THIS directory rather than an installed copy. If the coverage
       really is absent, mutate one line you are certain is covered: that
       mutant should be killed, and if it is not, the environment is the cause."
fi

if [ "$survived" -gt 0 ]; then
  say ""
  say "Survivors are coverage gaps, not bugs: the code is usually correct as"
  say "written, and the finding is that a future edit could change behaviour"
  say "with the suite still green. Report them; do not write the tests unasked."
fi
exit 0
