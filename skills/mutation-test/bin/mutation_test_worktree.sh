#!/usr/bin/env bash
# mutation_test_worktree.sh — a throwaway checkout to mutate in, so the real
# tree is never touched.
#
# The predecessor to this script backed up each source file, mutated it in
# place, and restored it afterwards. An adversarial review found seven blockers
# in that path, including a backup key (`tr '/' '_'`) that was not injective and
# so restored one file's contents over another while reporting success. This
# design deletes the class: a scope worth mutating is committed, a worktree can
# hold committed work, and a tree you never write to cannot be corrupted.
#
#   create   build the worktree, bootstrap it, and PROVE it is usable
#   destroy  remove it
#
# `create` refuses to hand back a worktree unless both gates pass:
#
#   1. the baseline is green — a red baseline cannot judge a mutant, and a
#      half-bootstrapped worktree (missing venv, uninitialised submodule) shows
#      up here rather than as a hundred false kills.
#   2. the test command SEES changes to the file about to be mutated. This is
#      not paranoia. A Python editable install records an absolute path, so a
#      venv reused from the host resolves imports to the ORIGINAL tree: the
#      mutant runs against unmutated source, every test passes, and the run
#      reports "no covering tests" with exit 0. Cheap isolation is worthless if
#      the isolated copy is not what runs, and that failure is invisible.
#
# Exit codes are distinct so a caller can tell refusal from breakage:
#   0 ok   2 usage   3 baseline red   4 mutation not visible
#   5 worktree or setup failed        127 missing dependency
set -uo pipefail

PROBE_MARK='!!!mutation_test_wiring_probe!!!'

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

On success the worktree path is printed on stdout and nothing else is.
USAGE
}

say()  { printf '%s\n' "$*" >&2; }
die()  { local code=$1; shift; say "Error: $*"; exit "$code"; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die 127 "missing required command: $c (install it; do not work around this)"
  done
}

# A ref is interpolated into git commands. git check-ref-format accepts names
# beginning with a dash, which would be read as an option -- `--output` in a
# `git diff` reached a file write that way. Refuse loudly rather than sanitise:
# a silently rewritten ref sends every later step at the wrong commit.
validate_ref() {
  case $1 in
    '')    die 2 "ref may not be empty" ;;
    -*)    die 2 "ref may not begin with '-': $1" ;;
    *..*)  die 2 "ref may not contain '..': $1" ;;
  esac
}

cmd_destroy() {
  local wt=${1:-}
  [ -n "$wt" ] || { usage; exit 2; }
  require_cmd git
  if [ ! -d "$wt" ]; then
    say "note: $wt does not exist"
    return 0
  fi
  # --force because setup almost certainly left untracked build output behind.
  if git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$wt" worktree remove --force "$wt" >/dev/null 2>&1 || true
  fi
  [ -d "$wt" ] && rm -rf "$wt"
  say "removed $wt"
  return 0
}

