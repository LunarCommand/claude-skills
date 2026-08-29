#!/usr/bin/env bash
# mutation_test_run_mutants.sh — apply mutations one at a time, run the tests,
# and report which ones nothing caught.
#
#   mutation_test_worktree.sh run --test 'make test' -- \
#       mutation_test_run_mutants.sh --spec /tmp/mutants.tsv --test 'make test'
#
# IT ONLY RUNS INSIDE A THROWAWAY WORKTREE, and refuses otherwise. That is not
# a convention, it is the safety property: an earlier version also worked
# directly on your real files, which meant its restore path had to be perfect,
# and it was not — a failed restore deleted the backup it had just named, and a
# not-yet-written backup could be copied over an untouched file. Both are gone,
# because restoring is now `git checkout -- <file>` in a checkout that is about
# to be deleted anyway. There is no backup to lose.
#
# It does NOT invent mutations. Choosing a semantically meaningful edit needs
# reading the code, and a generated edit that breaks the syntax goes red for a
# reason that says nothing about coverage. You choose; this runs them.
#
# SPEC FORMAT. One mutant per line, TAB-separated, in a file OUTSIDE the
# repository (the worktree will not contain an untracked file):
#
#   file<TAB>line<TAB>find<TAB>replace[<TAB>desc[<TAB>control]]
#   src/pkg/limits.py	42	>=	>	trip the boundary
#   src/pkg/limits.py	51	return True	return False
#   src/pkg/parse.py	12	==	!=	a line you KNOW is covered	control
#
# Blank lines and lines starting with # are skipped. find and replace are
# LITERAL and apply to the single line given, first occurrence only. Because
# the fields are tab-separated, find and replace cannot contain a tab; nothing
# else is off limits, including spaces, colons and quotes.
#
# An earlier version used blank-line-separated `key: value` records. A spec
# missing one blank line silently collapsed two mutants into one, and that
# dropped the run below the all-survived floor, turning a mis-wired environment
# into a confident "coverage gap" report. One line per mutant cannot do that:
# the wrong number of fields is refused.
#
# WHAT A RESULT MEANS. A mutant the suite catches is KILLED — that line is
# covered. A mutant nothing catches SURVIVED, which is a coverage gap rather
# than a bug: the code is usually correct as written, and the finding is that a
# future edit could change behaviour with the suite still green.
#
# MARK ONE MUTANT `control` AND THE GUESSWORK GOES AWAY. A control is a mutant
# on a line you are confident IS covered. If it dies, the tests demonstrably see
# your edits, so every survivor beside it is a real coverage gap. If it survives
# too, the environment is the cause and the run refuses.
#
# Without a control this falls back to a heuristic: every mutant surviving,
# across two or more distinct lines, is refused as probable mis-wiring. That
# heuristic is wrong exactly where this tool is most often pointed. Running it
# against a freshly written module — where coverage is genuinely thinnest — was
# measured refusing four mutants whose lines a coverage report independently
# called untested. The environment was fine; the refusal was a false alarm.
# A control turns "suspect the environment" from a guess into a test.
#
# Serial by design: two mutants in one working tree cannot be told apart.
#
# Refusals print `mutation_test_run_mutants: refused: <slug>` before exiting:
#   50 usage   51 missing dependency   52 spec or apply problem
#   53 baseline red   54 every mutant survived, or a control did
#   55 the test never ran
set -uo pipefail

SPEC=''
TEST_CMD=''
DRY=no
TEST_PID=''
MUTATED=''
OUT=''

usage() {
  cat <<'USAGE'
Usage:
  mutation_test_run_mutants.sh --spec <file> --test <cmd> [--dry-run]

Runs ONLY inside a throwaway git worktree; use mutation_test_worktree.sh to
make one. Keep the spec OUTSIDE the repository and pass an absolute path — an
untracked file in the repo will not exist inside the worktree.

  --spec <file>  one mutant per line:
                   file<TAB>line<TAB>find<TAB>replace[<TAB>desc[<TAB>control]]
                 Mark one mutant `control` on a line you know is covered: if it
                 dies the wiring is proven and every other survivor is a real
                 gap. Without one, all-mutants-surviving is refused as probable
                 mis-wiring, which is wrong on genuinely untested code.
  --test <cmd>   the command that judges a mutant; must exit 0 on clean source
  --dry-run      resolve and check every mutant, run no mutants. Composed with
                 mutation_test_worktree.sh you still pay that script's baseline
                 run, so this costs one full suite, not nothing.

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

# git owns the restore. In a worktree that is about to be deleted this cannot
# lose anything: the content is in the object database, not in a temp file we
# might drop.
restore_mutated() {
  [ -n "$MUTATED" ] || return 0
  git checkout -- "$MUTATED" 2>/dev/null || say "WARNING: could not restore $MUTATED with git checkout"
  MUTATED=''
}
cleanup() { [ -n "$TEST_PID" ] && kill "$TEST_PID" 2>/dev/null; restore_mutated; [ -n "$OUT" ] && rm -f "$OUT"; return 0; }
on_signal() { cleanup; trap - EXIT; say ""; say "interrupted — the mutated file was restored with git checkout"; exit 130; }
trap on_signal INT TERM HUP QUIT
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case $1 in
    --spec)    [ $# -ge 2 ] || refuse spec-needs-value 50 "--spec needs a value"; SPEC=$2;     shift 2 ;;
    --test)    [ $# -ge 2 ] || refuse test-needs-value 50 "--test needs a value"; TEST_CMD=$2; shift 2 ;;
    --dry-run) DRY=yes; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; refuse unknown-argument 50 "unknown argument: $1" ;;
  esac
