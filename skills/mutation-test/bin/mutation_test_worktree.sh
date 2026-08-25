#!/usr/bin/env bash
# mutation_test_worktree.sh — run a command inside a throwaway checkout that has
# been PROVEN to be a valid place to mutate, then tear the checkout down.
#
# WHY THERE IS NO `destroy` SUBCOMMAND
#
# There was one. Twice it deleted a repository — .git and uncommitted work — and
# printed "removed" with exit 0. The first time it never asked whether the path
# was a worktree. The second time it asked three times, printed git's refusal,
# and deleted anyway because the return status was captured but never tested.
#
# Both failures needed the same ingredient: a pre-approved wrapper that deletes
# a path the caller names. So the wrapper no longer takes a path to delete.
# `run` owns the worktree from creation to teardown and never lets its path
# cross the boundary; with --keep it prints the path and the exact `git worktree
# remove` command, which is git's own guarded operation and prompts like any
# other. There is nothing here for a stale variable or a crafted argument to aim.
#
# WHAT THE GATES DO AND DO NOT PROVE
#
# Before your command runs, this establishes:
#
#   0. the working tree agrees with the checked-out ref about the probe file, so
#      you are not scoring committed code while looking at uncommitted edits
#   1. the baseline is green — a red baseline cannot judge a mutant
#   2. --test does NOT react to unrelated changes in the tree. A step like
#      `git diff --exit-code` goes red for ANY edit, which would make every
#      probe below meaningless
#   3. breaking the probe file's syntax turns --test red
#   4. emptying the probe file ALSO turns --test red, with different output.
#      Same output from both usually means one static step objected to both
#
# It does NOT prove that the step which judges mutants EXECUTES the file.
# Nothing content-shaped can: a type checker, a linter, or a formatter reacts to
# a file it never runs. If you need that established, pass --exec-probe with a
# snippet that is valid in the language and fatal when executed (for Python,
# `raise SystemExit(97)`); only the caller knows the language.
#
# EXECUTION SURFACE. --setup, --test and the trailing command are run with
# `bash -c` inside the worktree, verbatim. Never assemble them from repository
# content (a README, a Makefile, a CI config) without showing the user what will
# run: a permission rule approving this script approves the wrapper, not the
# payload.
#
# EXIT CODES. Gate failures use 60-69 so they cannot be confused with the exit
# status of your command, which is passed through unchanged:
#   60 usage    61 missing dependency    62 worktree or setup failed
#   63 baseline red                      64 the probe proved nothing
#   65 --test did not run to a verdict   66 repository state refuses the run
#   130 interrupted
# Any other status is your command's own.
set -uo pipefail

PROBE_MARK='!!!mutation_test_wiring_probe!!!'
SCRATCH_NAME='.mutation_test_tree_reactivity_probe'

WT=''
REPO=''
SAVED=''
PROBE_REL=''
KEEP=no
SUCCEEDED=no
OUT_A=''
OUT_B=''

usage() {
  cat <<'USAGE'
Usage:
  mutation_test_worktree.sh run --test <cmd> --probe <file> [options] -- <command>...

Creates a throwaway worktree, proves it is a valid place to mutate, runs your
command inside it, and removes it. The worktree path never leaves this script;
your command sees it as the working directory and in $MUTATION_TEST_WORKTREE.

Required:
  --test  <cmd>      command that judges a mutant; must exit 0 on clean source
  --probe <file>     repo-relative file your command intends to mutate

Optional:
  --setup <cmd>      bootstrap to run in the worktree first, e.g.
                     'uv sync --frozen && git submodule update --init'
  --exec-probe <txt> text appended to the probe file that is VALID in the
                     language and fatal when executed (Python:
                     'raise SystemExit(97)'). The only way to establish that
                     --test executes the file rather than merely reading it.
  --repo  <path>     repository to branch from (default: current directory)
  --ref   <ref>      commit-ish to check out (default: HEAD)
  --keep              on failure, keep the worktree and print how to remove it

Exit codes 60-69 are this script's own; anything else is your command's status.
USAGE
}

say() { printf '%s\n' "$*" >&2; }
die() { local code=$1; shift; say "Error: $*"; exit "$code"; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die 61 "missing required command: $c (install it; do not work around this)"
  done
}

abspath_dir() { ( cd "$1" 2>/dev/null && pwd -P ) || return 1; }

validate_ref() {
  case $1 in
    '')    die 60 "ref may not be empty" ;;
    -*)    die 60 "ref may not begin with '-': $1" ;;
    *..*)  die 60 "ref may not contain '..': $1" ;;
  esac
}

