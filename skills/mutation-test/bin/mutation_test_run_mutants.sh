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
# on a line you are confident IS covered.
#
# THE RULE IS: A RUN IN WHICH NOTHING DIED IS REFUSED, PROVIDED THERE IS ENOUGH
# TO CONCLUDE FROM -- either a control was given, or the survivors span two or
# more distinct lines. A LONE SURVIVOR IS REPORTED, not refused: one mutant on
# one line cannot tell a broken environment from an uncovered line, so refusing
# it would be a guess in the other direction. Anything killed --
# control or not -- proves the tests see edits to this checkout, so every
# survivor beside it is a real coverage gap and the run reports normally. What a
# control buys is a refusal that can say why: "you told me this line was covered
# and its mutant lived too" is a diagnosis, where the shape of the result alone
# is only a suspicion.
#
# So a surviving control is NOT a refusal once something else has died. The
# wiring is proven, and the honest reading is that the line you picked is not
# covered after all. The run says so in a NOTE and carries on. Refusing there
# would throw away a sound report over one wrong guess about coverage -- and
# since there is deliberately no coverage map, guessing is the normal case.
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
#   53 baseline red   54 nothing was killed and the result cannot be read
#   55 the test never ran
set -uo pipefail

SPEC=''
TEST_CMD=''
DRY=no
TEST_PID=''
MUTATED=''
BACKUP=''
BACKUP_KEPT=''
RESTORE_FAILED=''
RESTORE_ERR=''
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
                 `control` is the SIXTH field, so leave the description empty to
                 reach it without writing one:
                   file<TAB>line<TAB>find<TAB>replace<TAB><TAB>control
                 Mark one mutant `control` on a line you know is covered. A run
                 in which nothing was killed is refused when there is enough to
                 conclude from -- a control, or survivors on two or more distinct
                 lines. A control makes that refusal specific instead of a guess.
                 A lone survivor is reported, because one mutant cannot tell a
                 broken environment from an uncovered line.
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

# Restores the ONE file this run has mutated, from a byte-exact copy taken
# before the write. This was `git checkout -- <path>`, which was wrong in four
# separate ways, each found the hard way:
#
#   - it restores from the INDEX, not HEAD. A --test that stages anything
#     (pre-commit, lint-staged, a codegen step, `git add -A`) put each mutant
#     into the index, so every restore became a silent no-op: mutants
#     accumulated, later ones were judged against earlier ones, and a three
#     mutant run reported "3 killed, 0 survived" with all three still applied.
#   - a pathspec GLOBS, so a file literally named `[id].tsx` -- the Next.js and
#     SvelteKit routing convention -- matched other tracked paths and the
#     restore was a no-op on the real file, exiting 0.
#   - it cannot restore an untracked path at all.
#   - whether it restores an --assume-unchanged path is git-version-dependent.
#
# A copy has none of those properties, and needs no guards against them. The
# runner is serial by design -- exactly one file is mutated at any moment -- so
# this is ONE backup with no key derived from the path. A non-injective path key
# was the original runner's worst defect; there is no key here to get wrong.
#
# It REPORTS rather than decides: on the normal path a failed restore is fatal,
# but inside the EXIT trap refusing would overwrite the exit code the run had
# already earned. And it VERIFIES the bytes instead of trusting an exit status,
# which is what hid the accumulation above.
restore_mutated() {
  [ -n "$MUTATED" ] || return 0
  lost=$MUTATED; keep=$BACKUP
  MUTATED=''; BACKUP=''
  # The cmp is defence against a partial write (a full disk or quota), NOT a
  # tested branch -- deleting it leaves the suite green, and no fixture here can
  # fill a filesystem. It is kept because it is cheap and the alternative is
  # trusting an exit status, which is exactly what hid the accumulation above.
  if [ -n "$keep" ]; then
    # `2>&1 >file`, in that order: stderr goes to the substitution and stdout to
    # the file. Written the other way round (`>file 2>&1`) stderr follows stdout
    # INTO the file being restored, so a failure would write its own error
    # message over the content it is meant to be putting back. The linter here
    # was silent about it at 0.9.0; the newer one on the macOS runner was not.
    RESTORE_ERR=$(cat "$keep" 2>&1 > "$ROOT/$lost") || true
    if [ -z "$RESTORE_ERR" ] && cmp -s "$keep" "$ROOT/$lost"; then
      rm -f "$keep"
      return 0
    fi
  fi
  RESTORE_FAILED=$lost; BACKUP_KEPT=$keep
  return 1
}
cleanup() {
  [ -n "$TEST_PID" ] && kill "$TEST_PID" 2>/dev/null
  restore_mutated || say "WARNING: $RESTORE_FAILED is STILL MUTATED — its backup copy is $BACKUP_KEPT"
  [ -n "$OUT" ] && rm -f "$OUT"
  return 0
}
on_signal() { cleanup; trap - EXIT; say ""; say "interrupted — the mutated file was restored from its backup copy"; exit 130; }
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
       Mutating here would edit your real files. Every mutant IS undone from a
       byte-exact copy, but a crash between the write and the restore would
       leave one applied, and this design rests on the checkout being
       disposable. Run it as the command of 'mutation_test_worktree.sh run'." ;;
