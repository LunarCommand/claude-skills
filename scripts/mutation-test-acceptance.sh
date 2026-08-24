#!/usr/bin/env bash
# mutation-test-acceptance.sh — behavioural tests for mutation_test_worktree.sh.
#
# The rest of scripts/validate.sh is syntactic: it checks that artifacts are
# spelled correctly, not that they do what they claim. That gap is why a
# non-injective backup key shipped once and passed every check. This file is
# the other kind — it builds a fixture repository designed to break a mutation
# runner, then asserts on observed behaviour.
#
# The fixture models the failure that actually matters, and that a naive
# synthetic tree would miss: a test command carrying an ABSOLUTE path to the
# original source, the way a Python editable install does. Point a runner at a
# worktree while the environment resolves to the original tree and every mutant
# survives, silently, with exit 0.
#
# The hostile filenames (a/b.py beside a_b.py, a path with a space, a symlink)
# are here because the withheld predecessor lost data on the first of them. The
# worktree design makes them irrelevant by construction -- which is precisely
# why they are asserted rather than assumed.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
WT_SH="$REPO_ROOT/skills/mutation-test/bin/mutation_test_worktree.sh"

pass_n=0; fail_n=0
pass() { pass_n=$((pass_n + 1)); printf '  ok    %s\n' "$*"; }
fail() { fail_n=$((fail_n + 1)); printf '  FAIL  %s\n' "$*"; }

# --- fixture -----------------------------------------------------------------
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/mt-acceptance.XXXXXX") || exit 1
cleanup() {
  # Deregister anything a failed assertion left behind before deleting.
  if [ -d "$FIXTURE/repo" ]; then
    git -C "$FIXTURE/repo" worktree prune >/dev/null 2>&1 || true
  fi
  rm -rf "$FIXTURE"
}
trap cleanup EXIT

REPO="$FIXTURE/repo"
mkdir -p "$REPO/src/pkg" "$REPO/tests" "$REPO/a"

cat > "$REPO/src/pkg/__init__.py" <<'PY'
def f():
    return 1
PY

cat > "$REPO/tests/check.py" <<'PY'
import sys
import pkg
sys.exit(0 if pkg.f() == 1 else 1)
PY

# Correct wiring: PYTHONPATH is resolved at run time, so it follows the worktree.
cat > "$REPO/run_correct.sh" <<'SH'
#!/bin/sh
PYTHONPATH="$(pwd)/src" python3 tests/check.py
SH

# A test command that never imports the probe file. Nothing is wrong with the
# environment; the file simply is not covered. Scoring it would invent results.
cat > "$REPO/run_nocover.sh" <<'SH'
#!/bin/sh
exit 0
SH

# Fails until a bootstrap step has run, standing in for a missing virtualenv or
# an uninitialised submodule.
cat > "$REPO/run_needs_setup.sh" <<'SH'
#!/bin/sh
[ -f .bootstrapped ] || exit 1
PYTHONPATH="$(pwd)/src" python3 tests/check.py
SH

# The hostile tree. a/b.py and a_b.py collide under `tr '/' '_'`, which is how
# the predecessor restored one file's contents over the other.
printf 'x = "a/b.py"\n'      > "$REPO/a/b.py"
printf 'x = "a_b.py"\n'      > "$REPO/a_b.py"
printf 'x = "has space"\n'   > "$REPO/has space.py"
printf 'x = "scratch"\n'     > "$REPO/mutation-test-scratch"
ln -s src/pkg/__init__.py    "$REPO/link.py"

chmod +x "$REPO/run_correct.sh" "$REPO/run_nocover.sh" "$REPO/run_needs_setup.sh"

git -C "$REPO" init -q
git -C "$REPO" config user.email "acceptance@example.invalid"
git -C "$REPO" config user.name  "acceptance"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "fixture"

# The trap: an absolute path to the ORIGINAL tree, baked in at setup time
# exactly as an editable install records one. Written after the commit above so
# the path is real, then committed on its own.
cat > "$REPO/run_trap.sh" <<SH
#!/bin/sh
PYTHONPATH="$REPO/src" python3 tests/check.py
SH
chmod +x "$REPO/run_trap.sh"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "trap runner"