validate_probe_arg() {
  case $1 in
    '')               die 60 "probe path may not be empty" ;;
    /*)               die 60 "probe must be repo-relative, not absolute: $1" ;;
    ..|../*|*/../*|*/..) die 60 "probe may not contain a '..' component: $1" ;;
  esac
}

restore_probe() {
  [ -n "$SAVED" ] || return 0
  [ -f "$SAVED" ] || return 0
  if [ -n "$WT" ] && [ -n "$PROBE_REL" ] && [ -f "$WT/$PROBE_REL" ]; then
    cat "$SAVED" > "$WT/$PROBE_REL" 2>/dev/null || true
  fi
  rm -f "$SAVED"
  SAVED=''
}

# Deregistration goes through git, which refuses a main working tree. There is
# deliberately no `git worktree prune` here: prune is repo-wide and would
# deregister a user's unrelated worktree whose directory is merely unavailable
# (an unmounted drive, a stale network mount).
remove_worktree() {
  [ -n "$WT" ] || return 0
  [ -d "$WT" ] || return 0
  if [ -n "$REPO" ]; then
    git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
  fi
  # Only ever a path this script made with mktemp, never one a caller named.
  [ -d "$WT" ] && rm -rf "$WT"
  return 0
}

keep_notice() {
  say ""
  say "worktree kept at: $WT"
  say "remove it with:   git -C '$REPO' worktree remove --force '$WT'"
}

cleanup() {
  [ -n "$OUT_A" ] && rm -f "$OUT_A"
  [ -n "$OUT_B" ] && rm -f "$OUT_B"
  restore_probe
  if [ "$KEEP" = yes ] && [ "$SUCCEEDED" != yes ] && [ -n "$WT" ] && [ -d "$WT" ]; then
    keep_notice
  else
    remove_worktree
  fi
}

on_signal() { cleanup; trap - EXIT; exit 130; }
on_exit()   { cleanup; }

run_in_wt() { ( cd "$WT" && bash -c "$1" ) </dev/null; }

