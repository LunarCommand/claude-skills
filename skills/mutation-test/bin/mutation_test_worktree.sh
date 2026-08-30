#!/usr/bin/env bash
# mutation_test_worktree.sh — hand a caller a throwaway checkout whose test
# suite is known to be green, then tear it down.
#
# It claims nothing else, and that is the point.
#
# WHAT THIS USED TO CLAIM, AND WHY IT STOPPED
#
# Earlier versions tried to PROVE, before handing the worktree over, that the
# test command would actually see a mutation — the failure being guarded
# against is an environment that resolves imports to the ORIGINAL tree (a
# Python editable install records an absolute path), so every mutant survives
# and the run reports "no covering tests" with exit 0.
#
# Three designs tried to establish that from exit codes. Each was defeated:
#
#   * break the file's syntax and require RED — a lint step objects while the
#     step that judges mutants never runs
#   * ALSO empty the file and require RED — a type checker notices the symbol
#     is gone without executing anything
#   * ALSO append a fatal snippet and require RED — a formatter objects to the
#     appended bytes; and in Go, Rust, Java or C there is no legal top-level
#     fatal statement, so every snippet is a parse error and the gate always
#     said yes
#   * a control that added an untracked file and required GREEN, meant to rule
#     the whole family out — `git diff` cannot see untracked files, so
#     `git diff --exit-code`, the archetype it named, sailed through
#
# They all measure the same thing: does --test react to this file's bytes
# changing? Any step that merely READS the file satisfies every one of them.
# A fourth probe would be a fourth confoundable signal, not a stronger proof.
#
# So the wiring question is not answered here. It is answered by the CALLER,
# from the run's own results: mutate several independent lines, and if EVERY
# mutant survives, the environment is almost certainly mis-wired. That signal
# cannot be fooled by a formatter, needs no language knowledge, and costs
# nothing because the mutants were being run anyway.
#
# WHAT IS ESTABLISHED HERE, all of it directly observed rather than inferred:
#
#   1. the working tree has no uncommitted changes, so the checkout matches
#      what you are looking at. A worktree holds committed work only.
#   2. the checkout is bootstrapped by a command you named
#   3. --test exits 0 in it. A red baseline cannot judge a mutant, and an
#      incomplete bootstrap shows up here rather than as a hundred false kills
#
# This script writes nothing inside the worktree itself. --setup, --test and
# your command do; it does not.
#
# EXECUTION SURFACE. --setup, --test and the trailing command run inside the
# worktree. --setup and --test go through `bash -c` verbatim; your command is
# executed as argv with no shell re-parse. Never assemble any of them from
# repository content without showing the user what will run: a permission rule
# approving this script approves the wrapper, not the payload.
#
# NOT ISOLATED FROM: the repository's `.git`. A worktree shares it, so a
# --setup that runs `git config`, fetches, or updates submodules changes the
# real repository's metadata. Only the working FILES are throwaway.
#
# EXIT CODES. Refusals use 40-44 — outside sysexits (64-78) and outside the
# shell's 126/127/128+ — because anything else this prints is your command's
# own status, passed through unchanged. For certainty rather than heuristics,
# read the machine-readable line this prints on stderr before exiting:
#     mutation_test_worktree: refused: <slug>
#   40 usage   41 missing dependency   42 worktree or setup failed
#   43 baseline red                    44 repository state refuses the run
#   130 interrupted
set -uo pipefail

WT=''
REPO=''
KEEP=no
HANDED_OVER=no
USER_PID=''
UNTRACKED_OK=''

usage() {
  cat <<'USAGE'
Usage:
  mutation_test_worktree.sh run --test <cmd> [options] -- <command>...

Creates a throwaway worktree, bootstraps it, checks the baseline is green, runs
your command inside it, and removes it. The worktree path never leaves this
script; your command sees it as the working directory and in
$MUTATION_TEST_WORKTREE.

Required:
  --test  <cmd>    command that judges a mutant; must exit 0 on clean source

Optional:
  --setup <cmd>    bootstrap to run in the worktree first, e.g.
                   'uv sync --frozen && git submodule update --init'
  --repo  <path>   repository to branch from (default: current directory)
  --ref   <ref>    commit-ish to check out (default: HEAD). Given explicitly,
                   the working-tree check is skipped: you said which commit.
  --keep           on refusal or failure, keep the worktree and print how to
                   remove it. A successful run always tears it down.
  --untracked-ok <path>
                   acknowledge one untracked path as irrelevant to this run
                   (repeatable). It is NOT a bypass: any untracked path you do
                   not name still refuses, so a test you forgot about still
                   stops the run. Naming a path is a deliberate act; a blanket
                   flag would be reached for reflexively, including in the one
                   case that matters.

This does NOT check that --test can see a mutation. Nothing exit-code-shaped
can. Judge that from your results: if every mutant survives, suspect the
environment before believing the coverage.
USAGE
}