done

[ -n "$SPEC" ]     || { usage; refuse no-spec 50 "--spec is required"; }
[ -n "$TEST_CMD" ] || { usage; refuse no-test 50 "--test is required"; }
[ -f "$SPEC" ]     || refuse no-such-spec 52 "no such spec file: $SPEC"
require_cmd git awk

# The safety property, enforced rather than documented. A linked worktree's git
# dir lives under .../worktrees/; a main working tree's does not.
gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) \
  || refuse not-a-worktree 52 "this is not a git working tree.
       Run it as the command of 'mutation_test_worktree.sh run', which makes a
       throwaway checkout. It refuses to mutate anything else."
case $gitdir in
  */worktrees/*) : ;;
  *) refuse main-worktree 52 "this is a MAIN working tree, not a throwaway worktree.
       Mutating here would edit your real files, and this script restores with
       'git checkout' on the assumption that the checkout is disposable. Run it
       as the command of 'mutation_test_worktree.sh run'." ;;
esac
ROOT=$(git rev-parse --show-toplevel) || refuse no-toplevel 52 "cannot find the worktree root"

# --- read the spec -----------------------------------------------------------
# One line per mutant, so a malformed record cannot silently merge with its
# neighbour. bash 3.2 has no arrays worth using here, so the fields are kept as
# newline-joined strings and read back by line number.
M_FILE=''; M_LINE=''; M_FIND=''; M_REPL=''; M_DESC=''; M_CTRL=''; M_COUNT=0
lineno=0
while IFS= read -r sl || [ -n "$sl" ]; do
  lineno=$((lineno + 1))
  case $sl in ''|'#'*) continue ;; esac
  # Count the separators rather than comparing a remainder to the field before
  # it: an earlier version did the latter and refused a legitimate mutant whose
  # find and replace happened to be the same string.
  ntab=$(printf '%s' "$sl" | awk -F'\t' '{print NF-1}')
  case $ntab in
    (3|4|5) : ;;
    (*) refuse spec-fields 52 "spec line $lineno: expected 4 to 6 tab-separated fields
       (file, line, find, replace, then optionally desc and the word 'control'),
       found $((ntab + 1)). A tab inside find or replace is not representable." ;;
  esac
  # Split positionally, NOT with `IFS=$'\t' read`. Tab is whitespace to the
  # shell, so read strips leading tabs and collapses consecutive ones — an
  # empty field silently vanished and every later field shifted left. The tab
  # count above makes the positional split unambiguous, and it keeps empty
  # fields, which matters: an empty replace deletes the token and is a
  # legitimate mutation.
  tab=$(printf '\t')
  f=${sl%%"$tab"*};  r1=${sl#*"$tab"}
  l=${r1%%"$tab"*};  r2=${r1#*"$tab"}
  fd=${r2%%"$tab"*}; r3=${r2#*"$tab"}
  ct=''
  if [ "$ntab" -eq 3 ]; then
    rp=$r3; ds=''
  else
    rp=${r3%%"$tab"*}; r4=${r3#*"$tab"}
    if [ "$ntab" -eq 4 ]; then ds=$r4; else ds=${r4%%"$tab"*}; ct=${r4#*"$tab"}; fi
  fi
  # A sixth field must be exactly `control`. Anything else is refused rather
  # than ignored: a typo that silently stopped being a control would remove the
  # evidence the run depends on.
  case $ct in
    (''|control) : ;;
    (*) refuse spec-bad-control 52 "spec line $lineno: the sixth field must be the word 'control', not '$ct'" ;;
  esac
  case $l in *[!0-9]*|'') refuse spec-bad-line 52 "spec line $lineno: '$l' is not a line number" ;; esac
  [ -n "$f" ]  || refuse spec-no-file 52 "spec line $lineno: the file field is empty"
  [ -n "$fd" ] || refuse spec-no-find 52 "spec line $lineno: the find field is empty"
  M_FILE="$M_FILE$f
"; M_LINE="$M_LINE$l
"; M_FIND="$M_FIND$fd
"; M_REPL="$M_REPL$rp
"; M_DESC="$M_DESC${ds:-$fd -> $rp}
"; M_CTRL="$M_CTRL${ct:-no}
"
  M_COUNT=$((M_COUNT + 1))
done < "$SPEC"
[ "$M_COUNT" -gt 0 ] || refuse spec-empty 52 "$SPEC contains no mutants"
nth() { printf '%s\n' "$1" | sed -n "$2p"; }

# --- resolve everything before running anything ------------------------------
i=1
while [ "$i" -le "$M_COUNT" ]; do
  f=$(nth "$M_FILE" "$i"); ln=$(nth "$M_LINE" "$i")
  fd=$(nth "$M_FIND" "$i"); rp=$(nth "$M_REPL" "$i")
  case $f in
    /*)                  refuse spec-absolute-path 52 "mutant $i: file must be relative to the worktree: $f" ;;
    ..|../*|*/../*|*/..) refuse spec-dotdot-path 52 "mutant $i: file may not contain '..': $f" ;;
  esac
  [ -e "$ROOT/$f" ] || refuse no-such-target 52 "mutant $i: no such file in the worktree: $f"
  # A symlink would carry the write outside the worktree, which is the one
  # boundary this design rests on.
  [ -L "$ROOT/$f" ] && refuse symlink-target 52 "mutant $i: $f is a symlink; mutating it would write through
       the link, outside the worktree. Name the file it points at."
  [ -f "$ROOT/$f" ] || refuse not-a-regular-file 52 "mutant $i: not a regular file: $f"
  [ "$fd" = "$rp" ] && refuse no-op-mutant 52 "mutant $i: find and replace are identical ('$fd'), so the file
       would be unchanged and the mutant reported as a survivor — a coverage
       gap that does not exist."
  total=$(awk 'END{print NR}' "$ROOT/$f")
  [ "$ln" -le "$total" ] || refuse line-out-of-range 52 "mutant $i: $f has $total lines, spec says line $ln"
  MT_FIND="$fd" awk -v ln="$ln" 'NR==ln && index($0, ENVIRON["MT_FIND"]) > 0 { ok=1 } END{ exit(ok?0:1) }' "$ROOT/$f" \
    || refuse find-not-on-line 52 "mutant $i: line $ln of $f does not contain: $fd"
  i=$((i + 1))
