#!/usr/bin/env bash
# mutation-test-acceptance.sh — behavioural tests for mutation_test_worktree.sh.
#
# The rest of scripts/validate.sh is syntactic: it checks that artifacts are
# spelled correctly, not that they do what they claim. That gap is why a
# non-injective backup key shipped once and passed every check.
#
# The first version of THIS file had the same disease. It built hostile
# fixtures -- a symlink, a path with a space, a/b.py beside a_b.py -- and then
# never passed any of them as --probe. It called destroy only on paths create
# had just returned, so a destroy that rm -rf'd whole repositories passed it.
# It compared content-only manifests, which cannot see a file written and then
# restored: the predecessor's entire failure mode. Every one of those was found
# by review, not by the suite.
#
# So the rules here are: use the hostile fixtures as INPUTS, feed each guard the
# thing it refuses, and assert on the REASON, not just the exit code -- an
# assertion that stays green when you delete the guard it names is not a test.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
WT_SH="$REPO_ROOT/skills/mutation-test/bin/mutation_test_worktree.sh"

# Preflight. Without this the manifest silently produces nothing and the canary
# below reports "not collecting a/b.py", sending the reader after a collector
# bug instead of an absent interpreter.
for c in git python3 cmp; do
  command -v "$c" >/dev/null 2>&1 || {
    echo "  FAIL  missing required command: $c (install it; this suite cannot run without it)" >&2
    exit 127
  }
done

pass_n=0; fail_n=0
pass() { pass_n=$((pass_n + 1)); printf '  ok    %s\n' "$*"; }
fail() { fail_n=$((fail_n + 1)); printf '  FAIL  %s\n' "$*"; }

FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/mt-acceptance.XXXXXX") || exit 1
cleanup() {
  [ -d "$FIXTURE/repo" ] && git -C "$FIXTURE/repo" worktree prune >/dev/null 2>&1
  for d in "${TMPDIR:-/tmp}"/mutation-test-wt.*; do
    [ -d "$d" ] && case $(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null) in
      "$FIXTURE"/*) rm -rf "$d" ;;
    esac
  done
  rm -rf "$FIXTURE"
}
trap cleanup EXIT

REPO="$FIXTURE/repo"
mkdir -p "$REPO/src/pkg" "$REPO/tests" "$REPO/a"

printf 'def f():\n    return 1\n'                             > "$REPO/src/pkg/__init__.py"
printf 'import sys\nimport pkg\nsys.exit(0 if pkg.f() == 1 else 1)\n' > "$REPO/tests/check.py"

# Correct wiring: PYTHONPATH resolves at run time, so it follows the worktree.
printf '#!/bin/sh\nPYTHONPATH="$(pwd)/src" python3 tests/check.py\n' > "$REPO/run_correct.sh"
# Never imports the probe file at all.
printf '#!/bin/sh\nexit 0\n'                                  > "$REPO/run_nocover.sh"
# Fails until a bootstrap step has run.
printf '#!/bin/sh\n[ -f .bootstrapped ] || exit 1\nPYTHONPATH="$(pwd)/src" python3 tests/check.py\n' > "$REPO/run_needs_setup.sh"
# Parses the probe file but never executes it -- a lint step. A heredoc, not
# printf: \xNN escapes are a GNU extension that BSD printf emits literally.
cat > "$REPO/run_lint_only.sh" <<'LINTSH'
#!/bin/sh
python3 -c "import ast; ast.parse(open('src/pkg/__init__.py').read())"
LINTSH
# Not idempotent: red on every run after the first.
printf '#!/bin/sh\n[ -f .stamp ] && exit 1\ntouch .stamp\nexit 0\n' > "$REPO/run_stamp.sh"
# Never runs at all: exit 127 territory.
printf '#!/bin/sh\nexec ./definitely-not-here\n'              > "$REPO/run_broken.sh"

printf 'x = "a/b.py"\n'    > "$REPO/a/b.py"
printf 'x = "a_b.py"\n'    > "$REPO/a_b.py"
printf 'x = "has space"\n' > "$REPO/has space.py"
printf 'x = "scratch"\n'   > "$REPO/mutation-test-scratch"
ln -s src/pkg/__init__.py  "$REPO/link.py"

chmod +x "$REPO"/run_*.sh
git -C "$REPO" init -q
git -C "$REPO" config user.email "acceptance@example.invalid"
git -C "$REPO" config user.name  "acceptance"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "fixture"

# The editable-install trap, and a compound command whose lint half sees the
# worktree while its test half resolves to the ORIGINAL tree. Written after the
# first commit so the absolute path is real.
printf '#!/bin/sh\nPYTHONPATH="%s/src" python3 tests/check.py\n' "$REPO" > "$REPO/run_trap.sh"
printf '#!/bin/sh\n./run_lint_only.sh && ./run_trap.sh\n'               > "$REPO/run_lint_then_trap.sh"
# A symlink pointing OUTSIDE the repository entirely.
printf 'ORIGINAL OUTSIDE CONTENT\n' > "$FIXTURE/outside_victim.txt"
ln -s "$FIXTURE/outside_victim.txt" "$REPO/escape.py"
chmod +x "$REPO/run_trap.sh" "$REPO/run_lint_then_trap.sh"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "trap runners and an escaping symlink"

# Done BEFORE the baseline manifest below: this test deliberately edits and
# restores a tracked file, and the isolation compare must measure only what the
# script under test did, not what the suite did to set itself up.
printf 'def f():\n    return 999\n' > "$REPO/src/pkg/__init__.py"
DIRTY_ERR=$("$WT_SH" create --repo "$REPO" --test ./run_correct.sh --probe src/pkg/__init__.py 2>&1 >/dev/null)
DIRTY_RC=$?
git -C "$REPO" checkout -q -- src/pkg/__init__.py

# --- manifest ----------------------------------------------------------------
# Records inode and mtime as well as content. A content-only manifest cannot
# see a file that was written and then restored, which is EXACTLY what the
# predecessor did before reporting success -- so a content-only compare would
# have called that run clean.
#
# The file list goes through a temp file, not a pipe: stdin already carries the
# program text. Piping both silently yields an EMPTY manifest, and two empty
# manifests compare equal, so every assertion passes while checking nothing.
# That was caught by shellcheck's SC2259; the canary below stops it returning.
manifest() {
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
        st = os.lstat(p)
        with open(p, 'rb') as fh:
            digest = hashlib.sha256(fh.read()).hexdigest()
        out.append(f'{rel}\t{oct(st.st_mode)[-4:]}\t{digest}\tino={st.st_ino}\tmtime={st.st_mtime_ns}')
    else:
        out.append(f'{rel}\tMISSING')
print('\n'.join(sorted(out)))
PY
}

# Every path on disk, ignoring .git. Deliberately NOT `git status`, which
# honours the developer's global gitignore -- so a write of an ignored shape
# into the source tree was invisible to the old check on their machine.
listing() {
  python3 - "$1" <<'PY'
import os, sys
root = sys.argv[1]
out = []
for dirpath, dirnames, filenames in os.walk(root):
    if '.git' in dirnames:
        dirnames.remove('.git')
    for n in filenames + dirnames:
        out.append(os.path.relpath(os.path.join(dirpath, n), root))
print('\n'.join(sorted(out)))
PY
}

BEFORE="$FIXTURE/before.manifest"
BEFORE_LS="$FIXTURE/before.listing"
manifest "$REPO" > "$BEFORE"
listing  "$REPO" > "$BEFORE_LS"

# Positive control for the collectors. Every isolation assertion compares two
# of these, so a collector that silently gathers nothing turns them all green.
for want in 'a/b.py' 'a_b.py' 'has space.py' 'link.py' 'escape.py' 'mutation-test-scratch'; do
  grep -q "^$want	" "$BEFORE" || {
    echo "  FAIL  manifest is not collecting '$want' — every isolation check below would be vacuous" >&2
    exit 1
  }
done
grep -q 'ino=' "$BEFORE" || {
  echo "  FAIL  manifest lost its inode/mtime columns — a write-then-restore would pass unseen" >&2
  exit 1
}

echo "Fixture: $(wc -l < "$BEFORE" | tr -d ' ') tracked entries — a/b.py beside a_b.py, a path with a space, a symlink, and one symlink escaping the repo"
echo

# --- helpers -----------------------------------------------------------------
run_create() {
  CREATE_OUT=$("$WT_SH" create --repo "$REPO" "$@" 2>"$FIXTURE/err.txt")
  CREATE_RC=$?
  CREATE_ERR=$(cat "$FIXTURE/err.txt")
  return 0
}

# Exit code AND reason. An assertion that only checks the code stays green when
# the guard it names is deleted and something else fails for its own reasons.
expect() { # rc, needle, label
  local want=$1 needle=$2 label=$3
  if [ "$CREATE_RC" -ne "$want" ]; then
    fail "$label (expected exit $want, got $CREATE_RC)"
    printf '%s\n' "$CREATE_ERR" | sed 's/^/          /' | head -4
  elif ! printf '%s' "$CREATE_ERR" | grep -q -- "$needle"; then
    fail "$label (exit $want as expected, but not for the stated reason: no '$needle')"
    printf '%s\n' "$CREATE_ERR" | sed 's/^/          /' | head -4
  else
    pass "$label"
  fi
}

destroyed() { [ -n "$1" ] && "$WT_SH" destroy "$1" >/dev/null 2>&1; }

echo "Wiring gates"

run_create --test ./run_correct.sh --probe src/pkg/__init__.py
if [ "$CREATE_RC" -eq 0 ] && [ -n "$CREATE_OUT" ] && [ -d "$CREATE_OUT" ]; then
  pass "clean run: accepted, worktree returned"
  grep -q 'mutation_test_wiring_probe' "$CREATE_OUT/src/pkg/__init__.py" \
    && fail "clean run: probe marker left in the worktree" \
    || pass "clean run: probe marker removed"
  destroyed "$CREATE_OUT"
  [ -d "$CREATE_OUT" ] && fail "destroy: worktree still on disk" || pass "destroy: removes a worktree it created"
else
  fail "clean run: expected exit 0 with a worktree (got $CREATE_RC)"
  printf '%s\n' "$CREATE_ERR" | sed 's/^/          /' | head -4
fi

run_create --test ./run_trap.sh --probe src/pkg/__init__.py
expect 4 'still PASSES' "editable-install trap refused"

run_create --test ./run_nocover.sh --probe src/pkg/__init__.py
expect 4 'still PASSES' "uncovered probe file refused"

# The case a single syntax probe cannot see: lint parses the file and objects,
# so the command goes red, while the step that judges mutants reads elsewhere.
run_create --test ./run_lint_then_trap.sh --probe src/pkg/__init__.py
expect 4 'EMPTYING it did not' "lint-only red refused (syntax probe alone would pass this)"

run_create --test ./run_stamp.sh --probe src/pkg/__init__.py
expect 4 'return to GREEN' "non-idempotent test command refused"

run_create --test ./run_broken.sh --probe src/pkg/__init__.py
expect 3 'baseline is RED' "a command that cannot run is a red baseline"

run_create --test ./run_needs_setup.sh --probe src/pkg/__init__.py
expect 3 'baseline is RED' "red baseline refused"

run_create --test ./run_needs_setup.sh --probe src/pkg/__init__.py --setup 'touch .bootstrapped'
[ "$CREATE_RC" -eq 0 ] && pass "--setup makes the same baseline green" || fail "--setup did not fix the baseline (exit $CREATE_RC)"
destroyed "$CREATE_OUT"

echo
echo "Containment"

# The probe write is the one write this design makes. A tracked symlink is a
# write straight through it, out of the worktree.
run_create --test ./run_correct.sh --probe escape.py
expect 2 'is a symlink' "symlink probe refused (escapes the worktree)"
if [ "$(cat "$FIXTURE/outside_victim.txt")" = "ORIGINAL OUTSIDE CONTENT" ]; then
  pass "file outside the repo untouched"
else
  fail "A FILE OUTSIDE THE REPOSITORY WAS MODIFIED: $(cat "$FIXTURE/outside_victim.txt")"
fi

run_create --test ./run_correct.sh --probe link.py
expect 2 'is a symlink' "symlink probe refused even when it points inside"

run_create --test ./run_correct.sh --probe '../../../etc/hosts'
expect 2 "'\.\.' component" "probe with .. refused"

run_create --test ./run_correct.sh --probe '/etc/hosts'
expect 2 'repo-relative' "absolute probe refused"

run_create --test ./run_correct.sh --probe 'a/b.py'
expect 4 'still PASSES' "colliding path a/b.py is usable as a probe (and uncovered)"

run_create --test ./run_correct.sh --probe 'has space.py'
expect 4 'still PASSES' "path with a space is usable as a probe"

echo
echo "destroy refuses what it did not create"

for target in "$REPO" "$REPO/src" "$FIXTURE"; do
  err=$("$WT_SH" destroy "$target" 2>&1); rc=$?
  label="destroy $(basename "$target")"
  if [ "$rc" -eq 0 ]; then
    fail "$label was DELETED or reported success (exit 0)"
  elif printf '%s' "$err" | grep -q -- 'refusing'; then
    pass "$label refused"
  else
    fail "$label exited $rc but not with a refusal: $(printf '%s' "$err" | head -1)"
  fi
done
[ -d "$REPO/.git" ] && pass "fixture repository still intact" || fail "THE FIXTURE REPOSITORY WAS DESTROYED"

err=$("$WT_SH" destroy "$FIXTURE/not-there" 2>&1); rc=$?
[ "$rc" -eq 0 ] && pass "destroy on a missing path is a no-op" || fail "destroy on a missing path exited $rc"

# A repository that WEARS the right name, in the right directory. The name and
# location checks pass here, so only the main-worktree check can refuse it --
# which is the point: the three cases above are all stopped by the name alone,
# so none of them can tell you whether that check still exists.
DECOY="${TMPDIR:-/tmp}/mutation-test-wt.decoy$$"
rm -rf "$DECOY"; mkdir -p "$DECOY"
git -C "$DECOY" init -q
git -C "$DECOY" config user.email "acceptance@example.invalid"
git -C "$DECOY" config user.name  "acceptance"
printf 'precious\n' > "$DECOY/work.txt"
git -C "$DECOY" add -A; git -C "$DECOY" commit -qm decoy
err=$("$WT_SH" destroy "$DECOY" 2>&1); rc=$?
if [ "$rc" -eq 0 ] || [ ! -d "$DECOY" ]; then
  fail "destroy DELETED a main working tree that merely had the right name (exit $rc)"
elif printf '%s' "$err" | grep -q -- 'MAIN working tree'; then
  pass "destroy refuses a main working tree wearing a worktree name"
else
  fail "destroy refused the decoy but not as a main working tree: $(printf '%s' "$err" | head -1)"
fi
[ -f "$DECOY/work.txt" ] && pass "decoy repository's contents intact" || fail "DECOY REPOSITORY CONTENTS DESTROYED"
rm -rf "$DECOY"

echo
echo "Repository state"

if [ "$DIRTY_RC" -eq 6 ] && printf '%s' "$DIRTY_ERR" | grep -q -- 'disagree about'; then
  pass "uncommitted edit to the probe file refused"
else
  fail "uncommitted edit to the probe file not refused (exit $DIRTY_RC)"
  printf '%s\n' "$DIRTY_ERR" | sed 's/^/          /' | head -4
fi

run_create --test ./run_correct.sh --probe src/pkg/__init__.py --ref '-oops'
expect 2 "may not begin with" "ref beginning with a dash refused, by the ref guard"

run_create --test ./run_correct.sh --probe src/pkg/__init__.py --ref 'a..b'
expect 2 "may not contain" "ref containing .. refused, by the ref guard"

run_create --test ./run_correct.sh --probe no/such/file.py
expect 6 'not present at' "missing probe file refused"

run_create --probe src/pkg/__init__.py
expect 2 '--test is required' "missing --test refused"

echo
echo "Isolation"

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
destroyed "$w1"; destroyed "$w2"

AFTER="$FIXTURE/after.manifest"
manifest "$REPO" > "$AFTER"
if diff -q "$BEFORE" "$AFTER" >/dev/null; then
  pass "every tracked file identical — content, inode AND mtime"
else
  fail "SOURCE TREE CHANGED (a write that was restored still shows here):"
  diff "$BEFORE" "$AFTER" | sed 's/^/          /' | head -10
fi

AFTER_LS="$FIXTURE/after.listing"
listing "$REPO" > "$AFTER_LS"
arrived=$(comm -13 "$BEFORE_LS" "$AFTER_LS")
unexpected=$(printf '%s\n' "$arrived" | grep -v '__pycache__' | grep -v '\.pyc$' | grep -v '^\.bootstrapped$' | grep -v '^\.stamp$' | grep -v '^$' || true)
if [ -z "$unexpected" ]; then
  pass "nothing unexpected arrived on disk (filesystem walk, not git status)"
else
  fail "unexpected files written into the source tree:"
  printf '%s\n' "$unexpected" | sed 's/^/          /'
fi

left=$(git -C "$REPO" worktree list | grep -c .)
[ "$left" -eq 1 ] && pass "no worktree registrations left behind" || {
  fail "$((left - 1)) worktree registration(s) leaked"
  git -C "$REPO" worktree list | sed 's/^/          /'
}

stray=0
for d in "${TMPDIR:-/tmp}"/mutation-test-wt.*; do
  [ -d "$d" ] || continue
  case $(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null) in "$FIXTURE"/*) stray=$((stray + 1)) ;; esac
done
[ "$stray" -eq 0 ] && pass "no worktree directories leaked into the temp dir" || fail "$stray worktree(s) leaked on disk"

echo
if [ "$fail_n" -eq 0 ]; then
  echo "PASS — $pass_n assertion(s)"
  exit 0
fi
echo "FAIL — $fail_n failure(s), $pass_n passed"
exit 1