say()     { printf '%s\n' "$*" >&2; }
refuse()  { # slug, code, message...
  local slug=$1 code=$2; shift 2
  say "mutation_test_worktree: refused: $slug"
  say "Error: $*"
  exit "$code"
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || \
      refuse missing-dependency 41 "missing required command: $c (install it; do not work around this)"
  done
}

abspath_dir() { ( cd "$1" 2>/dev/null && pwd -P ) || return 1; }

validate_ref() {
  case $1 in
    '')    refuse empty-ref 40 "ref may not be empty" ;;
    -*)    refuse dash-ref 40 "ref may not begin with '-': $1" ;;
    *..*)  refuse dotdot-ref 40 "ref may not contain '..': $1" ;;
  esac
}

# Deregistration goes through git, which refuses a main working tree. No
# `git worktree prune` here: prune is repo-wide and would deregister a user's
# unrelated worktree whose directory is merely unavailable.
remove_worktree() {
  [ -n "$WT" ] || return 0
  [ -d "$WT" ] || return 0
  [ -n "$REPO" ] && git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
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
  [ -n "$USER_PID" ] && kill "$USER_PID" 2>/dev/null
  [ "$HANDED_OVER" = yes ] && return 0
  if [ "$KEEP" = yes ] && [ -n "$WT" ] && [ -d "$WT" ]; then
    keep_notice
  else
    remove_worktree
  fi
  return 0
}

on_signal() { cleanup; trap - EXIT; exit 130; }

# stdin closed so a command that prompts fails instead of hanging. There is no
# timeout: `timeout` is GNU coreutils and absent on stock macOS.
run_in_wt() { ( cd "$WT" && bash -c "$1" ) </dev/null; }

# 126/127 and anything above 128 mean the command never reached a verdict.
# Reporting that as a red baseline sends the reader to fix a virtualenv that is
# fine, so it is named separately wherever a command is run.
check_ran() { # rc, what
  case $1 in
    126|127) refuse command-not-runnable 42 "$2 exited $1: it is not executable or was not found." ;;
  esac
  [ "$1" -gt 128 ] && refuse command-killed 42 "$2 was killed by a signal (exit $1)."
  return 0
}

