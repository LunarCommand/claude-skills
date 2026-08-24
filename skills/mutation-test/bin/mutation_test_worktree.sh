#!/usr/bin/env bash
# mutation_test_worktree.sh — a throwaway checkout to mutate in, so the real
# tree is never touched.
#
# The predecessor to this script backed up each source file, mutated it in
# place, and restored it afterwards. An adversarial review found seven blockers
# in that path, including a backup key (`tr '/' '_'`) that was not injective and
# so restored one file's contents over another while reporting success.
#
# Moving to a worktree removes that surface. It does NOT remove every surface,
# and the first version of this script proved it: `destroy` would rm -rf any
# path it was handed, so `destroy <repo>` deleted a repository — .git and
# uncommitted work included — and printed "removed" with exit 0. The same
# signature, in the replacement. Two rules follow from that, and both are load
# bearing:
#
#   * this script deletes ONLY a worktree it created, verified three ways, and
#     says so loudly when it cannot;
#   * every write it makes is proven to land inside the worktree before it
#     happens — a tracked symlink pointing outside the checkout is a write
#     through that link, and `-f` follows symlinks.
#
#   create   build the worktree, bootstrap it, and PROVE it is usable
#   destroy  remove a worktree this script created
#
# `create` refuses to hand back a worktree unless all of these hold:
#
#   1. the working tree agrees with the reviewed ref for the probe file. A
#      worktree holds COMMITTED work, so uncommitted edits are invisible in it;
#      scoring them would report on code the caller is not looking at.
#   2. the baseline is green — a red baseline cannot judge a mutant, and a
#      half-bootstrapped worktree (missing venv, uninitialised submodule) shows
#      up here rather than as a hundred false kills.
#   3. the test command goes green -> RED -> green across corrupting and
#      restoring the probe file. A one-way "it went red" is not evidence: a
#      lint or compile step in a compound command (`ruff check . && pytest`)
#      catches the corruption while the step that actually judges mutants still
#      resolves elsewhere, which is precisely the editable-install trap this
#      gate exists to catch. Requiring green again afterwards also rejects a
#      non-idempotent or flaky command, which cannot judge a mutant either.
#
# WHAT GATE 3 DOES NOT PROVE. It establishes wiring for the PROBE FILE ONLY.
# A caller mutating several files must probe each one; a probe on a test-side
# file passes while every src/ mutant still runs against unmutated source.
#
# EXECUTION SURFACE. --setup and --test are run with `bash -c` inside the
# worktree. They are executed verbatim. Never pass a command assembled from
# repository content (a README, a Makefile, a CI config) without showing the
# user what will run: a permission rule approving this script approves the
# wrapper, not the payload.
#
# Exit codes:
#   0   ok
#   2   usage — a malformed or missing argument
#   3   baseline is red
#   4   the mutation is not visible to the test command
#   5   the worktree, the setup command, or the test command failed to RUN
#   6   the repository state refuses the run (probe absent at ref, or the
#       working tree disagrees with the ref about the probe file)
#   127 a required command is missing
#   130 interrupted
set -uo pipefail

PROBE_MARK='!!!mutation_test_wiring_probe!!!'

# Set by cmd_create; read by the traps, which must not interpolate them.
WT=''
REPO=''
SAVED=''
PROBE_REL=''
KEEP=no
SUCCEEDED=no

usage() {
  cat <<'USAGE'
Usage:
  mutation_test_worktree.sh create --test <cmd> --probe <file> [options]
  mutation_test_worktree.sh destroy <worktree-path>

create options:
  --test  <cmd>    command that judges a mutant; must exit 0 on clean source (required)
  --probe <file>   repo-relative file the mutation will target; used to prove
                   the test command actually sees edits to it (required)
  --setup <cmd>    bootstrap to run inside the worktree first, e.g.
                   'uv sync --frozen && git submodule update --init'
  --repo  <path>   repository to branch from (default: current directory)
  --ref   <ref>    commit-ish to check out (default: HEAD)
  --keep           leave the worktree behind when a gate fails, for debugging

destroy refuses any path this script did not create.
On success the worktree path is printed on stdout and nothing else is.
USAGE
}