done

if [ "$DRY" = yes ]; then
  say "$M_COUNT mutant(s) resolve cleanly; nothing was run"
  i=1; while [ "$i" -le "$M_COUNT" ]; do
    printf '%s:%s\t%s\n' "$(nth "$M_FILE" "$i")" "$(nth "$M_LINE" "$i")" "$(nth "$M_DESC" "$i")"
    i=$((i + 1)); done
  exit 0
fi

# --- baseline ----------------------------------------------------------------
OUT=$(mktemp "${TMPDIR:-/tmp}/mutation-test-out.XXXXXX") || refuse tmpfile-out 52 "cannot create a temporary file for the test output"
# Backgrounded and waited on: bash defers trap handling until a foreground
# command returns, so a signal during a test run did nothing until it finished
# — with a file sitting mutated the whole time.
run_test() {
  ( cd "$ROOT" && bash -c "$TEST_CMD" ) </dev/null >"$OUT" 2>&1 &
  TEST_PID=$!
  wait "$TEST_PID"; local rc=$?
  TEST_PID=''
  return "$rc"
}
check_ran() {
  case $1 in 126|127) show_out; refuse test-not-runnable 55 "$2 exited $1: not executable or not found" ;; esac
  [ "$1" -gt 128 ] && { show_out; refuse test-killed 55 "$2 was killed by a signal (exit $1)"; }
  return 0
}
show_out() { say "--- test output ---"; sed 's/^/       /' "$OUT" >&2; }

say "baseline: $TEST_CMD"
rc=0; run_test || rc=$?
check_ran "$rc" "the --test command"
if [ "$rc" -ne 0 ]; then show_out; refuse baseline-red 53 "the baseline is RED (exit $rc). A red baseline cannot judge a mutant."; fi

