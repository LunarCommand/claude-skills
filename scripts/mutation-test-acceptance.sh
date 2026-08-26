#!/usr/bin/env bash
# mutation-test-acceptance.sh — behavioural tests for mutation_test_worktree.sh.
#
# Everything else in scripts/validate.sh is syntactic. This runs the artifact
# and asserts on what it does.
#
# Rules here, each one paid for by a defect that got through an earlier version:
#   * an assertion must be able to KILL the guard it names. Mutate the guard;
#     if the suite stays green, the assertion is decoration.
#   * feed each guard the thing IT refuses, not a thing something else refuses.
#   * never call pass() on both branches. The previous signal assertion did,
#     so it could not fail, and it burned 30 of the suite's 37 seconds.
#   * needles are FIXED strings (grep -F). As a BRE, a needle split across a
#     line break degraded into an OR and matched the token "NOT" anywhere.
#   * choose fixtures from the documented hazard, not from the implementation.
#     The old tree-reactivity fixture used `git status --porcelain` — the one
#     variant the code caught — while `git diff --exit-code`, the archetype the
#     error message named, sailed through.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
WT_SH="$REPO_ROOT/skills/mutation-test/bin/mutation_test_worktree.sh"

for c in git python3 sed; do
  command -v "$c" >/dev/null 2>&1 || { echo "  FAIL  missing required command: $c" >&2; exit 127; }
done

pass_n=0; fail_n=0
pass() { pass_n=$((pass_n + 1)); printf '  ok    %s\n' "$*"; }
fail() { fail_n=$((fail_n + 1)); printf '  FAIL  %s\n' "$*"; }

FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/mt-acceptance.XXXXXX") || exit 1
FIXTURE=$(cd "$FIXTURE" && pwd -P)
TMPRES=$(cd "${TMPDIR:-/tmp}" && pwd -P)
# Only ever touch worktrees belonging to THIS fixture. Globbing the shared
# TMPDIR unfiltered meant one stale file from any killed run turned the suite,
# validate.sh and CI red against unrelated code.
mine() { # dir -> 0 if it belongs to this run's fixture
  case $(git -C "$1" rev-parse --git-common-dir 2>/dev/null) in "$FIXTURE"/*) return 0 ;; esac
  return 1
}
cleanup() {
  for d in "$TMPRES"/mutation-test-wt.*; do [ -d "$d" ] && mine "$d" && rm -rf "$d"; done
  rm -rf "$FIXTURE"
}
trap cleanup EXIT

REPO="$FIXTURE/repo"
mkdir -p "$REPO/src/pkg" "$REPO/tests" "$REPO/sub"
printf 'def f():\n    return 1\n'                                    > "$REPO/src/pkg/__init__.py"
printf 'import sys\nimport pkg\nsys.exit(0 if pkg.f() == 1 else 1)\n' > "$REPO/tests/check.py"
cat > "$REPO/run_correct.sh" <<'SH'
#!/bin/sh
PYTHONPATH="$(pwd)/src" python3 tests/check.py
SH
cat > "$REPO/run_needs_setup.sh" <<'SH'
#!/bin/sh
[ -f .bootstrapped ] || exit 1
PYTHONPATH="$(pwd)/src" python3 tests/check.py
SH
cat > "$REPO/run_notfound.sh" <<'SH'
#!/bin/sh
exec ./definitely-not-here
SH
chmod +x "$REPO"/run_*.sh
git -C "$REPO" init -q
git -C "$REPO" config user.email "acceptance@example.invalid"
git -C "$REPO" config user.name  "acceptance"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "fixture"
printf 'def f():\n    return 1  # second commit\n' > "$REPO/src/pkg/__init__.py"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "second"

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
    st = os.lstat(p)
    if os.path.islink(p):
        out.append(f'{rel}\tsymlink\t{os.readlink(p)}')
    else:
        with open(p, 'rb') as fh:
            d = hashlib.sha256(fh.read()).hexdigest()
        out.append(f'{rel}\t{oct(st.st_mode)[-4:]}\t{d}\tino={st.st_ino}\tmtime={st.st_mtime_ns}')
print('\n'.join(sorted(out)))
PY
}
listing() {
  python3 - "$1" <<'PY'
import os, sys
root = sys.argv[1]; out = []
for dirpath, dirnames, filenames in os.walk(root):
    if '.git' in dirnames: dirnames.remove('.git')
    for n in filenames + dirnames:
        out.append(os.path.relpath(os.path.join(dirpath, n), root))
print('\n'.join(sorted(out)))
PY
}
arrivals() {
  python3 - "$1" "$2" <<'PY'
import sys
b=set(open(sys.argv[1]).read().splitlines()); a=set(open(sys.argv[2]).read().splitlines())
print('\n'.join(sorted(a-b)))
PY
}
# The worktree shares the repository's .git, so --setup CAN change real
# metadata. Neither collector above can see that: manifest covers tracked files
# and listing drops .git. This is the third one.
gitstate() {
  {
    git -C "$1" rev-parse HEAD
    git -C "$1" config --local --list | LC_ALL=C sort
    git -C "$1" for-each-ref --format='%(refname) %(objectname)' | LC_ALL=C sort
    git -C "$1" worktree list --porcelain | LC_ALL=C sort
  } 2>/dev/null
}

# Run BEFORE the collectors below: these deliberately edit a tracked file, and
# the isolation compare must measure only what the SCRIPT under test did.
printf 'import sys\nimport pkg\nsys.exit(0)\n' > "$REPO/tests/check.py"
DIRTY_ERR=$("$WT_SH" run --repo "$REPO" --test ./run_correct.sh -- true 2>&1 >/dev/null); DIRTY_RC=$?
"$WT_SH" run --repo "$REPO/sub" --test ./run_correct.sh -- true >/dev/null 2>&1; DIRTY_SUB_RC=$?
"$WT_SH" run --repo "$REPO" --test ./run_correct.sh --ref HEAD -- true >/dev/null 2>&1; DIRTY_REF_RC=$?
git -C "$REPO" checkout -q -- tests/check.py

BEFORE="$FIXTURE/before.manifest"; manifest "$REPO" > "$BEFORE"
BEFORE_LS="$FIXTURE/before.listing"; listing "$REPO" > "$BEFORE_LS"
BEFORE_GIT="$FIXTURE/before.git"; gitstate "$REPO" > "$BEFORE_GIT"
grep -q 'ino=' "$BEFORE" || { echo "  FAIL  manifest lost its inode/mtime columns" >&2; exit 1; }
[ -s "$BEFORE_GIT" ] || { echo "  FAIL  gitstate collected nothing — the .git assertion would be vacuous" >&2; exit 1; }

echo "Fixture: $(wc -l < "$BEFORE" | tr -d ' ') tracked entries, two commits"
echo

run_wt() {
  "$WT_SH" run --repo "$REPO" "$@" >/dev/null 2>"$FIXTURE/err.txt"
  RUN_RC=$?
  RUN_ERR=$(cat "$FIXTURE/err.txt")
  return 0
}
expect() { # rc, slug, label — matches the machine-readable refusal line
  local want=$1 slug=$2 label=$3
  if [ "$RUN_RC" -ne "$want" ]; then
    fail "$label (expected exit $want, got $RUN_RC)"; printf '%s\n' "$RUN_ERR" | sed 's/^/          /' | head -4
  elif ! printf '%s' "$RUN_ERR" | grep -qF "refused: $slug"; then
    fail "$label (exit $want, but the refusal slug was not '$slug')"; printf '%s\n' "$RUN_ERR" | sed 's/^/          /' | head -4
  else
    pass "$label"
  fi
}

echo "Removed surfaces"
for sub in create destroy; do
  err=$("$WT_SH" "$sub" "$REPO" 2>&1); rc=$?
  { [ "$rc" -eq 40 ] && printf '%s' "$err" | grep -qF 'was removed'; } \
    && pass "'$sub' refused with an explanation" || fail "'$sub' exited $rc"
done
[ -d "$REPO/.git" ] && pass "fixture repository intact" || fail "THE FIXTURE REPOSITORY WAS DESTROYED"
for flag in --probe --exec-probe; do
  run_wt --test ./run_correct.sh "$flag" src/pkg/__init__.py -- true
  expect 40 usage "'$flag' refused, and says why probing was dropped"
done

echo
echo "What it establishes"
run_wt --test ./run_correct.sh -- sh -c 'test -n "$MUTATION_TEST_WORKTREE" && test -f "$MUTATION_TEST_WORKTREE/tests/check.py"'
[ "$RUN_RC" -eq 0 ] && pass "clean run: baseline green, command runs in the worktree" \
  || { fail "clean run rejected (exit $RUN_RC)"; printf '%s\n' "$RUN_ERR" | sed 's/^/          /' | head -4; }

run_wt --test ./run_correct.sh -- sh -c 'exit 42'
[ "$RUN_RC" -eq 42 ] && pass "the command's exit status passes through" || fail "expected 42, got $RUN_RC"

run_wt --test ./run_needs_setup.sh -- true
expect 43 baseline-red "red baseline refused"
run_wt --test ./run_needs_setup.sh --setup 'touch .bootstrapped' -- true
[ "$RUN_RC" -eq 0 ] && pass "--setup makes the same baseline green" || fail "--setup did not fix the baseline ($RUN_RC)"

# A command that cannot RUN must not be reported as the user's code being red.
run_wt --test ./run_notfound.sh -- true
expect 42 test-command-broken "a --test that cannot run is breakage, not a red baseline"
run_wt --test ./run_correct.sh --setup './definitely-not-here' -- true
expect 42 test-command-broken "a --setup that cannot run is breakage too"
run_wt --test ./run_correct.sh --setup 'exit 3' -- true
expect 42 setup-failed "a --setup that runs and FAILS is refused as setup-failed"

echo
echo "Repository state"
if [ "$DIRTY_RC" -eq 44 ] && printf '%s' "$DIRTY_ERR" | grep -qF 'refused: dirty-tree'; then
  pass "a dirty TEST file is refused (not just the mutated file)"
else
  fail "dirty test file not refused (exit $DIRTY_RC)"
fi
printf '%s' "$DIRTY_ERR" | grep -qF 'tests/check.py' \
  && pass "the refusal names the dirty file" || fail "the refusal did not name tests/check.py"
if [ "$DIRTY_SUB_RC" -eq 44 ]; then
  pass "still refused when invoked from a subdirectory"
else
  fail "not refused from a subdirectory (exit $DIRTY_SUB_RC) — status is not anchored to the toplevel"
fi
if [ "$DIRTY_REF_RC" -eq 0 ]; then
  pass "an explicit --ref bypasses the check, as documented"
else
  fail "explicit --ref did not bypass the dirty check (exit $DIRTY_REF_RC)"
fi

run_wt --test ./run_correct.sh --ref HEAD~1 -- true
[ "$RUN_RC" -eq 0 ] && pass "an explicit --ref to an older commit is allowed" \
  || fail "--ref HEAD~1 refused ($RUN_RC): $(printf '%s' "$RUN_ERR" | head -1)"

# Distinct slugs, because rev-parse rejects these inputs too: with one shared
# slug the assertions stayed green after deleting validate_ref entirely.
run_wt --test ./run_correct.sh --ref '-oops' -- true
expect 40 malformed-ref "ref beginning with a dash refused BY THE SYNTAX GUARD"
run_wt --test ./run_correct.sh --ref 'a..b' -- true
expect 40 malformed-ref "ref containing .. refused BY THE SYNTAX GUARD"
run_wt --test ./run_correct.sh --ref 'no-such-ref' -- true
expect 40 bad-ref "an unresolvable ref is refused by rev-parse"
run_wt -- true
[ "$RUN_RC" -eq 40 ] && pass "missing --test refused" || fail "missing --test exited $RUN_RC"
run_wt --test ./run_correct.sh
[ "$RUN_RC" -eq 40 ] && pass "missing trailing command refused" || fail "missing command exited $RUN_RC"

echo
echo "Lifecycle"
run_wt --test ./run_correct.sh --keep -- sh -c 'exit 7'
kept=$(printf '%s' "$RUN_ERR" | sed -n 's/^worktree kept at: //p')
if [ -n "$kept" ] && [ -d "$kept" ]; then
  pass "--keep keeps the worktree when the command fails"
  printf '%s' "$RUN_ERR" | grep -qF 'git -C' && pass "--keep prints the removal command" || fail "--keep printed no removal command"
  git -C "$REPO" worktree remove --force "$kept" >/dev/null 2>&1; rm -rf "$kept"
else
  fail "--keep did not report a surviving worktree"
fi
run_wt --test ./run_correct.sh --keep -- true
[ -z "$(printf '%s' "$RUN_ERR" | sed -n 's/^worktree kept at: //p')" ] \
  && pass "--keep still tears down after a SUCCESSFUL run" || fail "--keep leaked a worktree on success"

# Real assertion, and fast: 3s not 30s, and it checks cleanup, not just the code.
"$WT_SH" run --repo "$REPO" --test ./run_correct.sh -- sleep 20 >/dev/null 2>"$FIXTURE/sig.txt" &
sig_pid=$!
i=0; while [ $i -lt 40 ] && ! ls -d "$TMPRES"/mutation-test-wt.* >/dev/null 2>&1; do i=$((i+1)); sleep 0.25; done
kill -TERM "$sig_pid" 2>/dev/null
wait "$sig_pid" 2>/dev/null; sig_rc=$?
strays=0
for d in "$TMPRES"/mutation-test-wt.*; do [ -d "$d" ] && mine "$d" && strays=$((strays+1)); done
if [ "$sig_rc" -eq 130 ] && [ "$strays" -eq 0 ]; then
  pass "an interrupted run exits 130 and removes its worktree"
else
  fail "interrupted run: exit $sig_rc, $strays worktree(s) left behind"
  for d in "$TMPRES"/mutation-test-wt.*; do [ -d "$d" ] && mine "$d" && rm -rf "$d"; done
fi

echo
echo "Isolation"
"$WT_SH" run --repo "$REPO" --test ./run_correct.sh -- sleep 1 >/dev/null 2>&1 & p1=$!
"$WT_SH" run --repo "$REPO" --test ./run_correct.sh -- sleep 1 >/dev/null 2>&1 & p2=$!
wait $p1; rc1=$?; wait $p2; rc2=$?
{ [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]; } && pass "two concurrent runs both succeeded" || fail "concurrent runs interfered ($rc1/$rc2)"

manifest "$REPO" > "$FIXTURE/after.manifest"
if diff -q "$BEFORE" "$FIXTURE/after.manifest" >/dev/null; then
  pass "every tracked file identical — content, inode AND mtime"
else
  fail "SOURCE TREE CHANGED:"; diff "$BEFORE" "$FIXTURE/after.manifest" | sed 's/^/          /' | head -8
fi
listing "$REPO" > "$FIXTURE/after.listing"
unexpected=$(arrivals "$BEFORE_LS" "$FIXTURE/after.listing" | grep -v '__pycache__' | grep -v '\.pyc$' | grep -v '^$' || true)
[ -z "$unexpected" ] && pass "nothing arrived in the source tree" \
  || { fail "files written into the source tree:"; printf '%s\n' "$unexpected" | sed 's/^/          /'; }

gitstate "$REPO" > "$FIXTURE/after.git"
if diff -q "$BEFORE_GIT" "$FIXTURE/after.git" >/dev/null; then
  pass "the repository's .git is unchanged — HEAD, config, refs, worktree list"
else
  fail ".git METADATA CHANGED:"; diff "$BEFORE_GIT" "$FIXTURE/after.git" | sed 's/^/          /' | head -8
fi

strays=0
for d in "$TMPRES"/mutation-test-wt.*; do [ -d "$d" ] && mine "$d" && strays=$((strays+1)); done
[ "$strays" -eq 0 ] && pass "no worktree directories leaked (this run's only)" || fail "$strays worktree(s) leaked"

echo
if [ "$fail_n" -eq 0 ]; then echo "PASS — $pass_n assertion(s)"; exit 0; fi
echo "FAIL — $fail_n failure(s), $pass_n passed"
exit 1