say() { printf '%s\n' "$*" >&2; }
die() { local code=$1; shift; say "Error: $*"; exit "$code"; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die 127 "missing required command: $c (install it; do not work around this)"
  done
}

# Absolute, symlink-resolved path of an existing directory. `readlink -f` is
# GNU-only and this must run under BSD userland too.
abspath_dir() { ( cd "$1" 2>/dev/null && pwd -P ) || return 1; }

validate_ref() {
  case $1 in
    '')    die 2 "ref may not be empty" ;;
    -*)    die 2 "ref may not begin with '-': $1" ;;
    *..*)  die 2 "ref may not contain '..': $1" ;;
  esac
}

# --probe is joined to the worktree path and then written to. A leading slash
# or a `..` component escapes the worktree by string alone, before any symlink
# is involved.
validate_probe_arg() {
  case $1 in
    '')      die 2 "probe path may not be empty" ;;
    /*)      die 2 "probe must be repo-relative, not absolute: $1" ;;
    ../*|*/../*|*/..) die 2 "probe may not contain a '..' component: $1" ;;
    ..)      die 2 "probe may not contain a '..' component: $1" ;;
  esac
}

# Restore the probe from $SAVED if it is currently corrupted. Called from the
# success path AND from the signal trap, because an interrupt during gate 3
# otherwise leaves the file corrupted with its only pristine copy orphaned.
restore_probe() {
  [ -n "$SAVED" ] || return 0
  [ -f "$SAVED" ] || return 0
  if [ -n "$WT" ] && [ -n "$PROBE_REL" ] && [ -f "$WT/$PROBE_REL" ]; then
    cat "$SAVED" > "$WT/$PROBE_REL" 2>/dev/null || true
  fi
  rm -f "$SAVED"
  SAVED=''
}

remove_worktree() {
  [ -n "$WT" ] || return 0
  [ -d "$WT" ] || return 0
  if [ -n "$REPO" ]; then
    git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
  fi
  [ -d "$WT" ] && rm -rf "$WT"
  [ -n "$REPO" ] && git -C "$REPO" worktree prune >/dev/null 2>&1
  return 0
}

on_signal() {
  restore_probe
  if [ "$KEEP" = yes ]; then
    say ""
    say "interrupted — worktree kept at: $WT"
  else
    remove_worktree
  fi
  trap - EXIT
  exit 130
}

# Without this, any termination that is not INT/TERM leaks the directory AND a
# registration inside the user's .git/worktrees that `destroy` cannot prune.
on_exit() {
  [ "$SUCCEEDED" = yes ] && return 0
  restore_probe
  [ "$KEEP" = yes ] || remove_worktree
  return 0
}