cmd_run() {
  local test_cmd='' setup_cmd='' repo='' ref='HEAD' ref_given=no rc err
  local dirty untracked tracked hidden skip_tree_check unacked

  while [ $# -gt 0 ]; do
    case $1 in
      --test)  [ $# -ge 2 ] || refuse test-needs-value 40 "--test needs a value";  test_cmd=$2;  shift 2 ;;
      --setup) [ $# -ge 2 ] || refuse setup-needs-value 40 "--setup needs a value"; setup_cmd=$2; shift 2 ;;
      --repo)  [ $# -ge 2 ] || refuse repo-needs-value 40 "--repo needs a value";  repo=$2;      shift 2 ;;
      --ref)   [ $# -ge 2 ] || refuse ref-needs-value 40 "--ref needs a value";   ref=$2; ref_given=yes; shift 2 ;;
      --keep)  KEEP=yes; shift ;;
      --untracked-ok)
        [ $# -ge 2 ] || refuse untracked-ok-needs-value 40 "--untracked-ok needs a value"
        UNTRACKED_OK="$UNTRACKED_OK$2
"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      --probe|--exec-probe)
        refuse removed-flag 40 "$1 was removed. This script no longer probes whether --test
       can see a mutation: nothing exit-code-shaped can establish that, and three
       designs that tried were each defeated by a step that reads the file
       without running it. Mark one mutant 'control' in the runner's spec
       instead, on a line you are confident is covered: if it dies, the wiring
       is proven by the run itself rather than guessed at beforehand." ;;
      *) refuse unknown-argument 40 "unknown argument: $1" ;;
    esac
  done

  [ $# -ge 1 ]       || { usage; refuse no-command 40 "a command to run must follow --"; }
  [ -n "$test_cmd" ] || { usage; refuse no-test 40 "--test is required"; }
  validate_ref "$ref"
  require_cmd git mktemp sed

  [ -n "$repo" ] || repo=$PWD
  [ -d "$repo" ] || refuse no-such-repo 40 "no such directory: $repo"
  repo=$(abspath_dir "$repo") || refuse unresolvable-repo 40 "cannot resolve: $repo"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || refuse not-a-repo 40 "not a git repository: $repo"

  # Normalise to the toplevel so messages name the repository rather than
  # whichever subdirectory the caller happened to be in. This is NOT what makes
  # the dirty check below correct: `git status --porcelain` is repo-wide from
  # any directory (verified). An earlier version used a PATHSPEC, which IS
  # scoped to -C, and that version reported a clean tree from a subdirectory.
  REPO=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) \
    || refuse no-toplevel 40 "cannot find the repository root of $repo"
  REPO=$(abspath_dir "$REPO") || refuse unresolvable-toplevel 40 "cannot resolve the repository root"

  git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 ||
    refuse bad-ref 40 "ref does not resolve to a commit in $REPO: $ref"

  # The WHOLE tree, not one file. An earlier version checked only the file
  # about to be mutated, so a dirty TEST file — the normal state when this
  # skill is used — was silently judged at its committed version. `git status`
  # takes no pathspec here, so there is no spelling that can fail it open.
  # An explicit --ref means the caller named a commit. But --ref HEAD names the
  # very commit this check compares against, so it must NOT buy a bypass — the
  # dirty-tree refusal used to say "pass --ref", steering callers straight into
  # the situation the guard exists to prevent.
  skip_tree_check=no
  if [ "$ref_given" = yes ]; then
    if [ "$(git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}")" \
       = "$(git -C "$REPO" rev-parse --verify --quiet 'HEAD^{commit}')" ]; then
      say "note: --ref $ref is HEAD, so the working tree is still checked"
    else
      skip_tree_check=yes
      say "note: --ref $ref is not HEAD; the working tree is not consulted"
    fi
  fi

  if [ "$skip_tree_check" = no ]; then
    # Default untracked reporting, NOT --untracked-files=no. A test that was
    # just written is usually untracked, and it is this skill's primary target;
    # with -uno the guard passed, the worktree did not contain the test, the
    # baseline was green, and every mutant survived. Ignored files still need
    # --ignored to appear, so build output does not make this noisy.
    dirty=$(git -C "$REPO" status --porcelain 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] && refuse git-failed 42 "git status failed in $REPO (exit $rc):
       $dirty"

    untracked=$(printf '%s\n' "$dirty" | sed -n 's/^?? //p')
    tracked=$(printf '%s\n' "$dirty" | sed -n '/^?? /!p' | sed -n '/./p')

    if [ -n "$tracked" ]; then
      say "uncommitted changes in $REPO:"
      printf '%s\n' "$tracked" | sed 's/^/       /' >&2
      refuse dirty-tree 44 "the working tree has uncommitted changes, and a worktree can hold
       committed work only. This run would judge the COMMITTED version of the
       files listed above while you are looking at your edits. Commit them, or
       pass --ref with a commit that is not HEAD to say you meant an older one."
    fi
    # Remove the paths the caller explicitly acknowledged. Anything left is a
    # path nobody accounted for, which is the case worth stopping for.
    unacked=$untracked
    if [ -n "$UNTRACKED_OK" ] && [ -n "$untracked" ]; then
      unacked=$(printf '%s\n' "$untracked" | while IFS= read -r u; do
        [ -n "$u" ] || continue
        hit=no
        printf '%s\n' "$UNTRACKED_OK" | while IFS= read -r ok; do
          [ -n "$ok" ] || continue
          [ "$ok" = "$u" ] && exit 7
        done || hit=yes
        [ "$hit" = yes ] || printf '%s\n' "$u"
      done)
      # A named path that is not untracked is a stale acknowledgement — it may
      # have been committed since. Say so; do not refuse, since it blocks
      # nothing.
      printf '%s\n' "$UNTRACKED_OK" | while IFS= read -r ok; do
        [ -n "$ok" ] || continue
        printf '%s\n' "$untracked" | grep -qxF "$ok" || \
          say "note: --untracked-ok $ok is not untracked; the acknowledgement did nothing"
      done
    fi
    if [ -n "$unacked" ]; then
      say "untracked files in $REPO:"
      printf '%s\n' "$unacked" | sed 's/^/       /' >&2
      refuse untracked-files 44 "these files are untracked, so the worktree will NOT contain them.
       A test you have just written and not yet added is the usual case, and it
       is exactly the one that matters: without it the baseline is green and
       every mutant survives, which reads as missing coverage. Add them, pass
       --untracked-ok <path> for each one you have established is irrelevant to
       this run, or pass --ref with a commit that is not HEAD."
    fi

    # A file marked assume-unchanged or skip-worktree is invisible to status,
    # so the checks above cannot see it. Lower-case tags mean one of those.
    hidden=$(git -C "$REPO" ls-files -v 2>/dev/null | sed -n 's/^[a-z] //p')
    if [ -n "$hidden" ]; then
      say "files hidden from git status in $REPO (assume-unchanged or skip-worktree):"
      printf '%s\n' "$hidden" | sed 's/^/       /' >&2
      refuse hidden-index-bits 44 "these files carry an index bit that hides them from git status, so
       nothing above could tell whether they differ from $ref. Clear it with
       'git update-index --no-assume-unchanged' / '--no-skip-worktree'."
    fi
  fi

  # Traps first: cleanup is a no-op while WT is empty, and installing them
  # after mktemp left a window in which a signal both created the directory and
  # took the default disposition, leaking it with no handler.
  trap on_signal INT TERM HUP QUIT
  trap cleanup EXIT
  WT=$(mktemp -d "${TMPDIR:-/tmp}/mutation-test-wt.XXXXXX") || refuse tmpdir 42 "cannot create a temporary directory"

  err=$(git -C "$REPO" worktree add --detach "$WT" "$ref" 2>&1) || \
    refuse worktree-add 42 "git worktree add failed for $ref in $REPO:
       $err"

  if [ -n "$setup_cmd" ]; then
    say "setup: $setup_cmd"
    rc=0; run_in_wt "$setup_cmd" >&2 || rc=$?
    check_ran "$rc" "the --setup command"
    [ "$rc" -ne 0 ] && refuse setup-failed 42 "the --setup command exited $rc; the checkout cannot run tests"
  fi

  say "baseline: $test_cmd"
  rc=0; run_in_wt "$test_cmd" >&2 || rc=$?
  check_ran "$rc" "the --test command"
  [ "$rc" -ne 0 ] && refuse baseline-red 43 "the baseline is RED at $ref (exit $rc). A red baseline cannot judge
       a mutant. Usually the bootstrap is incomplete - a missing virtualenv, an
       uninitialised submodule, an absent build step. Pass it with --setup."

  say "ok: baseline green at $ref. Whether --test can SEE a mutation is not"
  say "    established here. Mark one mutant 'control' in the runner's spec, on a"
  say "    line you are confident is covered, and its verdict settles it."

  # The caller owns the worktree from here. Its exit status passes through,
  # which is why every refusal above used 40-44.
  # Backgrounded and waited on, NOT run in the foreground: bash defers trap
  # handling until a foreground command returns, so a SIGTERM during a long
  # caller command did nothing until it finished, and a supervisor escalating
  # to SIGKILL left the worktree and its registration behind with no message.
  local user_rc=0
  ( cd "$WT" && MUTATION_TEST_WORKTREE="$WT" bash -c '"$@"' _ "$@" ) &
  USER_PID=$!
  wait "$USER_PID"; user_rc=$?
  USER_PID=''

  HANDED_OVER=yes
  if [ "$KEEP" = yes ] && [ "$user_rc" -ne 0 ]; then
    keep_notice
  else
    remove_worktree
  fi
  trap - INT TERM HUP QUIT
  trap - EXIT
  return "$user_rc"
}

case ${1:-} in
  run)       shift; cmd_run "$@" ;;
  -h|--help) usage; exit 0 ;;
  '')        usage; refuse no-subcommand 40 "a subcommand is required" ;;
  create|destroy)
    refuse removed-subcommand 40 "'$1' was removed. This script no longer takes a path to
       delete; twice that deleted a repository and reported success. Use 'run'." ;;
  *) usage; refuse unknown-subcommand 40 "unknown subcommand: $1" ;;
esac
