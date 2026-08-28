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
CL_SH="$REPO_ROOT/skills/mutation-test/bin/mutation_test_changed_lines.sh"
RM_SH="$REPO_ROOT/skills/mutation-test/bin/mutation_test_run_mutants.sh"

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
# --ref HEAD names the very commit the guard compares against, so it must NOT
# buy a bypass; --ref HEAD~1 names a different one and must.
"$WT_SH" run --repo "$REPO" --test ./run_correct.sh --ref HEAD -- true >/dev/null 2>&1; DIRTY_REFHEAD_RC=$?
"$WT_SH" run --repo "$REPO" --test ./run_correct.sh --ref HEAD~1 -- true >/dev/null 2>&1; DIRTY_REFOLD_RC=$?
git -C "$REPO" checkout -q -- tests/check.py

# An untracked test is this skill's primary target state and the worktree will
# not contain it, so it must be refused by its own slug, not lumped in.
printf 'import sys\nsys.exit(0)\n' > "$REPO/tests/test_brand_new.py"
UNTRACKED_ERR=$("$WT_SH" run --repo "$REPO" --test ./run_correct.sh -- true 2>&1 >/dev/null); UNTRACKED_RC=$?
rm -f "$REPO/tests/test_brand_new.py"

# An index bit that hides a file from git status defeats both checks above.
git -C "$REPO" update-index --assume-unchanged tests/check.py
HIDDEN_ERR=$("$WT_SH" run --repo "$REPO" --test ./run_correct.sh -- true 2>&1 >/dev/null); HIDDEN_RC=$?
git -C "$REPO" update-index --no-assume-unchanged tests/check.py