cmd_run() {
  local test_cmd='' probe='' setup_cmd='' exec_probe='' repo='' ref='HEAD'
  local ref_given=no probe_dir_abs wt_abs rc

  while [ $# -gt 0 ]; do
    case $1 in
      --test)       [ $# -ge 2 ] || die 60 "--test needs a value";       test_cmd=$2;   shift 2 ;;
      --probe)      [ $# -ge 2 ] || die 60 "--probe needs a value";      probe=$2;      shift 2 ;;
      --setup)      [ $# -ge 2 ] || die 60 "--setup needs a value";      setup_cmd=$2;  shift 2 ;;
      --exec-probe) [ $# -ge 2 ] || die 60 "--exec-probe needs a value"; exec_probe=$2; shift 2 ;;
      --repo)       [ $# -ge 2 ] || die 60 "--repo needs a value";       repo=$2;       shift 2 ;;
      --ref)        [ $# -ge 2 ] || die 60 "--ref needs a value";        ref=$2; ref_given=yes; shift 2 ;;
      --keep)       KEEP=yes; shift ;;
      -h|--help)    usage; exit 0 ;;
      --)           shift; break ;;
      *) die 60 "unknown argument: $1" ;;
    esac
  done

  [ $# -ge 1 ]       || { say "Error: a command to run must follow --"; usage; exit 60; }
  [ -n "$test_cmd" ] || { say "Error: --test is required";  usage; exit 60; }
  [ -n "$probe" ]    || { say "Error: --probe is required"; usage; exit 60; }
  validate_ref "$ref"
  validate_probe_arg "$probe"
  require_cmd git cmp mktemp basename dirname

  [ -n "$repo" ] || repo=$PWD
  [ -d "$repo" ] || die 60 "no such directory: $repo"
  repo=$(abspath_dir "$repo") || die 60 "cannot resolve: $repo"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die 60 "not a git repository: $repo"

  # Anchor to the TOPLEVEL. A pathspec is resolved relative to the -C directory,
  # so from a subdirectory a repo-root-relative probe matches nothing and every
  # pathspec check below silently succeeds.
  REPO=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || die 60 "cannot find the repository root of $repo"
  REPO=$(abspath_dir "$REPO") || die 60 "cannot resolve the repository root"

  git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 ||
    die 60 "ref does not resolve to a commit in $REPO: $ref"

  # Gate 0. Only meaningful for the DEFAULT ref: an explicit --ref says the
  # caller means a specific commit, and a historical commit differing from the
  # working tree is the normal case, not an error.
  if [ "$ref_given" = no ]; then
    git -C "$REPO" diff --quiet HEAD -- ":(literal,top)$probe"
    rc=$?
    if [ "$rc" -eq 1 ]; then
      die 66 "the working tree and HEAD disagree about $probe.
       A worktree holds committed work only, so this run would judge the
       COMMITTED version while you are looking at your edits. Commit first, or
       pass --ref to say which commit you meant."
    elif [ "$rc" -gt 1 ]; then
      die 62 "git could not compare $probe against HEAD in $REPO (git exited $rc)"
    fi
  else
    say "note: --ref $ref given; the working tree is not consulted"
  fi

  PROBE_REL=$probe
  WT=$(mktemp -d "${TMPDIR:-/tmp}/mutation-test-wt.XXXXXX") || die 62 "cannot create a temporary directory"
  trap on_signal INT TERM HUP QUIT
  trap on_exit EXIT

  local err
  err=$(git -C "$REPO" worktree add --detach "$WT" "$ref" 2>&1) || \
    die 62 "git worktree add failed for $ref in $REPO:
       $err"

  [ -e "$WT/$probe" ] || die 66 "--probe file not present at $ref: $probe"
  [ -L "$WT/$probe" ] && die 60 "refusing: $probe is a symlink. Writing the probe would
       follow it out of the worktree. Name the file it points at instead."
  [ -f "$WT/$probe" ] || die 60 "not a regular file: $probe"

  # Containment. An intermediate DIRECTORY may be a symlink even when the file
  # is not, so resolve the parent and require it inside the worktree. The
  # trailing slash on both sides stops /a/b matching /a/bc.
  probe_dir_abs=$(abspath_dir "$(dirname "$WT/$probe")") || die 62 "cannot resolve the probe's directory"
  wt_abs=$(abspath_dir "$WT") || die 62 "cannot resolve $WT"
  case "$probe_dir_abs/" in
    "$wt_abs"/*) : ;;
    *) die 60 "refusing: $probe resolves outside the worktree ($probe_dir_abs)" ;;
  esac

  if [ -n "$setup_cmd" ]; then
    say "setup: $setup_cmd"
    run_in_wt "$setup_cmd" >&2 || die 62 "setup command failed in the worktree; the checkout cannot run tests"
  fi

  say "gate 1/5 baseline: $test_cmd"
  run_in_wt "$test_cmd" >&2 || die 63 "baseline is RED at $ref. A red baseline cannot judge a mutant.
       Usually the bootstrap is incomplete - a missing virtualenv, an
       uninitialised submodule, an absent build step. Pass it with --setup."

  # Gate 2. If --test reacts to ANY change in the tree, every probe below goes
  # red for a reason that has nothing to do with the probe file.
  say "gate 2/5 tree-reactivity control: expecting GREEN"
  : > "$WT/$SCRATCH_NAME"
  rc=0; run_in_wt "$test_cmd" >/dev/null 2>&1 || rc=$?
  rm -f "$WT/$SCRATCH_NAME"
  if [ "$rc" -ne 0 ]; then
    die 64 "--test goes RED on a second run when only an unrelated file was added.
       Two causes look identical from here and both make every probe below
       meaningless: the command reacts to TREE STATE (a 'git diff --exit-code'
       or dirty-tree guard goes red for any edit at all), or it is NOT
       IDEMPOTENT (it writes a stamp file, runs a migration, rewrites
       snapshots) so a second run can never be green. Either way nothing below
       could tell your mutation apart from the mutation's side effects. Point
       --test at the command that judges mutants, and make it repeatable."
  fi

  OUT_A=$(mktemp "${TMPDIR:-/tmp}/mutation-test-out.XXXXXX") || die 62 "cannot create a temporary file"
  OUT_B=$(mktemp "${TMPDIR:-/tmp}/mutation-test-out.XXXXXX") || die 62 "cannot create a temporary file"
  SAVED=$(mktemp "${TMPDIR:-/tmp}/mutation-test-probe.XXXXXX") || die 62 "cannot create a temporary file"
  cat "$WT/$probe" > "$SAVED" || die 62 "cannot read $probe"

  probe_run() { # mode, output-file — always restores before returning
    local mode=$1 dest=$2 r=0
    case $mode in
      marker) { printf '%s\n' "$PROBE_MARK"; cat "$SAVED"; } > "$WT/$probe" || die 62 "cannot write $probe" ;;
      empty)  : > "$WT/$probe" || die 62 "cannot write $probe" ;;
      exec)   { cat "$SAVED"; printf '\n%s\n' "$exec_probe"; } > "$WT/$probe" || die 62 "cannot write $probe" ;;
    esac
    run_in_wt "$test_cmd" >"$dest" 2>&1 || r=$?
    cat "$SAVED" > "$WT/$probe" || die 62 "cannot restore $probe in the worktree"
    cmp -s "$SAVED" "$WT/$probe" || die 62 "probe file did not restore cleanly: $probe"
    PROBE_RC=$r
  }

  check_ran() { # a command that never reached a verdict is not evidence
    if [ "$PROBE_RC" -eq 126 ] || [ "$PROBE_RC" -eq 127 ] || [ "$PROBE_RC" -gt 128 ]; then
      say "--- test output ---"; sed 's/^/       /' "$1" >&2
      die 65 "--test exited $PROBE_RC with $probe altered, so it did not RUN
       (126/127 = not executable or not found, >128 = killed by a signal).
       That is breakage, not evidence that the mutation was seen."
    fi
  }

  say "gate 3/5 syntax probe: expecting RED"
  probe_run marker "$OUT_A"
  check_ran "$OUT_A"
  if [ "$PROBE_RC" -eq 0 ]; then
    say "--- test output with $probe corrupted ---"; sed 's/^/       /' "$OUT_A" >&2
    die 64 "--test still PASSES with $probe corrupted, so it is not reading the
       worktree's copy of that file. Anything scored here would be a false
       survivor. Usually the environment was reused from the host and resolves
       to the original tree (an editable install records an absolute path), or
       nothing in --test touches $probe at all. Bootstrap inside the worktree
       with --setup rather than reusing the host's."
  fi

  # An already-empty probe file makes gate 4 a no-op, and reporting a no-op as
  # a failure would be a diagnosis that cannot be acted on.
  if [ ! -s "$SAVED" ]; then
    say "gate 4/5 skipped: $probe is empty, so emptying it proves nothing"
  else
    say "gate 4/5 semantic probe: expecting RED, with different output"
    probe_run empty "$OUT_B"
    check_ran "$OUT_B"
    if [ "$PROBE_RC" -eq 0 ]; then
      say "--- test output with $probe emptied ---"; sed 's/^/       /' "$OUT_B" >&2
      die 64 "corrupting $probe turned --test red, but EMPTYING it did not. So
       something in --test parses this file while the step that judges mutants
       never reads it — typically a lint or type-check step failing first in a
       compound command, with the real suite resolving to another tree."
    fi
    if cmp -s "$OUT_A" "$OUT_B"; then
      say "--- identical output from both probes ---"; sed 's/^/       /' "$OUT_A" >&2
      die 64 "a syntax break and an emptied file produced byte-identical output
       from --test, which means one step objected to both without looking at
       what changed — a licence-header lint or a file-policy check behaves this
       way. Neither probe established anything about the mutation."
    fi
  fi

  if [ -n "$exec_probe" ]; then
    say "gate 4b/5 execution probe: expecting RED"
    probe_run exec "$OUT_B"
    check_ran "$OUT_B"
    [ "$PROBE_RC" -eq 0 ] && die 64 "--test PASSES with the --exec-probe snippet appended to $probe,
       so nothing in --test EXECUTES that file. A static check can react to a
       file it never runs; this is the probe that tells them apart."
  fi

  say "gate 5/5 re-baseline: expecting GREEN again"
  run_in_wt "$test_cmd" >&2 || die 64 "--test does not return to GREEN after $probe is restored, so its
       red result was not attributable to the mutation. Usually the command is
       not idempotent (a stamp file, a migration, a snapshot writer) or flaky."

  rm -f "$SAVED"; SAVED=''
  rm -f "$OUT_A" "$OUT_B"; OUT_A=''; OUT_B=''
  if [ -n "$exec_probe" ]; then
    say "ok: mutation visible in $probe AND executed by --test; running your command"
  else
    say "ok: mutation visible in $probe (not proven executed — see --exec-probe); running your command"
  fi

  # The caller's command owns the worktree from here. Its exit status is passed
  # through, which is why the gates above use 60-69.
  local user_rc=0
  ( cd "$WT" && MUTATION_TEST_WORKTREE="$WT" bash -c '"$@"' _ "$@" ) || user_rc=$?

  SUCCEEDED=yes
  [ "$KEEP" = yes ] && keep_notice || remove_worktree
  trap - INT TERM HUP QUIT
  trap - EXIT
  return "$user_rc"
}

case ${1:-} in
  run)       shift; cmd_run "$@" ;;
  -h|--help) usage; exit 0 ;;
  '')        usage; exit 60 ;;
  create|destroy)
    say "Error: '$1' was removed. This script no longer takes a path to delete;"
    say "       twice that deleted a repository and reported success. Use 'run',"
    say "       which owns the worktree end to end. See --help."
    exit 60 ;;
  *) say "Error: unknown subcommand: $1"; usage; exit 60 ;;
esac