cmd_create() {
  local test_cmd='' probe='' setup_cmd='' repo='' ref='HEAD' keep=no
  while [ $# -gt 0 ]; do
    case $1 in
      --test)  [ $# -ge 2 ] || die 2 "--test needs a value";  test_cmd=$2;  shift 2 ;;
      --probe) [ $# -ge 2 ] || die 2 "--probe needs a value"; probe=$2;     shift 2 ;;
      --setup) [ $# -ge 2 ] || die 2 "--setup needs a value"; setup_cmd=$2; shift 2 ;;
      --repo)  [ $# -ge 2 ] || die 2 "--repo needs a value";  repo=$2;      shift 2 ;;
      --ref)   [ $# -ge 2 ] || die 2 "--ref needs a value";   ref=$2;       shift 2 ;;
      --keep)  keep=yes; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die 2 "unknown argument: $1" ;;
    esac
  done

  [ -n "$test_cmd" ] || { say "Error: --test is required"; usage; exit 2; }
  [ -n "$probe" ]    || { say "Error: --probe is required"; usage; exit 2; }
  validate_ref "$ref"

  require_cmd git cmp mktemp

  [ -n "$repo" ] || repo=$PWD
  [ -d "$repo" ] || die 2 "no such directory: $repo"
  repo=$(cd "$repo" && pwd) || die 2 "cannot resolve: $repo"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die 2 "not a git repository: $repo"
  git -C "$repo" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 ||
    die 2 "ref does not resolve to a commit in $repo: $ref"

  local wt
  wt=$(mktemp -d "${TMPDIR:-/tmp}/mutation-test-wt.XXXXXX") || die 5 "cannot create a temporary directory"
  # mktemp made the directory; git worktree add insists on creating it itself.
  rmdir "$wt" || die 5 "cannot prepare $wt"

  # Two runs never share a worktree: each gets its own mktemp path. That is why
  # this design needs no lock, where the in-place predecessor did and lacked one.
  git -C "$repo" worktree add --detach "$wt" "$ref" >/dev/null 2>&1 ||
    die 5 "git worktree add failed for $ref in $repo"

  # shellcheck disable=SC2064  # expand now: these are what must be cleaned up
  trap "git -C '$repo' worktree remove --force '$wt' >/dev/null 2>&1; rm -rf '$wt'; exit 130" INT TERM

  abort() { # code, message
    local code=$1; shift
    if [ "$keep" = yes ]; then
      say "Error: $*"
      say "worktree kept at: $wt"
    else
      git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
      [ -d "$wt" ] && rm -rf "$wt"
      say "Error: $*"
    fi
    exit "$code"
  }

  [ -f "$wt/$probe" ] || abort 2 "--probe file not present at $ref: $probe"

  if [ -n "$setup_cmd" ]; then
    say "setup: $setup_cmd"
    if ! ( cd "$wt" && bash -c "$setup_cmd" ) >&2; then
      abort 5 "setup command failed in the worktree; the checkout cannot run tests"
    fi
  fi

  # Gate 1 — the baseline must be green.
  say "baseline: $test_cmd"
  if ! ( cd "$wt" && bash -c "$test_cmd" ) >&2; then
    abort 3 "baseline is RED at $ref. A red baseline cannot judge a mutant.
       Usually the bootstrap is incomplete - a missing virtualenv, an
       uninitialised submodule, an absent build step. Pass it with --setup."
  fi

  # Gate 2 — a change to the probe file must reach the test command.
  local saved
  saved=$(mktemp "${TMPDIR:-/tmp}/mutation-test-probe.XXXXXX") || abort 5 "cannot create a temporary file"
  cat "$wt/$probe" > "$saved" || abort 5 "cannot read $probe"
  { printf '%s\n' "$PROBE_MARK"; cat "$saved"; } > "$wt/$probe" || abort 5 "cannot write $probe"

  say "wiring probe: expecting the test command to FAIL"
  local probe_rc=0
  ( cd "$wt" && bash -c "$test_cmd" ) >/dev/null 2>&1 || probe_rc=$?

  cat "$saved" > "$wt/$probe" || abort 5 "cannot restore $probe in the worktree"
  cmp -s "$saved" "$wt/$probe" || abort 5 "probe file did not restore cleanly: $probe"
  rm -f "$saved"

  if [ "$probe_rc" -eq 0 ]; then
    abort 4 "the test command still PASSES with $probe corrupted, so it is not
       running the worktree's copy of that file. Anything scored from here
       would be a false survivor. Two usual causes:
         - the environment was reused from the host and resolves to the
           original tree (an editable install records an absolute path)
         - no test in --test actually exercises $probe
       Bootstrap inside the worktree with --setup instead of reusing the host's."
  fi

  trap - INT TERM
  say "ok: baseline green, mutations visible"
  printf '%s\n' "$wt"
}

case ${1:-} in
  create)  shift; cmd_create "$@" ;;
  destroy) shift; cmd_destroy "$@" ;;
  -h|--help) usage; exit 0 ;;
  '') usage; exit 2 ;;
  *) say "Error: unknown subcommand: $1"; usage; exit 2 ;;
esac