# --- manifest ----------------------------------------------------------------
# Byte-for-byte state of every TRACKED file, symlinks and odd names included.
#
# Tracked, not everything on disk, and the distinction is load-bearing. Proving
# the environment is mis-wired means running the caller's test command once; a
# mis-wired command reaches the original tree by definition, and a Python one
# leaves __pycache__ there. That is interpreter cache, not the user's work, and
# an ordinary test run drops the same file. The promise this script makes is
# that your SOURCE is never modified, so that is what is asserted here -- with
# untracked arrivals reported separately below rather than ignored.
manifest() {
  # The file list goes through a temp file, not a pipe: stdin already carries
  # the program text. Piping both silently yields an EMPTY manifest, and two
  # empty manifests compare equal -- the assertion passes while checking
  # nothing. shellcheck SC2259 caught that here; the canary below is what stops
  # it coming back.
  git -C "$1" ls-files -z > "$FIXTURE/filelist"
  python3 - "$1" "$FIXTURE/filelist" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
with open(sys.argv[2], 'rb') as fh:
    names = [n for n in fh.read().split(b'\0') if n]
out = []
for raw in names:
    rel = raw.decode('utf-8', 'surrogateescape')
    p = os.path.join(root, rel)
    if os.path.islink(p):
        out.append(f'{rel}\tsymlink\t{os.readlink(p)}')
    elif os.path.isfile(p):
        with open(p, 'rb') as fh:
            out.append(f'{rel}\t{oct(os.stat(p).st_mode)[-4:]}\t{hashlib.sha256(fh.read()).hexdigest()}')
    else:
        out.append(f'{rel}\tMISSING')
print('\n'.join(sorted(out)))
PY
}

BEFORE="$FIXTURE/before.manifest"
manifest "$REPO" > "$BEFORE"

# Positive control for the manifest itself. Every isolation assertion below
# compares two manifests, so a manifest that silently collects nothing turns
# all of them green while testing nothing at all. Name the awkward entries
# explicitly: if the collector breaks, this fails before anything else runs.
for want in 'a/b.py' 'a_b.py' 'has space.py' 'link.py' 'mutation-test-scratch'; do
  if ! grep -q "^$want	" "$BEFORE"; then
    echo "  FAIL  manifest is not collecting '$want' — every isolation check below would be vacuous" >&2
    exit 1
  fi
done

echo "Fixture: $(wc -l < "$BEFORE" | tr -d ' ') tracked entries, including a/b.py beside a_b.py, a path with a space, and a symlink"
echo

# --- helpers -----------------------------------------------------------------
# Runs create and reports its exit code; stdout (the worktree path) is captured.
run_create() {
  CREATE_OUT=$("$WT_SH" create --repo "$REPO" "$@" 2>"$FIXTURE/err.txt")
  CREATE_RC=$?
  CREATE_ERR=$(cat "$FIXTURE/err.txt")
  return 0
}

expect_rc() { # expected, label
  if [ "$CREATE_RC" -eq "$1" ]; then pass "$2"; else
    fail "$2 (expected exit $1, got $CREATE_RC)"
    printf '%s\n' "$CREATE_ERR" | sed 's/^/          /' | head -6
  fi
}

echo "Gates"

# 1. Happy path.
run_create --test ./run_correct.sh --probe src/pkg/__init__.py
expect_rc 0 "clean run: baseline green and mutation visible"
HAPPY_WT="$CREATE_OUT"
if [ -n "$HAPPY_WT" ] && [ -d "$HAPPY_WT" ]; then
  pass "clean run: printed a worktree that exists"
  if [ -f "$HAPPY_WT/src/pkg/__init__.py" ] && ! grep -q 'mutation_test_wiring_probe' "$HAPPY_WT/src/pkg/__init__.py"; then
    pass "clean run: probe marker removed from the worktree"
  else
    fail "clean run: probe marker left behind in the worktree"
  fi
  "$WT_SH" destroy "$HAPPY_WT" >/dev/null 2>&1
  [ -d "$HAPPY_WT" ] && fail "destroy: worktree still on disk" || pass "destroy: worktree removed"
else
  fail "clean run: no usable worktree path on stdout"
fi

# 2. The editable-install trap: environment resolves to the ORIGINAL tree.
run_create --test ./run_trap.sh --probe src/pkg/__init__.py
expect_rc 4 "absolute-path environment refused (would report every mutant a survivor)"