# --- run them ----------------------------------------------------------------
killed=0; survived=0; SURV_KEYS=''
ctrl_total=0; ctrl_killed=0
i=1
while [ "$i" -le "$M_COUNT" ]; do
  f=$(nth "$M_FILE" "$i"); ln=$(nth "$M_LINE" "$i")
  fd=$(nth "$M_FIND" "$i"); rp=$(nth "$M_REPL" "$i"); ds=$(nth "$M_DESC" "$i")
  ct=$(nth "$M_CTRL" "$i")
  target="$ROOT/$f"

  # Preserve whether the file ended with a newline: awk would otherwise add
  # one, making the mutant differ from the original by more than the edit and
  # turning a newline-sensitive check into a spurious kill.
  had_nl=yes
  [ -n "$(tail -c 1 "$target")" ] && had_nl=no

  tmp=$(mktemp "${TMPDIR:-/tmp}/mutation-test-apply.XXXXXX") || refuse tmpfile-apply 52 "cannot create a temporary file for the edit"
  MT_FIND="$fd" MT_REPL="$rp" awk -v ln="$ln" '
    NR > 1 { printf "\n" }
    NR == ln {
      f = ENVIRON["MT_FIND"]; r = ENVIRON["MT_REPL"]
      p = index($0, f)
      if (p > 0) { $0 = substr($0, 1, p - 1) r substr($0, p + length(f)) }
    }
    { printf "%s", $0 }
  ' "$target" > "$tmp" || { rm -f "$tmp"; refuse apply-build-failed 52 "mutant $i: could not build the mutated $f"; }
  [ "$had_nl" = yes ] && printf '\n' >> "$tmp"

  MUTATED=$f
  cat "$tmp" > "$target" || { rm -f "$tmp"; refuse apply-write-failed 52 "mutant $i: could not write $f"; }
  rm -f "$tmp"

  # The edit must actually change the file, or a "survivor" means nothing.
  if git diff --quiet -- "$f" 2>/dev/null; then
    restore_mutated
    refuse mutant-had-no-effect 52 "mutant $i: applying it left $f unchanged, so a survivor would be a
       coverage gap that does not exist."
  fi

  rc=0; run_test || rc=$?
  restore_mutated
  check_ran "$rc" "the --test command (mutant $i)"

  [ "$ct" = control ] && ctrl_total=$((ctrl_total + 1))
  if [ "$rc" -eq 0 ]; then
    survived=$((survived + 1)); verdict=SURVIVED
    SURV_KEYS="$SURV_KEYS$f:$ln
"
  else
    killed=$((killed + 1)); verdict=killed
    [ "$ct" = control ] && ctrl_killed=$((ctrl_killed + 1))
  fi
  [ "$ct" = control ] && verdict="$verdict*"
  printf '%-10s %s:%s\t%s\n' "$verdict" "$f" "$ln" "$ds"
  i=$((i + 1))
done
rm -f "$OUT"; OUT=''

say ""
say "$M_COUNT mutant(s): $killed killed, $survived survived"
[ "$ctrl_total" -gt 0 ] && say "  (* = control, $ctrl_killed of $ctrl_total killed)"

# A control settles what the heuristic can only guess. If one died, the tests
# demonstrably see edits to this checkout, so every other survivor is a real
# coverage gap and there is nothing to refuse.
if [ "$ctrl_total" -gt 0 ]; then
  if [ "$ctrl_killed" -eq 0 ]; then
    refuse control-survived 54 "every control mutant survived.

       A control is a line you said was covered, so its mutant should have been
       killed. It was not, which points at the environment rather than at the
       coverage: a test suite resolving to a DIFFERENT copy of the source
       produces exactly this — an editable install records an absolute path, so
       the tests import the tree you did not mutate.

       Check that --test exercises these files and runs against this directory
       rather than an installed copy. If the control line turns out not to be
       covered after all, pick one that is."
  fi
else
  # No control, so fall back to a heuristic — and say what it cannot know.
  distinct=$(printf '%s' "$SURV_KEYS" | sed '/^$/d' | sort -u | grep -c . || true)
  if [ "$killed" -eq 0 ] && [ "$distinct" -ge 2 ]; then
    refuse all-survived 54 "every mutant survived, across $distinct distinct lines, and no
       control was given.

       That is what a suite resolving to a DIFFERENT copy of the source looks
       like — an editable install records an absolute path, so the tests import
       the tree you did not mutate. It is ALSO what genuinely untested code
       looks like, and this run cannot tell the two apart.

       Settle it by marking one mutant 'control' in a sixth column, on a line
       you are confident is covered. If that mutant dies, the wiring is proven
       and the survivors are real coverage gaps rather than a warning."
  fi
fi

if [ "$survived" -gt 0 ]; then
  say ""
  say "Survivors are coverage gaps, not bugs: the code is usually correct as"
  say "written, and the finding is that a future edit could change behaviour"
  say "with the suite still green. Report them; do not write the tests unasked."
fi
exit 0