esac
ROOT=$(git rev-parse --show-toplevel) || refuse no-toplevel 52 "cannot find the worktree root"
# The spec path is resolved BEFORE the cd below, so a relative --spec keeps
# working from wherever the caller stood.
case $SPEC in (/*) : ;; (*) SPEC="$PWD/$SPEC" ;; esac
# The script works from the worktree root. This mattered far more when git
# pathspecs decided whether a target was safe to touch: run from a subdirectory
# those resolved against the CURRENT directory, matched nothing, and every guard
# went quiet while the mutation still landed through the absolute "$ROOT/$f".
# Those guards are gone with the pathspecs, but the cd stays -- --test expects
# to run at the root, and so do relative paths in a spec.
cd "$ROOT" || refuse root-unreachable 52 "cannot enter the worktree root: $ROOT"

# --- read the spec -----------------------------------------------------------
# One line per mutant, so a malformed record cannot silently merge with its
# neighbour. bash 3.2 has no arrays worth using here, so the fields are kept as
# newline-joined strings and read back by line number.
M_FILE=''; M_LINE=''; M_FIND=''; M_REPL=''; M_DESC=''; M_CTRL=''; M_COUNT=0
lineno=0
cr=$(printf '\r')
while IFS= read -r sl || [ -n "$sl" ]; do
  lineno=$((lineno + 1))
  # A spec written on Windows carries a CR into the LAST field, so `control\r`
  # is not `control` and the refusal below printed "must be 'control', not
  # 'control'" -- two strings that render identically, sending the reader to
  # look for a typo that is not there.
  sl=${sl%"$cr"}
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
    if [ "$ntab" -eq 4 ]; then
      ds=$r4
    else
      ds=${r4%%"$tab"*}; ct=${r4#*"$tab"}
    fi
    # `control` is the SIXTH field. Writing it fifth is how you believe you
    # marked a control and did not: it parsed as the description, the run lost
    # its only wiring evidence, and it reported a confident coverage gap.
    #
    # Checked AFTER ct is known, so a trailing tab (`...<TAB>control<TAB>`, five
    # separators with an empty sixth field) is caught too -- it skipped the
    # check entirely when this lived in the four-separator branch. And the value
    # is TRIMMED before an exact compare rather than matched with globs that
    # allowed exactly one space: column-aligned specs pad with several, and the
    # glob form also refused a legitimate description ending in the word.
    if [ -z "$ct" ]; then
      dtrim=$ds
      while [ "${dtrim# }" != "$dtrim" ]; do dtrim=${dtrim# }; done
      while [ "${dtrim%% }" != "$dtrim" ]; do dtrim=${dtrim%% }; done
      case $dtrim in
        ([Cc][Oo][Nn][Tt][Rr][Oo][Ll])
          refuse spec-control-needs-desc 52 "spec line $lineno: 'control' must be the SIXTH field, not the fifth.
Leave the description empty to reach it:
  file<TAB>line<TAB>find<TAB>replace<TAB><TAB>control" ;;
      esac
    fi
  fi
  # A sixth field must be exactly `control`. Anything else is refused rather
  # than ignored: a typo that silently stopped being a control would remove the
  # evidence the run depends on.
  case $ct in
    (''|control) : ;;
    (*) refuse spec-bad-control 52 "spec line $lineno: the sixth field must be the word 'control', not [$ct].
The brackets are there so trailing whitespace is visible." ;;
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
  # No tracked/clean/index-bit guards here. They existed because the restore was
  # `git checkout --`, which cannot undo a mutation to an untracked file, a
  # glob-shadowed name, or a path git has been told to ignore -- so those files
  # had to be refused rather than touched. Restoring from a byte-exact copy
  # undoes any of them, so the guards went with the primitive that needed them.
  [ "$fd" = "$rp" ] && refuse no-op-mutant 52 "mutant $i: find and replace are identical ('$fd'), so the file
       would be unchanged and the mutant reported as a survivor — a coverage
       gap that does not exist."
  # Without this, an unreadable target made awk fail, left `total` empty, and the
  # line-range test below died with "[: : integer expression expected" -- a raw
  # shell error rather than a refusal, which under the bundled-script invariant
  # sends the reader editing a script that is working correctly.
  [ -r "$ROOT/$f" ] || refuse unreadable-target 52 "mutant $i: cannot read $f. Check its permissions."
  total=$(awk 'END{print NR}' "$ROOT/$f")
  [ "$ln" -le "$total" ] || refuse line-out-of-range 52 "mutant $i: $f has $total lines, spec says line $ln"
  MT_FIND="$fd" awk -v ln="$ln" 'NR==ln && index($0, ENVIRON["MT_FIND"]) > 0 { ok=1 } END{ exit(ok?0:1) }' "$ROOT/$f" \
    || refuse find-not-on-line 52 "mutant $i: line $ln of $f does not contain: $fd"
  i=$((i + 1))
done

if [ "$DRY" = yes ]; then
  dctrl=0
  i=1; while [ "$i" -le "$M_COUNT" ]; do
    [ "$(nth "$M_CTRL" "$i")" = control ] && dctrl=$((dctrl + 1))
    i=$((i + 1)); done
  # Say what they resolved AGAINST. A dry run reads the worktree as it stands,
  # which for a borrowed worktree includes uncommitted edits; the composed run
  # cuts a fresh checkout from a ref and will not see them, so a spec that dry-
  # runs clean here can still fail to resolve there.
  say "$M_COUNT mutant(s) resolve cleanly against the files in $ROOT as they are"
  say "now, $dctrl marked control; nothing was run"
  i=1; while [ "$i" -le "$M_COUNT" ]; do
    mark=' '; [ "$(nth "$M_CTRL" "$i")" = control ] && mark='*'
    printf '%s %s:%s\t%s\n' "$mark" "$(nth "$M_FILE" "$i")" "$(nth "$M_LINE" "$i")" "$(nth "$M_DESC" "$i")"
    i=$((i + 1)); done
  # Whether a control registered is the one thing a dry run has to show. Without
  # it the spec that mis-slots `control` into the description listed a mutant
  # described as "control" -- reading as confirmation of the very thing that had
  # failed to happen.
  if [ "$dctrl" -eq 0 ]; then
    say ""
    say "No control in this spec. If every mutant survives across two or more"
    say "distinct lines, the run will be REFUSED rather than reported. Mark one"
    say "'control' in a sixth field, on a line you are confident is covered, to"
    say "get a verdict either way."
  fi
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
ctrl_total=0; ctrl_killed=0; CTRL_SURV=''
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

  # Taken BEFORE the write, so the trap never sees a mutated file it cannot
  # undo. MUTATED is set only once the backup exists.
  BACKUP=$(mktemp "${TMPDIR:-/tmp}/mutation-test-backup.XXXXXX") || { rm -f "$tmp"; refuse tmpfile-backup 52 "cannot create a temporary file to back up $f"; }
  cat "$target" > "$BACKUP" || { rm -f "$tmp" "$BACKUP"; BACKUP=''; refuse backup-failed 52 "mutant $i: could not copy $f before mutating it"; }
  MUTATED=$f
  cat "$tmp" > "$target" || { rm -f "$tmp"; refuse apply-write-failed 52 "mutant $i: could not write $f"; }
  rm -f "$tmp"

  # The edit must actually change the file, or a "survivor" means nothing. This
  # compares BYTES against the backup. It used to ask git, which answers about
  # the index rather than the file and says nothing for an untracked or
  # glob-shadowed path -- so it once denied an overwrite it had just performed.
  if cmp -s "$BACKUP" "$target"; then
    refuse mutant-had-no-effect 52 "mutant $i: $f is byte-identical after applying the mutant, so a
       survivor would be a coverage gap that does not exist."
  fi

  rc=0; run_test || rc=$?
  restore_mutated || refuse restore-failed 52 "mutant $i: could not restore $RESTORE_FAILED from its backup copy.
It is still MUTATED, so every verdict from here on would be measured against a
file that no longer matches your source. The run stops rather than report them.
The backup was kept: $BACKUP_KEPT
${RESTORE_ERR:+The error was: $RESTORE_ERR}"
  check_ran "$rc" "the --test command (mutant $i)"

  [ "$ct" = control ] && ctrl_total=$((ctrl_total + 1))
  if [ "$rc" -eq 0 ]; then
    survived=$((survived + 1)); verdict=SURVIVED
    SURV_KEYS="$SURV_KEYS$f:$ln
"
    [ "$ct" = control ] && CTRL_SURV="$CTRL_SURV$f:$ln
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

# Anything killed -- control or not -- proves the tests see edits to THIS
# checkout, so nothing in such a run is refusable. Only a run in which nothing
# at all died is indistinguishable from a suite reading a different copy of the
# source. An earlier version refused whenever every CONTROL survived without
# consulting `killed`, so a control that was merely a bad guess about coverage
# threw away a report the same run had just proven sound -- and blamed an
# environment the killed mutant exonerated.
if [ "$killed" -eq 0 ]; then
  if [ "$ctrl_total" -gt 0 ]; then
    refuse control-survived 54 "nothing was killed, including the $ctrl_total mutant(s) you marked control.

       A control is a line you said was covered, so its mutant should have been
       killed. Nothing was, which points at the environment rather than at the
       coverage: a test suite resolving to a DIFFERENT copy of the source
       produces exactly this — an editable install records an absolute path, so
       the tests import the tree you did not mutate.

       Check that --test exercises these files and runs against this directory
       rather than an installed copy. If the control line turns out not to be
       covered after all, pick one that is."
  fi
  # No control, so fall back to a heuristic — and say what it cannot know.
  distinct=$(printf '%s' "$SURV_KEYS" | sed '/^$/d' | sort -u | grep -c . || true)
  if [ "$distinct" -ge 2 ]; then
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

# Reached only when something died, so the wiring is not in question. A control
# that survived here is not a refusal: it is the caller's belief about coverage
# being wrong, which is worth saying plainly and is no reason to discard the
# rest of the report.
if [ -n "$CTRL_SURV" ]; then
  say ""
  say "NOTE: you marked these lines 'control', and their mutants survived:"
  printf '%s' "$CTRL_SURV" | sed '/^$/d;s/^/  /' >&2
  say "Something else WAS killed, so the tests do see this checkout. Those"
  say "lines are simply not covered after all. Pick a control that is, if you"
  say "want the next run's verdict to rest on something."
fi

if [ "$survived" -gt 0 ]; then
  say ""
  say "Survivors are coverage gaps, not bugs: the code is usually correct as"
  say "written, and the finding is that a future edit could change behaviour"
  say "with the suite still green. Report them; do not write the tests unasked."
fi
exit 0