# 3. A probe file no test exercises.
run_create --test ./run_nocover.sh --probe src/pkg/__init__.py
expect_rc 4 "uncovered probe file refused"

# 4. Incomplete bootstrap shows up as a red baseline.
run_create --test ./run_needs_setup.sh --probe src/pkg/__init__.py
expect_rc 3 "red baseline refused"

# 5. ...and --setup fixes exactly that.
run_create --test ./run_needs_setup.sh --probe src/pkg/__init__.py --setup 'touch .bootstrapped'
expect_rc 0 "--setup makes the same baseline green"
[ -n "$CREATE_OUT" ] && "$WT_SH" destroy "$CREATE_OUT" >/dev/null 2>&1

# 6. Argument validation.
run_create --test ./run_correct.sh --probe src/pkg/__init__.py --ref '-oops'
expect_rc 2 "ref beginning with a dash refused"
run_create --test ./run_correct.sh --probe src/pkg/__init__.py --ref 'a..b'
expect_rc 2 "ref containing .. refused"
run_create --test ./run_correct.sh --probe no/such/file.py
expect_rc 2 "missing probe file refused"
run_create --probe src/pkg/__init__.py
expect_rc 2 "missing --test refused"

echo
echo "Isolation"

# 7. Concurrency: two runs at once. The predecessor needed a lock and had none.
"$WT_SH" create --repo "$REPO" --test ./run_correct.sh --probe src/pkg/__init__.py >"$FIXTURE/c1" 2>/dev/null &
p1=$!
"$WT_SH" create --repo "$REPO" --test ./run_correct.sh --probe src/pkg/__init__.py >"$FIXTURE/c2" 2>/dev/null &
p2=$!
wait $p1; rc1=$?
wait $p2; rc2=$?
w1=$(cat "$FIXTURE/c1"); w2=$(cat "$FIXTURE/c2")
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ -n "$w1" ] && [ -n "$w2" ] && [ "$w1" != "$w2" ]; then
  pass "two concurrent runs both succeeded, in separate worktrees"
else
  fail "concurrent runs interfered (rc $rc1/$rc2)"
fi
[ -n "$w1" ] && "$WT_SH" destroy "$w1" >/dev/null 2>&1
[ -n "$w2" ] && "$WT_SH" destroy "$w2" >/dev/null 2>&1

# 8. The whole point: the source tree is untouched by any of the above.
AFTER="$FIXTURE/after.manifest"
manifest "$REPO" > "$AFTER"
if diff -q "$BEFORE" "$AFTER" >/dev/null; then
  pass "every tracked file byte-identical after every run"
else
  fail "SOURCE TREE CHANGED:"
  diff "$BEFORE" "$AFTER" | sed 's/^/          /' | head -10
fi

# Anything that ARRIVED in the tree. Expected: interpreter bytecode cache, and
# only from the trap case, where proving the mis-wiring required running a
# command that reaches the original tree. Anything else would mean this design
# has started writing to the user's repository, which is the thing it exists to
# avoid -- so the allowance is named rather than a blanket ignore.
arrived=$(git -C "$REPO" status --porcelain --untracked-files=all 2>/dev/null | sed -n 's/^?? //p')
unexpected=$(printf '%s\n' "$arrived" | grep -v '__pycache__' | grep -v '\.pyc$' | grep -v '^$' || true)
if [ -z "$unexpected" ]; then
  if [ -n "$arrived" ]; then
    pass "only interpreter bytecode cache arrived (from proving the trap)"
  else
    pass "nothing arrived in the source tree at all"
  fi
else
  fail "unexpected files written into the source tree:"
  printf '%s\n' "$unexpected" | sed 's/^/          /'
fi

# 9. No worktree registrations left behind.
left=$(git -C "$REPO" worktree list | grep -c . )
if [ "$left" -eq 1 ]; then
  pass "no worktree registrations left behind"
else
  fail "$((left - 1)) worktree registration(s) leaked"
  git -C "$REPO" worktree list | sed 's/^/          /'
fi

echo
if [ "$fail_n" -eq 0 ]; then
  echo "PASS — $pass_n assertion(s)"
  exit 0
fi
echo "FAIL — $fail_n failure(s), $pass_n passed"
exit 1