# Content alone cannot see a file written and then restored, which is the
# predecessor's whole failure mode, so identity and mtime come too.
content_id() { python3 -c "
import hashlib,os,sys
p=sys.argv[1]; st=os.lstat(p)
print(f'{st.st_ino}:{st.st_size}:{hashlib.sha256(open(p,\"rb\").read()).hexdigest()}')" "$1"; }

stat_line() { python3 -c "
import os,sys
st=os.lstat(sys.argv[1])
print(f'{st.st_ino}:{st.st_mtime_ns}:{st.st_size}')" "$1"; }

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
run_raw() {  # no implicit --repo, for argument-parsing cases
  "$WT_SH" "$@" >/dev/null 2>"$FIXTURE/err.txt"
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
  { [ "$rc" -eq 40 ] && printf '%s' "$err" | grep -qF 'refused: removed-subcommand'; } \
    && pass "'$sub' refused by its own guard" || fail "'$sub' exited $rc: $(printf '%s' "$err" | head -1)"
done
[ -d "$REPO/.git" ] && pass "fixture repository intact" || fail "THE FIXTURE REPOSITORY WAS DESTROYED"
for flag in --probe --exec-probe; do
  run_wt --test ./run_correct.sh "$flag" src/pkg/__init__.py -- true
  expect 40 removed-flag "'$flag' refused by its own guard, with the reason"
done

echo
echo "What it establishes"
run_wt --test ./run_correct.sh -- sh -c 'test -n "$MUTATION_TEST_WORKTREE" && test -f "$MUTATION_TEST_WORKTREE/tests/check.py"'
[ "$RUN_RC" -eq 0 ] && pass "clean run: baseline green, command runs in the worktree" \
  || { fail "clean run rejected (exit $RUN_RC)"; printf '%s\n' "$RUN_ERR" | sed 's/^/          /' | head -4; }

# CWD, not $MUTATION_TEST_WORKTREE. The env var is an absolute path and stays
# correct even when the command's working directory is wrong, so the assertion
# above passed with `cd "$WT" &&` deleted — and what that guard prevents is the
# caller's writes landing in the user's real checkout.
run_wt --test ./run_correct.sh -- sh -c 'test "$(pwd -P)" = "$(cd "$MUTATION_TEST_WORKTREE" && pwd -P)"'
[ "$RUN_RC" -eq 0 ] && pass "the command's WORKING DIRECTORY is the worktree" \
  || fail "the command did not run with the worktree as its cwd (exit $RUN_RC)"

# ...and the same guard proven from the other side: a RELATIVE write must land
# in the worktree, so the isolation collectors below fail if it reaches $REPO.
run_wt --test ./run_correct.sh -- sh -c 'printf mutant > relative-write-probe.txt'
[ "$RUN_RC" -eq 0 ] && pass "a relative write by the command is accepted" \
  || fail "the relative-write probe failed (exit $RUN_RC)"
stray_probe=""
for d in "$REPO" "$PWD" "$REPO_ROOT"; do
  [ -e "$d/relative-write-probe.txt" ] && stray_probe="$stray_probe $d"
done
if [ -n "$stray_probe" ]; then
  fail "THE COMMAND'S RELATIVE WRITE ESCAPED THE WORKTREE, into:$stray_probe"
  for d in $stray_probe; do rm -f "$d/relative-write-probe.txt"; done
else
  pass "the command's relative write stayed inside the worktree"
fi

run_wt --test ./run_correct.sh -- sh -c 'exit 42'
[ "$RUN_RC" -eq 42 ] && pass "the command's exit status passes through" || fail "expected 42, got $RUN_RC"

run_wt --test ./run_needs_setup.sh -- true
expect 43 baseline-red "red baseline refused"
run_wt --test ./run_needs_setup.sh --setup 'touch .bootstrapped' -- true
[ "$RUN_RC" -eq 0 ] && pass "--setup makes the same baseline green" || fail "--setup did not fix the baseline ($RUN_RC)"

# A command that cannot RUN must not be reported as the user's code being red.
run_wt --test ./run_notfound.sh -- true
expect 42 command-not-runnable "a --test that cannot run is breakage, not a red baseline"
run_wt --test 'kill -TERM $$' -- true
expect 42 command-killed "a --test killed by a signal is refused by its own guard"
run_wt --test ./run_correct.sh --setup './definitely-not-here' -- true
expect 42 command-not-runnable "a --setup that cannot run is breakage too"
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
if [ "$DIRTY_REFHEAD_RC" -eq 44 ]; then
  pass "--ref HEAD does NOT buy a bypass of the dirty check"
else
  fail "--ref HEAD bypassed the dirty check (exit $DIRTY_REFHEAD_RC) — it names the very commit being compared"
fi
if [ "$DIRTY_REFOLD_RC" -eq 0 ]; then
  pass "--ref to a different commit does bypass it, as documented"
else
  fail "--ref HEAD~1 was refused (exit $DIRTY_REFOLD_RC)"
fi
if [ "$UNTRACKED_RC" -eq 44 ] && printf '%s' "$UNTRACKED_ERR" | grep -qF 'refused: untracked-files'; then
  pass "a brand-new UNTRACKED test file is refused by its own slug"
else
  fail "untracked test file not refused (exit $UNTRACKED_RC) — the worktree would not contain it"
fi
if [ "$HIDDEN_RC" -eq 44 ] && printf '%s' "$HIDDEN_ERR" | grep -qF 'refused: hidden-index-bits'; then
  pass "a file hidden by assume-unchanged is refused"
else
  fail "assume-unchanged file not refused (exit $HIDDEN_RC) — it is invisible to git status"
fi

run_wt --test ./run_correct.sh --ref HEAD~1 -- true
[ "$RUN_RC" -eq 0 ] && pass "an explicit --ref to an older commit is allowed" \
  || fail "--ref HEAD~1 refused ($RUN_RC): $(printf '%s' "$RUN_ERR" | head -1)"

# Distinct slugs, because rev-parse rejects these inputs too: with one shared
# slug the assertions stayed green after deleting validate_ref entirely.
# One slug per guarded case: sharing one meant deleting a branch left the
# check and the suite green while a different guard quietly caught the input.
run_wt --test ./run_correct.sh --ref '' -- true
expect 40 empty-ref "an EMPTY ref is refused by its own guard"
run_wt --test ./run_correct.sh --ref '-oops' -- true
expect 40 dash-ref "a ref beginning with a dash is refused by its own guard"
run_wt --test ./run_correct.sh --ref 'a..b' -- true
expect 40 dotdot-ref "a ref containing .. is refused by its own guard"
run_wt --test ./run_correct.sh --ref 'no-such-ref' -- true
expect 40 bad-ref "an unresolvable ref is refused by rev-parse"
run_wt -- true
expect 40 no-test "missing --test refused"
run_wt --test ./run_correct.sh
expect 40 no-command "missing trailing command refused"
run_wt --test ./run_correct.sh --bogus -- true
expect 40 unknown-argument "an unknown argument is refused"
run_raw run --test
expect 40 test-needs-value "--test with no value is refused"
run_raw run --test ./run_correct.sh --setup
expect 40 setup-needs-value "--setup with no value is refused"
run_raw run --test ./run_correct.sh --repo
expect 40 repo-needs-value "--repo with no value is refused"
run_raw run --test ./run_correct.sh --ref
expect 40 ref-needs-value "--ref with no value is refused"
run_raw
expect 40 no-subcommand "no subcommand is refused"
run_raw bogus-subcommand
expect 40 unknown-subcommand "an unknown subcommand is refused"
"$WT_SH" run --repo "$FIXTURE/definitely-not-there" --test ./run_correct.sh -- true >/dev/null 2>"$FIXTURE/err.txt"
RUN_RC=$?; RUN_ERR=$(cat "$FIXTURE/err.txt")
expect 40 no-such-repo "a --repo that does not exist is refused"
"$WT_SH" run --repo "$FIXTURE" --test ./run_correct.sh -- true >/dev/null 2>"$FIXTURE/err.txt"
RUN_RC=$?; RUN_ERR=$(cat "$FIXTURE/err.txt")
expect 40 not-a-repo "a --repo that is not a git repository is refused"
# A BARE repository has a git dir but no working tree, so it passes the
# --git-dir check and fails at --show-toplevel: the only route to that slug.
git init -q --bare "$FIXTURE/bare.git"
run_raw run --repo "$FIXTURE/bare.git" --test ./run_correct.sh -- true
expect 40 no-toplevel "a bare repository is refused for having no working tree"

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
# Wait for the script's OWN readiness marker, not for any directory matching
# the glob. An unrelated stale mutation-test-wt.* satisfied the old poll
# instantly, so the TERM landed before the traps were installed and the suite
# failed with 143 on unmutated code — permanently, because an empty orphan is
# not a git worktree and mine() will not clean it.
i=0; while [ $i -lt 80 ] && ! grep -q 'baseline green' "$FIXTURE/sig.txt" 2>/dev/null; do i=$((i+1)); sleep 0.25; done
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
echo "Scope resolution"

# A diff with known answers: two added lines in a kept file, a DELETED file
# whose lines cannot be mutated, and a file the suffix filter must exclude.
cat > "$FIXTURE/t.diff" <<'DIFF'
diff --git a/keep.py b/keep.py
--- a/keep.py
+++ b/keep.py
@@ -10,3 +10,5 @@ def f():
 context1
+added11
+added12
 context2
diff --git a/gone.py b/gone.py
--- a/gone.py
+++ /dev/null
@@ -1,2 +0,0 @@
-deleted1
-deleted2
diff --git a/other.txt b/other.txt
--- a/other.txt
+++ b/other.txt
@@ -5,1 +5,2 @@
+addedtxt
diff --git a/notes.py.txt b/notes.py.txt
--- a/notes.py.txt
+++ b/notes.py.txt
@@ -1,0 +1,1 @@
+contains-dot-py-but-does-not-end-in-it
DIFF

got=$("$CL_SH" --file "$FIXTURE/t.diff" --suffix .py)
want="keep.py	11
keep.py	12"
[ "$got" = "$want" ] && pass "added lines resolved, deleted file skipped, suffix applied" \
  || { fail "changed-lines output wrong:"; printf '%s\n' "$got" | sed 's/^/          /'; }

got=$("$CL_SH" --file "$FIXTURE/t.diff" | grep -c .)
[ "$got" -eq 4 ] && pass "without a suffix, every added line is reported" || fail "expected 4 lines, got $got"

# notes.py.txt CONTAINS '.py' but does not end in it. A filter that matched
# anywhere in the path rather than at the end would include it.
got=$("$CL_SH" --file "$FIXTURE/t.diff" --suffix .py | grep -c 'notes.py.txt' || true)
[ "$got" -eq 0 ] && pass "a suffix must match the END, not appear anywhere" \
  || fail "'.py' matched notes.py.txt, which merely contains it"

# A suffix is a literal ending, not a pattern: '.py' once matched a file named
# 'apy' because it was escaped into a regex.
printf 'diff --git a/apy b/apy\n--- a/apy\n+++ b/apy\n@@ -1,0 +1,1 @@\n+x\n' > "$FIXTURE/p.diff"
got=$("$CL_SH" --file "$FIXTURE/p.diff" --suffix .py | grep -c . || true)
[ "$got" -eq 0 ] && pass "a suffix matches an ending, not a pattern" || fail "'.py' matched a file named 'apy'"

# stdin is the documented primary input, not just --file
got=$("$CL_SH" --suffix .py < "$FIXTURE/t.diff" | grep -c .)
[ "$got" -eq 2 ] && pass "reads a diff on stdin" || fail "stdin path produced $got lines"

cl_expect() { # rc, slug, label
  local want=$1 slug=$2 label=$3
  if [ "$CL_RC" -ne "$want" ]; then fail "$label (expected exit $want, got $CL_RC)"
  elif ! printf '%s' "$CL_ERR" | grep -qF "refused: $slug"; then
    fail "$label (exit $want, but the slug was not '$slug')"
  else pass "$label"; fi
}
CL_ERR=$("$CL_SH" --file "$FIXTURE/definitely-not-there" 2>&1 >/dev/null); CL_RC=$?
cl_expect 42 no-such-diff "a --file that does not exist is refused"
CL_ERR=$("$CL_SH" --file 2>&1 >/dev/null); CL_RC=$?
cl_expect 40 file-needs-value "--file with no value is refused"
CL_ERR=$("$CL_SH" --out 2>&1 >/dev/null); CL_RC=$?
cl_expect 40 out-needs-value "--out with no value is refused"
CL_ERR=$("$CL_SH" --suffix 2>&1 >/dev/null); CL_RC=$?
cl_expect 40 suffix-needs-value "--suffix with no value is refused"
CL_ERR=$("$CL_SH" --bogus </dev/null 2>&1 >/dev/null); CL_RC=$?
cl_expect 40 unknown-argument "an unknown argument is refused"

"$CL_SH" --file "$FIXTURE/t.diff" --out "$FIXTURE/out.tsv" 2>/dev/null
[ -s "$FIXTURE/out.tsv" ] && pass "--out writes the list to a file" || fail "--out produced nothing"

echo
echo "Running mutants"

MR="$FIXTURE/mut"; mkdir -p "$MR/src" "$MR/tests" "$MR/elsewhere/src"
cat > "$MR/src/limits.py" <<'PY'
def over(n):
    return n >= 10

def unused(n):
    return n * 2
PY
cat > "$MR/tests/check.py" <<'PY'
import sys
sys.path.insert(0, "src")
import limits
assert limits.over(10) is True
assert limits.over(9) is False
PY
cp "$MR/src/limits.py" "$MR/elsewhere/src/limits.py"
printf '#!/bin/sh\npython3 tests/check.py\n' > "$MR/t.sh"
# Reads a DIFFERENT copy of the source: the editable-install trap in miniature.
printf '#!/bin/sh\ncd %s/elsewhere && python3 %s/tests/check.py\n' "$MR" "$MR" > "$MR/t_trap.sh"
printf '#!/bin/sh\nexit 1\n' > "$MR/t_red.sh"
printf '#!/bin/sh\nexec ./definitely-not-here\n' > "$MR/t_gone.sh"
chmod +x "$MR"/t*.sh
cat > "$MR/spec.txt" <<'SPEC'
file: src/limits.py
line: 2
find: >=
replace: >
desc: trip the boundary

file: src/limits.py
line: 5
find: * 2
replace: * 3
desc: the unused multiplier
SPEC
printf 'file: src/limits.py\nline: 5\nfind: * 2\nreplace: * 3\n' > "$MR/one.txt"

MR_ORIG=$(content_id "$MR/src/limits.py")
rm_run() { RM_OUT=$("$RM_SH" --root "$MR" "$@" 2>"$FIXTURE/rmerr.txt"); RM_RC=$?; RM_ERR=$(cat "$FIXTURE/rmerr.txt"); return 0; }
rm_expect() { # rc, slug, label
  local want=$1 slug=$2 label=$3
  if [ "$RM_RC" -ne "$want" ]; then fail "$label (expected exit $want, got $RM_RC)"
  elif ! printf '%s' "$RM_ERR" | grep -qF "refused: $slug"; then
    fail "$label (exit $want, but the slug was not '$slug')"
  else pass "$label"; fi
}

rm_run --spec "$MR/spec.txt" --test ./t.sh
if [ "$RM_RC" -eq 0 ] && printf '%s' "$RM_OUT" | grep -q '^killed .*limits.py:2' \
   && printf '%s' "$RM_OUT" | grep -q '^SURVIVED .*limits.py:5'; then
  pass "a covered line is killed and an uncovered one survives"
else
  fail "scoring wrong (exit $RM_RC):"; printf '%s\n' "$RM_OUT" | sed 's/^/          /' | head -4
fi

[ "$(content_id "$MR/src/limits.py")" = "$MR_ORIG" ] \
  && pass "the mutated file is restored — same content, same inode" \
  || fail "THE MUTATED FILE WAS NOT RESTORED"

# The result that must never be reported as coverage.
rm_run --spec "$MR/spec.txt" --test ./t_trap.sh
rm_expect 54 all-survived "every mutant surviving is refused, not reported as a gap"

# ...but ONE survivor cannot distinguish a gap from mis-wiring, so it is a finding.
rm_run --spec "$MR/one.txt" --test ./t.sh
[ "$RM_RC" -eq 0 ] && pass "a single survivor is reported, not refused" || fail "one survivor exited $RM_RC"

rm_run --spec "$MR/spec.txt" --test ./t_red.sh
rm_expect 53 baseline-red "a red baseline is refused before any mutant runs"
rm_run --spec "$MR/spec.txt" --test ./t_gone.sh
rm_expect 55 test-not-runnable "a --test that cannot run is breakage, not a kill"

rm_run --spec "$MR/spec.txt" --test ./t.sh --dry-run
if [ "$RM_RC" -eq 0 ] && [ "$(content_id "$MR/src/limits.py")" = "$MR_ORIG" ]; then
  pass "--dry-run resolves every mutant and changes nothing"
else
  fail "--dry-run exited $RM_RC or touched the file"
fi

# Every spec error must surface BEFORE a single test runs.
printf 'file: src/limits.py\nline: 2\nfind: NOT-THERE\nreplace: x\n' > "$MR/e1"
rm_run --spec "$MR/e1" --test ./t.sh; rm_expect 52 find-not-on-line "a find string absent from that line is refused"
printf 'file: src/limits.py\nline: 999\nfind: x\nreplace: y\n' > "$MR/e2"
rm_run --spec "$MR/e2" --test ./t.sh; rm_expect 52 line-out-of-range "a line past the end of the file is refused"
printf 'file: ../escape.py\nline: 1\nfind: x\nreplace: y\n' > "$MR/e3"
rm_run --spec "$MR/e3" --test ./t.sh; rm_expect 52 spec-dotdot-path "a path containing .. is refused"
printf 'file: /etc/hosts\nline: 1\nfind: x\nreplace: y\n' > "$MR/e4"
rm_run --spec "$MR/e4" --test ./t.sh; rm_expect 52 spec-absolute-path "an absolute path is refused"
printf 'file: src/limits.py\nline: two\nfind: x\nreplace: y\n' > "$MR/e5"
rm_run --spec "$MR/e5" --test ./t.sh; rm_expect 52 spec-bad-line "a non-numeric line is refused"
printf 'line: 2\nfind: x\nreplace: y\n' > "$MR/e6"
rm_run --spec "$MR/e6" --test ./t.sh; rm_expect 52 spec-no-file "a record with no file: is refused"
printf 'file: src/limits.py\nfind: x\nreplace: y\n' > "$MR/e6b"
rm_run --spec "$MR/e6b" --test ./t.sh; rm_expect 52 spec-no-line "a record with no line: is refused"
printf 'file: src/limits.py\nline: 2\nreplace: y\n' > "$MR/e6c"
rm_run --spec "$MR/e6c" --test ./t.sh; rm_expect 52 spec-no-find "a record with no find: is refused"
printf 'nonsense\n' > "$MR/e7"
rm_run --spec "$MR/e7" --test ./t.sh; rm_expect 52 spec-unparsed "an unparseable spec line is refused"
: > "$MR/e8"
rm_run --spec "$MR/e8" --test ./t.sh; rm_expect 52 spec-empty "an empty spec is refused"
printf 'file: nope.py\nline: 1\nfind: x\nreplace: y\n' > "$MR/e9"
rm_run --spec "$MR/e9" --test ./t.sh; rm_expect 52 no-such-target "a spec naming a missing file is refused"
rm_run --spec "$MR/definitely-not-there" --test ./t.sh; rm_expect 52 no-such-spec "a missing spec file is refused"
"$RM_SH" --root "$MR/nope" --spec "$MR/spec.txt" --test ./t.sh >/dev/null 2>"$FIXTURE/rmerr.txt"
RM_RC=$?; RM_ERR=$(cat "$FIXTURE/rmerr.txt"); rm_expect 52 no-such-root "a --root that does not exist is refused"

rm_run --test ./t.sh; rm_expect 50 no-spec "a missing --spec is refused"
rm_run --spec "$MR/spec.txt"; rm_expect 50 no-test "a missing --test is refused"
rm_run --spec "$MR/spec.txt" --test ./t.sh --bogus; rm_expect 50 unknown-argument "an unknown argument is refused"
rm_run --spec; rm_expect 50 spec-needs-value "--spec with no value is refused"
rm_run --spec "$MR/spec.txt" --test; rm_expect 50 test-needs-value "--test with no value is refused"
rm_run --spec "$MR/spec.txt" --test ./t.sh --root; rm_expect 50 root-needs-value "--root with no value is refused"

# find/replace are LITERAL. A regex-minded implementation would treat '.' and
# '*' as metacharacters and mutate the wrong text.
printf 'x = "a.b" + "axb"\n' > "$MR/src/literal.py"
printf 'file: src/literal.py\nline: 1\nfind: a.b\nreplace: ZZZ\n' > "$MR/lit.txt"
"$RM_SH" --root "$MR" --spec "$MR/lit.txt" --test ./t.sh --dry-run >/dev/null 2>&1 \
  && pass "find is matched literally, not as a pattern" \
  || fail "a literal find containing '.' was not resolved"
rm -f "$MR/src/literal.py" "$MR/lit.txt"

echo
if [ "$fail_n" -eq 0 ]; then echo "PASS — $pass_n assertion(s)"; exit 0; fi
echo "FAIL — $fail_n failure(s), $pass_n passed"
exit 1