# ---------------------------------------------------------------- destroy ----
# Three independent checks, because the failure this guards against destroyed a
# repository and reported success. Any one of them passing is not enough.
cmd_destroy() {
  local wt=${1:-} resolved base parent tmpdir gitdir toplevel err
  [ -n "$wt" ] || { usage; exit 2; }
  case $wt in -*) die 2 "path may not begin with '-': $wt" ;; esac
  require_cmd git

  if [ ! -d "$wt" ]; then
    say "note: $wt does not exist; nothing to remove"
    return 0
  fi

  resolved=$(abspath_dir "$wt") || die 5 "cannot resolve: $wt"

  # 1. It must carry the name this script gives its worktrees, in the directory
  #    this script puts them in.
  base=$(basename "$resolved")
  parent=$(dirname "$resolved")
  tmpdir=$(abspath_dir "${TMPDIR:-/tmp}") || tmpdir="/tmp"
  case $base in
    mutation-test-wt.*) : ;;
    *) die 2 "refusing: $resolved was not created by this script (name does not match mutation-test-wt.*)" ;;
  esac
  [ "$parent" = "$tmpdir" ] || \
    die 2 "refusing: $resolved is not directly under ${TMPDIR:-/tmp}"

  # 2. It must be a LINKED worktree, never a main one. A main worktree's git dir
  #    is the repository itself; a linked worktree's lives under .../worktrees/.
  #    This is the check whose absence deleted a repository: `rev-parse
  #    --git-dir` succeeds for BOTH, so it can never tell them apart.
  gitdir=$(git -C "$resolved" rev-parse --absolute-git-dir 2>/dev/null) || \
    die 2 "refusing: $resolved is not inside a git worktree"
  case $gitdir in
    */worktrees/*) : ;;
    *) die 2 "refusing: $resolved is a MAIN working tree, not a throwaway worktree.
       Deleting it would destroy the repository and any uncommitted work in it." ;;
  esac

  # 3. Its own toplevel must be this path — not a subdirectory of a worktree.
  toplevel=$(git -C "$resolved" rev-parse --show-toplevel 2>/dev/null) || \
    die 2 "refusing: cannot determine the worktree root of $resolved"
  toplevel=$(abspath_dir "$toplevel") || die 5 "cannot resolve worktree root"
  [ "$toplevel" = "$resolved" ] || \
    die 2 "refusing: $resolved is inside a worktree but is not its root ($toplevel)"

  # Deregister through git, and REPORT a failure instead of falling through to
  # rm -rf. The discarded failure here is what turned a refusal into a deletion.
  err=$(git -C "$resolved" worktree remove --force "$resolved" 2>&1)
  if [ -d "$resolved" ]; then
    say "git worktree remove did not remove it: $err"
    rm -rf "$resolved" || die 5 "could not remove $resolved"
  fi
  if [ -d "$resolved" ]; then
    die 5 "failed to remove $resolved"
  fi
  say "removed $resolved"
  return 0
}

# ----------------------------------------------------------------- create ----
run_in_wt() { # command -> exit code; stdin closed so a prompt cannot hang us
  ( cd "$WT" && bash -c "$1" ) </dev/null
}

cmd_create() {
  local test_cmd='' probe='' setup_cmd='' repo='' ref='HEAD'
  local probe_dir probe_dir_abs wt_abs rc out err

  while [ $# -gt 0 ]; do
    case $1 in
      --test)  [ $# -ge 2 ] || die 2 "--test needs a value";  test_cmd=$2;  shift 2 ;;
      --probe) [ $# -ge 2 ] || die 2 "--probe needs a value"; probe=$2;     shift 2 ;;
      --setup) [ $# -ge 2 ] || die 2 "--setup needs a value"; setup_cmd=$2; shift 2 ;;
      --repo)  [ $# -ge 2 ] || die 2 "--repo needs a value";  repo=$2;      shift 2 ;;
      --ref)   [ $# -ge 2 ] || die 2 "--ref needs a value";   ref=$2;       shift 2 ;;
      --keep)  KEEP=yes; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die 2 "unknown argument: $1" ;;
    esac
  done

  [ -n "$test_cmd" ] || { say "Error: --test is required"; usage; exit 2; }
  [ -n "$probe" ]    || { say "Error: --probe is required"; usage; exit 2; }
  validate_ref "$ref"
  validate_probe_arg "$probe"

  require_cmd git cmp mktemp basename dirname

  [ -n "$repo" ] || repo=$PWD
  [ -d "$repo" ] || die 2 "no such directory: $repo"
  REPO=$(abspath_dir "$repo") || die 2 "cannot resolve: $repo"
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die 2 "not a git repository: $REPO"
  git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 ||
    die 2 "ref does not resolve to a commit in $REPO: $ref"

  # Gate 0 — the worktree holds COMMITTED work. If the probe file on disk
  # differs from the ref, the gates below would pass against a version of the
  # code the caller is not looking at, and every result would be misattributed.
  if ! git -C "$REPO" diff --quiet "$ref" -- "$probe" 2>/dev/null; then
    die 6 "the working tree and $ref disagree about $probe.
       A worktree can only hold committed work, so this run would judge the
       COMMITTED version while you are looking at your edits. Commit first, or
       pass --ref explicitly to say that is what you meant."
  fi
  if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
    say "note: $REPO has uncommitted changes elsewhere; $ref is what will be reviewed"
  fi

  PROBE_REL=$probe

  # mktemp -d creates the directory atomically and git accepts an existing
  # empty one (verified), so it is never surrendered — the previous rmdir
  # opened a window in world-writable /tmp for nothing.
  WT=$(mktemp -d "${TMPDIR:-/tmp}/mutation-test-wt.XXXXXX") || die 5 "cannot create a temporary directory"

  trap on_signal INT TERM HUP QUIT
  trap on_exit EXIT

  err=$(git -C "$REPO" worktree add --detach "$WT" "$ref" 2>&1) || \
    die 5 "git worktree add failed for $ref in $REPO:
       $err"

  [ -e "$WT/$probe" ] || die 6 "--probe file not present at $ref: $probe"

  # Containment. `-f` follows symlinks, so a repo tracking `link.py -> /etc/x`
  # would have had the probe written straight through it, outside the worktree.
  [ -L "$WT/$probe" ] && \
    die 2 "refusing: $probe is a symlink. Writing the probe would follow it out
       of the worktree. Name the file it points at instead."
  [ -f "$WT/$probe" ] || die 2 "not a regular file: $probe"
  probe_dir=$(dirname "$WT/$probe")
  probe_dir_abs=$(abspath_dir "$probe_dir") || die 5 "cannot resolve $probe_dir"
  wt_abs=$(abspath_dir "$WT") || die 5 "cannot resolve $WT"
  case "$probe_dir_abs/" in
    "$wt_abs"/*) : ;;
    *) die 2 "refusing: $probe resolves outside the worktree ($probe_dir_abs)" ;;
  esac

  if [ -n "$setup_cmd" ]; then
    say "setup: $setup_cmd"
    if ! run_in_wt "$setup_cmd" >&2; then
      die 5 "setup command failed in the worktree; the checkout cannot run tests"
    fi
  fi

  # Gate 1 — baseline green.
  say "baseline: $test_cmd"
  if ! run_in_wt "$test_cmd" >&2; then
    die 3 "baseline is RED at $ref. A red baseline cannot judge a mutant.
       Usually the bootstrap is incomplete - a missing virtualenv, an
       uninitialised submodule, an absent build step. Pass it with --setup."
  fi

  # --- Gates 2-4: prove the mutation reaches the JUDGING step ----------------
  #
  # Two probes, because one is not enough. A syntax break is caught by ANY step
  # that merely parses the file, so with `--test 'ruff check . && pytest'` the
  # linter objects, the command goes red, and the pytest step never runs -- yet
  # it is pytest that judges mutants, and it may still be resolving imports to
  # the original tree. That is the editable-install trap passing the gate built
  # to catch it (measured: it did).
  #
  # The second probe empties the file instead. An empty module parses fine in
  # Python, JavaScript and Ruby, so a lint step stays GREEN and only a step that
  # actually EXECUTES the code can notice. If probe 1 goes red and probe 2 does
  # not, the file is being read but not run, and nothing scored here would mean
  # anything. In a compiled language the compiler catches both, which is no
  # weaker than before.
  SAVED=$(mktemp "${TMPDIR:-/tmp}/mutation-test-probe.XXXXXX") || die 5 "cannot create a temporary file"
  cat "$WT/$probe" > "$SAVED" || die 5 "cannot read $probe"
  out=$(mktemp "${TMPDIR:-/tmp}/mutation-test-out.XXXXXX") || die 5 "cannot create a temporary file"

  PROBE_RC=0
  probe_run() { # mode: marker | empty — always restores before returning
    local rc=0
    case $1 in
      marker) { printf '%s\n' "$PROBE_MARK"; cat "$SAVED"; } > "$WT/$probe" || die 5 "cannot write $probe" ;;
      empty)  : > "$WT/$probe" || die 5 "cannot write $probe" ;;
    esac
    run_in_wt "$test_cmd" >"$out" 2>&1 || rc=$?
    cat "$SAVED" > "$WT/$probe" || die 5 "cannot restore $probe in the worktree"
    cmp -s "$SAVED" "$WT/$probe" || die 5 "probe file did not restore cleanly: $probe"
    PROBE_RC=$rc
  }

  check_breakage() { # 126/127/>128 mean the command never reached a verdict
    if [ "$PROBE_RC" -eq 126 ] || [ "$PROBE_RC" -eq 127 ] || [ "$PROBE_RC" -gt 128 ]; then
      say "--- test output ---"
      sed 's/^/       /' "$out" >&2
      rm -f "$out"
      die 5 "the test command exited $PROBE_RC with $probe altered, which means it
       did not RUN (126/127 = not executable or not found, >128 = killed by a
       signal). That is breakage, not evidence that the mutation was seen."
    fi
  }

  say "wiring probe 1/2 (syntax): expecting the test command to FAIL"
  probe_run marker
  check_breakage
  if [ "$PROBE_RC" -eq 0 ]; then
    say "--- test output with $probe corrupted ---"
    sed 's/^/       /' "$out" >&2
    rm -f "$out"
    die 4 "the test command still PASSES with $probe corrupted, so it is not
       running the worktree's copy of that file. Anything scored from here
       would be a false survivor. Two usual causes:
         - the environment was reused from the host and resolves to the
           original tree (an editable install records an absolute path)
         - no test in --test actually exercises $probe
       Bootstrap inside the worktree with --setup instead of reusing the host's."
  fi

  say "wiring probe 2/2 (semantic): expecting the test command to FAIL"
  probe_run empty
  check_breakage
  if [ "$PROBE_RC" -eq 0 ]; then
    say "--- test output with $probe emptied ---"
    sed 's/^/       /' "$out" >&2
    rm -f "$out"
    die 4 "corrupting $probe turned the suite red, but EMPTYING it did not. So
       something in --test parses this file while the step that judges mutants
       never executes it -- a lint, format or type-check step failing first in a
       compound command, with the real suite still resolving to another tree.
       Point --test at the command that actually judges mutants, and bootstrap
       inside the worktree with --setup."
  fi
  rm -f "$out"

  # The third leg: green again after restore. Rejects a non-idempotent command
  # (a stamp file, a migration, a snapshot writer) or a flake, neither of which
  # can attribute a red result to the mutation.
  say "re-baseline: expecting green again after restore"
  if ! run_in_wt "$test_cmd" >&2; then
    die 4 "the test command does not return to GREEN after $probe is restored,
       so its red result was not attributable to the mutation. Usually the
       command is not idempotent (it writes a stamp file, runs a migration, or
       rewrites snapshots) or it is flaky. Neither can judge a mutant."
  fi

  rm -f "$SAVED"; SAVED=''
  SUCCEEDED=yes
  trap - INT TERM HUP QUIT
  trap - EXIT
  say "ok: baseline green, mutation visible in $probe, green again after restore"
  printf '%s\n' "$WT"
}

case ${1:-} in
  create)  shift; cmd_create "$@" ;;
  destroy) shift; cmd_destroy "$@" ;;
  -h|--help) usage; exit 0 ;;
  '') usage; exit 2 ;;
  *) say "Error: unknown subcommand: $1"; usage; exit 2 ;;
esac
