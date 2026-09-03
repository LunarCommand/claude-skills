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

# --untracked-ok is an acknowledgement list, not a bypass: naming one path must
# not excuse another. The unnamed one is the case that matters -- a test you
# forgot about, whose absence from the worktree makes every mutant survive.
printf 'notes\n' > "$REPO/scratch-note.md"
"$WT_SH" run --repo "$REPO" --test ./run_correct.sh -- true >/dev/null 2>&1; UOK_BARE_RC=$?
"$WT_SH" run --repo "$REPO" --test ./run_correct.sh --untracked-ok scratch-note.md -- true >/dev/null 2>&1; UOK_ACK_RC=$?
printf 'import sys\n' > "$REPO/tests/test_forgotten.py"
UOK_PARTIAL_ERR=$("$WT_SH" run --repo "$REPO" --test ./run_correct.sh --untracked-ok scratch-note.md -- true 2>&1 >/dev/null); UOK_PARTIAL_RC=$?
UOK_STALE_ERR=$("$WT_SH" run --repo "$REPO" --test ./run_correct.sh \
  --untracked-ok scratch-note.md --untracked-ok tests/test_forgotten.py --untracked-ok never-existed.md -- true 2>&1 >/dev/null); UOK_STALE_RC=$?
rm -f "$REPO/scratch-note.md" "$REPO/tests/test_forgotten.py"

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
  { [ "$rc" -eq 40 ] && printf '%s' "$err" | grep -qF 'mutation_test_worktree: refused: removed-subcommand'; } \
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
if [ "$DIRTY_RC" -eq 44 ] && printf '%s' "$DIRTY_ERR" | grep -qF 'mutation_test_worktree: refused: dirty-tree'; then
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
if [ "$UNTRACKED_RC" -eq 44 ] && printf '%s' "$UNTRACKED_ERR" | grep -qF 'mutation_test_worktree: refused: untracked-files'; then
  pass "a brand-new UNTRACKED test file is refused by its own slug"
else
  fail "untracked test file not refused (exit $UNTRACKED_RC) — the worktree would not contain it"
fi
if [ "$UOK_BARE_RC" -eq 44 ] && [ "$UOK_ACK_RC" -eq 0 ]; then
  pass "--untracked-ok acknowledges the path it names"
else
  fail "--untracked-ok did not work (bare $UOK_BARE_RC, acknowledged $UOK_ACK_RC)"
fi
if [ "$UOK_PARTIAL_RC" -eq 44 ] && printf '%s' "$UOK_PARTIAL_ERR" | grep -qF 'test_forgotten.py' \
   && ! printf '%s' "$UOK_PARTIAL_ERR" | grep -qF 'scratch-note.md'; then
  pass "an UNNAMED untracked path still refuses, and only it is named"
else
  fail "--untracked-ok excused a path it was not given (exit $UOK_PARTIAL_RC)"
fi
if [ "$UOK_STALE_RC" -eq 0 ] && printf '%s' "$UOK_STALE_ERR" | grep -qF 'acknowledgement did nothing'; then
  pass "a stale acknowledgement is reported, not refused"
else
  fail "a stale --untracked-ok was not reported (exit $UOK_STALE_RC)"
fi
# Direct call: run_wt appends "-- true", which --untracked-ok would eat as its
# value, so the missing-value branch would never be reached.
run_raw run --repo "$REPO" --test ./run_correct.sh --untracked-ok
expect 40 untracked-ok-needs-value "--untracked-ok with no value is refused"

if [ "$HIDDEN_RC" -eq 44 ] && printf '%s' "$HIDDEN_ERR" | grep -qF 'mutation_test_worktree: refused: hidden-index-bits'; then
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
CL_ERR=$("$CL_SH" --suffix 2>&1 >/dev/null); CL_RC=$?
cl_expect 40 suffix-needs-value "--suffix with no value is refused"
CL_ERR=$("$CL_SH" --bogus </dev/null 2>&1 >/dev/null); CL_RC=$?
cl_expect 40 unknown-argument "an unknown argument is refused"

# It must not open a file for writing at all: a permission rule pre-approving
# this script would otherwise pre-approve truncating any path a caller named.
CL_ERR=$("$CL_SH" --file "$FIXTURE/t.diff" --out "$FIXTURE/should-not-exist.tsv" 2>&1 >/dev/null); CL_RC=$?
if [ "$CL_RC" -eq 40 ] && [ ! -e "$FIXTURE/should-not-exist.tsv" ]; then
  pass "--out is gone: the script cannot be told to write a file"
else
  fail "--out still exists or created a file (exit $CL_RC)"
fi

# The diff is written by the author of the PR under review. An added line
# reading `++ foo` renders as `+++ foo`, so matching `^+++ ` anywhere let that
# author reassign their own later lines to a path of their choosing: the line
# went unmutated and unreported while the count still read as a full inventory.
printf 'diff --git a/src/auth.py b/src/auth.py\n--- a/src/auth.py\n+++ b/src/auth.py\n@@ -10,2 +10,4 @@\n context\n+# note:\n+++ b/README.md\n+    tok = "letmein"\n' > "$FIXTURE/inject.diff"
CL_OUT=$("$CL_SH" --file "$FIXTURE/inject.diff" 2>/dev/null)
if printf '%s' "$CL_OUT" | grep -q 'README.md'; then
  fail "an added line beginning '++ ' was read as a header and re-attributed the lines after it"
else
  pass "added content cannot re-attribute later lines to another path"
fi
printf '%s' "$CL_OUT" | grep -q 'src/auth.py	13' \
  && pass "the line that injection hid is still reported, under its real path" \
  || fail "the injected hunk lost a line entirely"

# The first fix for the above used a "saw --- last" flag, which the same author
# could re-arm: DELETE a line whose text begins `-- ` (an SQL or Lua comment, a
# signature delimiter) and it renders as `--- `, so the next `+++ ` was read as
# a header again. That was worse than the original -- the hunk's added lines
# were dropped from the inventory rather than misfiled.
printf 'diff --git a/src/auth.py b/src/auth.py\n--- a/src/auth.py\n+++ b/src/auth.py\n@@ -10,4 +10,5 @@\n context\n--- legacy sql comment\n+++ b/README.md\n+    tok = "letmein"\n+    passwd = "hunter2"\n@@ -40,1 +41,2 @@\n other\n+    another_secret = 1\n' > "$FIXTURE/rearm.diff"
CL_OUT=$("$CL_SH" --file "$FIXTURE/rearm.diff" 2>/dev/null)
if printf '%s' "$CL_OUT" | grep -q 'README.md'; then
  fail "a deleted line beginning '-- ' re-armed the header branch"
else
  pass "a deleted line beginning '-- ' cannot re-arm the header branch"
fi
# 11, 12 and 13 are the three added lines of hunk one (the spoofed header IS an
# added line); 42 is the added line of hunk two.
for want in 11 12 13 42; do
  printf '%s' "$CL_OUT" | grep -q "src/auth.py	$want" \
    || fail "the re-arm spoof lost src/auth.py:$want"
done
[ "$(printf '%s' "$CL_OUT" | grep -c 'src/auth.py')" -eq 4 ] \
  && pass "every added line of the spoofed diff is reported under its real path" \
  || fail "wrong line count for the re-arm spoof"

echo
echo "Running mutants"

# The runner REFUSES to run outside a linked worktree, so every case here is in
# one. Most go through mutation_test_worktree.sh, which makes a THROWAWAY one --
# the recommended form, and what the standalone mode it used to have was
# replaced by after two data-loss defects lived in that mode's restore path.
# Some cases below run the runner directly inside a worktree the suite builds,
# which is also supported and is what SKILL.md recommends for a cheap --dry-run.
MREPO="$FIXTURE/mrepo"; mkdir -p "$MREPO/src"
cat > "$MREPO/src/limits.py" <<'PY'
def over(n):
    return n >= 10

def unused(n):
    return n * 2
PY
printf 'import sys\nsys.path.insert(0,"src")\nimport limits\nassert limits.over(10) is True\nassert limits.over(9) is False\n' > "$MREPO/check.py"
printf '#!/bin/sh\npython3 check.py\n' > "$MREPO/t.sh"
# Reads a DIFFERENT copy of the source: the editable-install trap in miniature.
mkdir -p "$FIXTURE/elsewhere/src"
printf '#!/bin/sh\ncd %s/elsewhere && python3 %s/check.py\n' "$FIXTURE" "$MREPO" > "$MREPO/t_trap.sh"
printf '#!/bin/sh\nexit 1\n' > "$MREPO/t_red.sh"
printf '#!/bin/sh\nexec ./definitely-not-here\n' > "$MREPO/t_gone.sh"
chmod +x "$MREPO"/t*.sh
git -C "$MREPO" init -q
git -C "$MREPO" config user.email "acceptance@example.invalid"
git -C "$MREPO" config user.name  "acceptance"
git -C "$MREPO" add -A; git -C "$MREPO" commit -qm fixture
cp "$MREPO/src/limits.py" "$FIXTURE/elsewhere/src/limits.py"

# Specs live OUTSIDE the repository: an untracked file is not in the worktree.
SPECD="$FIXTURE/specs"; mkdir -p "$SPECD"
printf 'src/limits.py\t2\t>=\t>\ttrip the boundary\nsrc/limits.py\t5\t* 2\t* 3\tthe unused multiplier\n' > "$SPECD/two.tsv"
printf 'src/limits.py\t5\t* 2\t* 3\n' > "$SPECD/one.tsv"

MREPO_ORIG=$(content_id "$MREPO/src/limits.py")
# Every runner case runs through the worktree layer, which is the only
# supported way to invoke it.
rm_run() { # spec, test-cmd
  RM_OUT=$( cd "$MREPO" && "$WT_SH" run --test "$2" -- "$RM_SH" --spec "$1" --test "$2" 2>"$FIXTURE/rmerr.txt" )
  RM_RC=$?
  RM_ERR=$(cat "$FIXTURE/rmerr.txt")
  return 0
}
rm_expect() { # rc, slug, label
  local want=$1 slug=$2 label=$3
  if [ "$RM_RC" -ne "$want" ]; then fail "$label (expected exit $want, got $RM_RC)"
  elif ! printf '%s' "$RM_ERR" | grep -qF "refused: $slug"; then
    fail "$label (exit $want, but the slug was not '$slug')"
  else pass "$label"; fi
}

rm_run "$SPECD/two.tsv" ./t.sh
if [ "$RM_RC" -eq 0 ] && printf '%s' "$RM_OUT" | grep -q '^killed .*limits.py:2' \
   && printf '%s' "$RM_OUT" | grep -q '^SURVIVED .*limits.py:5'; then
  pass "a covered line is killed and an uncovered one survives"
else
  fail "scoring wrong (exit $RM_RC):"; printf '%s\n' "$RM_OUT" | sed 's/^/          /' | head -4
fi
[ "$(content_id "$MREPO/src/limits.py")" = "$MREPO_ORIG" ] \
  && pass "the real repository's file is untouched" || fail "THE REAL FILE WAS MODIFIED"

# The safety property, enforced rather than documented.
STANDALONE_ERR=$( cd "$MREPO" && "$RM_SH" --spec "$SPECD/two.tsv" --test ./t.sh 2>&1 >/dev/null ); STANDALONE_RC=$?
if [ "$STANDALONE_RC" -eq 52 ] && printf '%s' "$STANDALONE_ERR" | grep -qF 'mutation_test_run_mutants: refused: main-worktree'; then
  pass "the runner REFUSES to run in a main working tree"
else
  fail "the runner ran outside a worktree (exit $STANDALONE_RC)"
fi

rm_run "$SPECD/two.tsv" ./t_trap.sh
rm_expect 54 all-survived "with no control, every mutant surviving is refused"

# A control settles what that heuristic can only guess. UAT found the heuristic
# firing on genuinely untested code — four mutants on lines a coverage report
# independently called uncovered — which is a false alarm on exactly the code
# this tool is pointed at. A control proves the wiring instead.
#
# Line 2 of the fixture is covered by t.sh and line 5 is not, so a mutant on 2
# dies and a mutant on 5 lives. Every case below is built from that pair.
printf 'src/limits.py\t2\t>=\t>\tcovered, so this must die\tcontrol\nsrc/limits.py\t5\t* 2\t* 3\tuncovered\n' > "$SPECD/ctrl.tsv"
rm_run "$SPECD/ctrl.tsv" ./t.sh
# Deliberately labelled for what it proves and no more. It does NOT prove the
# refusal was suppressed: a killed control implies killed>=1, and the fallback
# heuristic only fires when killed==0, so there was never a refusal here to
# suppress. Claiming otherwise is what the previous label did, and deleting the
# whole control branch left it green.
if [ "$RM_RC" -eq 0 ] && printf '%s' "$RM_OUT" | grep -q 'SURVIVED'; then
  pass "a six-field record parses, runs, and reports its survivor"
else
  fail "a killed control plus a survivor did not report cleanly (exit $RM_RC)"
fi
printf '%s' "$RM_OUT" | grep -q 'killed\*' \
  && pass "the control is marked in the output" || fail "the control was not marked"

# THE RULE, and the assertion that can actually fail: anything killed proves the
# tests see this checkout, so a surviving control is a wrong guess about
# coverage, not a broken environment — report it, do not refuse. The previous
# code refused here on ctrl_killed==0 without consulting killed, so this case
# exited 54 and threw away a report the same run had just proven sound.
printf 'src/limits.py\t5\t* 2\t* 3\tI believed this was covered\tcontrol\nsrc/limits.py\t2\t>=\t>\treal mutant\n' > "$SPECD/ctrlsurv.tsv"
rm_run "$SPECD/ctrlsurv.tsv" ./t.sh
if [ "$RM_RC" -eq 0 ]; then
  pass "a surviving control beside a killed mutant is reported, not refused"
else
  fail "a surviving control refused despite a kill in the same run (exit $RM_RC)"
fi
printf '%s' "$RM_ERR" | grep -q "NOTE: you marked these lines 'control'" \
  && pass "the surviving control is named rather than passed off as a coverage gap" \
  || fail "no NOTE naming the surviving control"

# Two controls, one each way. Nothing constrained the count, and the docs said
# flatly that a surviving control refuses — false for this spec under the old
# code, which asked only whether EVERY control survived.
printf 'src/limits.py\t2\t>=\t>\tcovered\tcontrol\nsrc/limits.py\t5\t* 2\t* 3\tbelieved covered\tcontrol\n' > "$SPECD/twoctrl.tsv"
rm_run "$SPECD/twoctrl.tsv" ./t.sh
if [ "$RM_RC" -eq 0 ] && printf '%s' "$RM_ERR" | grep -q "NOTE: you marked these lines 'control'"; then
  pass "with two controls, one killed and one surviving, the run reports and says so"
else
  fail "one-killed-one-surviving controls did not report with a NOTE (exit $RM_RC)"
fi

# ...and a control that survives with NOTHING killed is the strong signal.
printf 'src/limits.py\t5\t* 2\t* 3\tI wrongly believed this was covered\tcontrol\n' > "$SPECD/badctrl.tsv"
rm_run "$SPECD/badctrl.tsv" ./t.sh
rm_expect 54 control-survived "a control that survives with nothing killed is refused"

printf 'src/limits.py\t2\t>=\t>\tdesc\tcontrl\n' > "$SPECD/typoctrl.tsv"
rm_run "$SPECD/typoctrl.tsv" ./t.sh
rm_expect 52 spec-bad-control "a misspelled sixth field is refused, not ignored"

# `control` is the SIXTH field. Writing it fifth is how you believe you marked a
# control and did not: it parsed as the description, the run lost its only
# wiring evidence, and it reported a confident coverage gap with exit 0.
printf 'src/limits.py\t5\t* 2\t* 3\tcontrol\n' > "$SPECD/fifthctrl.tsv"
rm_run "$SPECD/fifthctrl.tsv" ./t.sh
rm_expect 52 spec-control-needs-desc "'control' in the fifth field is refused, not read as a description"
# The sixth-field check refuses every near-miss, so the fifth-field guard has to
# be at least as loose or the strictness is backwards: capitalising, or padding
# while aligning columns, silently produced the outcome it exists to prevent.
for variant in 'Control' 'CONTROL' 'control '; do
  printf 'src/limits.py\t5\t* 2\t* 3\t%s\n' "$variant" > "$SPECD/fifthvar.tsv"
  rm_run "$SPECD/fifthvar.tsv" ./t.sh
  rm_expect 52 spec-control-needs-desc "'$variant' in the fifth field is refused too"
done

# A spec written on Windows put a CR on the last field, so the refusal read
# "must be the word 'control', not 'control'" — two strings that render alike.
printf 'src/limits.py\t2\t>=\t>\tdesc\tcontrol\r\n' > "$SPECD/crlf.tsv"
rm_run "$SPECD/crlf.tsv" ./t.sh
[ "$RM_RC" -ne 52 ] \
  && pass "a CRLF spec is not refused for an invisible carriage return" \
  || fail "a CRLF spec was refused (exit $RM_RC): $RM_ERR"
rm_run "$SPECD/one.tsv" ./t.sh
[ "$RM_RC" -eq 0 ] && pass "a single surviving line is reported, not refused" || fail "one survivor exited $RM_RC"
# The worktree layer refuses a red or unrunnable --test before the runner ever
# starts, which is correct but leaves the runner's OWN checks unexercised. They
# still matter: someone can make a worktree themselves. So these cases go
# through a worktree the suite builds directly.
rm_direct() { # spec, test-cmd
  local wt; wt=$(mktemp -d "$FIXTURE/directwt.XXXXXX"); rmdir "$wt"
  git -C "$MREPO" worktree add --detach "$wt" HEAD >/dev/null 2>&1
  RM_OUT=$( cd "$wt" && "$RM_SH" --spec "$1" --test "$2" 2>"$FIXTURE/rmerr.txt" )
  RM_RC=$?
  RM_ERR=$(cat "$FIXTURE/rmerr.txt")
  git -C "$MREPO" worktree remove --force "$wt" >/dev/null 2>&1; rm -rf "$wt"
  return 0
}
rm_direct "$SPECD/two.tsv" ./t_red.sh
rm_expect 53 baseline-red "the runner's own red-baseline check refuses"
printf '%s' "$RM_ERR" | grep -qF -- '--- test output ---' \
  && pass "a red baseline shows the test output" || fail "baseline-red printed no diagnostic"
rm_direct "$SPECD/two.tsv" ./t_gone.sh
rm_expect 55 test-not-runnable "a --test that cannot run is breakage, not a kill"

# One line per mutant: the old blank-line-separated format could silently merge
# two records into one, which also dropped the run below the all-survived floor.
printf 'src/limits.py 2 >= >\n' > "$SPECD/spaces.tsv"
rm_run "$SPECD/spaces.tsv" ./t.sh; rm_expect 52 spec-fields "a line without tabs is refused"
printf 'src/limits.py\t2\t>=\n' > "$SPECD/short.tsv"
rm_run "$SPECD/short.tsv" ./t.sh; rm_expect 52 spec-fields "too few fields is refused"
printf 'src/limits.py\t2\t>=\t>=\n' > "$SPECD/noop.tsv"
rm_run "$SPECD/noop.tsv" ./t.sh; rm_expect 52 no-op-mutant "find identical to replace is refused"
printf 'src/limits.py\ttwo\t>=\t>\n' > "$SPECD/badline.tsv"
rm_run "$SPECD/badline.tsv" ./t.sh; rm_expect 52 spec-bad-line "a non-numeric line is refused"
printf 'src/limits.py\t999\t>=\t>\n' > "$SPECD/range.tsv"
rm_run "$SPECD/range.tsv" ./t.sh; rm_expect 52 line-out-of-range "a line past the end is refused"
printf 'src/limits.py\t2\tNOT-THERE\tx\n' > "$SPECD/absent.tsv"
rm_run "$SPECD/absent.tsv" ./t.sh; rm_expect 52 find-not-on-line "a find absent from that line is refused"
printf '../escape.py\t1\tx\ty\n' > "$SPECD/dotdot.tsv"
rm_run "$SPECD/dotdot.tsv" ./t.sh; rm_expect 52 spec-dotdot-path "a path containing .. is refused"
printf '/etc/hosts\t1\tx\ty\n' > "$SPECD/abs.tsv"
rm_run "$SPECD/abs.tsv" ./t.sh; rm_expect 52 spec-absolute-path "an absolute path is refused"
printf 'nope.py\t1\tx\ty\n' > "$SPECD/missing.tsv"
rm_run "$SPECD/missing.tsv" ./t.sh; rm_expect 52 no-such-target "a spec naming a missing file is refused"
printf '\n# only a comment\n' > "$SPECD/empty.tsv"
rm_run "$SPECD/empty.tsv" ./t.sh; rm_expect 52 spec-empty "a spec with no mutants is refused"
rm_run "$SPECD/definitely-not-there" ./t.sh; rm_expect 52 no-such-spec "a missing spec file is refused"

# A symlinked target would carry the write outside the worktree — the one
# boundary this design rests on.
printf 'x = 1\n' > "$FIXTURE/outside-target.py"
( cd "$MREPO" && ln -sf "$FIXTURE/outside-target.py" symlink.py && git add -A && git commit -qm symlink >/dev/null )
printf 'symlink.py\t1\tx\ty\n' > "$SPECD/link.tsv"
rm_run "$SPECD/link.tsv" ./t.sh; rm_expect 52 symlink-target "a symlinked target is refused"
[ "$(cat "$FIXTURE/outside-target.py")" = "x = 1" ] \
  && pass "the file the symlink pointed at is untouched" || fail "A FILE OUTSIDE THE WORKTREE WAS MUTATED"

# An empty replace deletes the token, which is a legitimate mutation and must
# not be confused with a missing field.
printf 'src/limits.py\t2\t>= 10\t\tdelete the comparison\n' > "$SPECD/del.tsv"
rm_run "$SPECD/del.tsv" ./t.sh
[ "$RM_RC" -eq 0 ] && printf '%s' "$RM_OUT" | grep -q '^killed' \
  && pass "an empty replace deletes the token and is scored" || fail "an empty replace was not handled (exit $RM_RC)"

# A file with no trailing newline must not gain one: that would make the mutant
# differ from the original by more than the edit.
printf 'def g():\n    return 5' > "$MREPO/src/nonl.py"
( cd "$MREPO" && git add -A && git commit -qm nonl >/dev/null )
NONL_ORIG=$(content_id "$MREPO/src/nonl.py")
printf 'src/nonl.py\t2\t5\t6\n' > "$SPECD/nonl.tsv"
rm_run "$SPECD/nonl.tsv" ./t.sh
[ "$(content_id "$MREPO/src/nonl.py")" = "$NONL_ORIG" ] \
  && pass "a file with no trailing newline is left exactly as it was" \
  || fail "the no-trailing-newline file was altered"

rm_run "$SPECD/two.tsv" ./t.sh --dry-run 2>/dev/null
RM_OUT=$( cd "$MREPO" && "$WT_SH" run --test ./t.sh -- "$RM_SH" --spec "$SPECD/two.tsv" --test ./t.sh --dry-run 2>"$FIXTURE/rmerr.txt" )
[ "$?" -eq 0 ] && printf '%s' "$RM_OUT" | grep -q 'limits.py:2' \
  && pass "--dry-run lists every mutant" || fail "--dry-run did not list the mutants"
# Whether a control registered is the one thing a dry run has to show, and it
# showed nothing: the spec that mis-slotted `control` into the description
# listed a mutant described as "control", reading as confirmation of the very
# thing that had failed to happen.
printf '%s' "$(cat "$FIXTURE/rmerr.txt")" | grep -q 'No control in this spec' \
  && pass "--dry-run says when a spec has no control, and what that will cost" \
  || fail "--dry-run did not warn about the missing control"
RM_OUT=$( cd "$MREPO" && "$WT_SH" run --test ./t.sh -- "$RM_SH" --spec "$SPECD/ctrl.tsv" --test ./t.sh --dry-run 2>"$FIXTURE/rmerr.txt" )
printf '%s' "$RM_OUT" | grep -q '^\* src/limits.py:2' \
  && pass "--dry-run marks which mutants are controls" || fail "--dry-run did not mark the control"
printf '%s' "$(cat "$FIXTURE/rmerr.txt")" | grep -q '1 marked control' \
  && pass "--dry-run counts the controls it found" || fail "--dry-run did not count the controls"

# A linked worktree is not necessarily a THROWAWAY one — the `/worktrees/` guard
# cannot tell a scratch checkout from a long-lived worktree someone keeps work
# in — and restore is a whole-file `git checkout --`, which discards uncommitted
# edits along with the mutation. SKILL.md briefly told readers to run the runner
# in "a worktree you already have"; following that sentence destroyed real work.
DIRTYWT=$(mktemp -d "$FIXTURE/dirtywt.XXXXXX"); rmdir "$DIRTYWT"
git -C "$MREPO" worktree add --detach "$DIRTYWT" HEAD >/dev/null 2>&1
printf '\n# uncommitted work nobody wants to lose\n' >> "$DIRTYWT/src/limits.py"
DIRTY_BEFORE=$(content_id "$DIRTYWT/src/limits.py")
RM_ERR=$( cd "$DIRTYWT" && "$RM_SH" --spec "$SPECD/two.tsv" --test ./t.sh 2>&1 >/dev/null ); RM_RC=$?
rm_expect 52 dirty-target "a target carrying uncommitted work is refused, not quietly restored over"
[ "$(content_id "$DIRTYWT/src/limits.py")" = "$DIRTY_BEFORE" ] \
  && pass "that uncommitted work is still there afterwards" \
  || fail "the runner altered work in a tree it refused to mutate"
# ...but a DRY run writes nothing and restores nothing, so refusing there breaks
# the one cheap way to check a spec for typos -- in exactly the worktree the
# docs recommend it for.
RM_OUT=$( cd "$DIRTYWT" && "$RM_SH" --spec "$SPECD/two.tsv" --test ./t.sh --dry-run 2>"$FIXTURE/rmerr.txt" ); RM_RC=$?
{ [ "$RM_RC" -eq 0 ] && printf '%s' "$RM_OUT" | grep -q 'limits.py:2'; } \
  && pass "a dry run against a dirty target is allowed, and lists the mutants" \
  || fail "a dry run against a dirty target was refused (exit $RM_RC)"

# git resolves a pathspec against the CURRENT DIRECTORY, but every path here is
# relative to the worktree ROOT. Run from a subdirectory, the guard matched
# nothing and went silent -- while the mutation still landed, because it is
# written through an absolute path. The restore missed for the same reason, so
# a CLEAN worktree was left with every mutant applied.
mkdir -p "$DIRTYWT/sub"
RM_ERR=$( cd "$DIRTYWT/sub" && "$RM_SH" --spec "$SPECD/two.tsv" --test ./t.sh 2>&1 >/dev/null ); RM_RC=$?
rm_expect 52 dirty-target "the guard still fires when the runner is invoked from a subdirectory"
[ "$(content_id "$DIRTYWT/src/limits.py")" = "$DIRTY_BEFORE" ] \
  && pass "and the uncommitted work survives a subdirectory invocation" \
  || fail "a subdirectory invocation altered the uncommitted work"
git -C "$MREPO" worktree remove --force "$DIRTYWT" >/dev/null 2>&1; rm -rf "$DIRTYWT"

# `git checkout -- <path>` can only restore a path git TRACKS, so an untracked
# target is unrestorable by construction. `git diff --quiet HEAD -- <untracked>`
# exits 0, so the dirty-target guard was blind to it: the runner mutated the
# file, the restore failed with a warning, and it refused `mutant-had-no-effect`
# -- a message asserting the file was unchanged, moments after overwriting it.
# An unadded module is the archetypal target for this tool.
UNTRWT=$(mktemp -d "$FIXTURE/untrwt.XXXXXX"); rmdir "$UNTRWT"
git -C "$MREPO" worktree add --detach "$UNTRWT" HEAD >/dev/null 2>&1
printf 'x = 1\ny = 2 >= 3\nz = 4\n' > "$UNTRWT/src/new_feature.py"
UNTR_BEFORE=$(content_id "$UNTRWT/src/new_feature.py")
printf 'src/new_feature.py\t2\t>=\t>\tnever added\n' > "$SPECD/untracked.tsv"
RM_ERR=$( cd "$UNTRWT" && "$RM_SH" --spec "$SPECD/untracked.tsv" --test ./t.sh 2>&1 >/dev/null ); RM_RC=$?
rm_expect 52 untracked-target "an untracked target is refused: git checkout could never restore it"
[ "$(content_id "$UNTRWT/src/new_feature.py")" = "$UNTR_BEFORE" ] \
  && pass "the untracked file is byte-identical afterwards" \
  || fail "the runner overwrote an untracked file it cannot restore"
git -C "$MREPO" worktree remove --force "$UNTRWT" >/dev/null 2>&1; rm -rf "$UNTRWT"

# Reachable, despite having been exempted as "requires an edit that changes
# bytes yet leaves git diff empty" -- which is what --assume-unchanged does.
# That exemption forbade the suite from covering the slug at all.
AUWT=$(mktemp -d "$FIXTURE/auwt.XXXXXX"); rmdir "$AUWT"
git -C "$MREPO" worktree add --detach "$AUWT" HEAD >/dev/null 2>&1
git -C "$AUWT" update-index --assume-unchanged src/limits.py
AU_BEFORE=$(content_id "$AUWT/src/limits.py")
RM_ERR=$( cd "$AUWT" && "$RM_SH" --spec "$SPECD/two.tsv" --test ./t.sh 2>&1 >/dev/null ); RM_RC=$?
rm_expect 52 mutant-had-no-effect "a target git has been told to ignore is refused, not scored"
[ "$(content_id "$AUWT/src/limits.py")" = "$AU_BEFORE" ] \
  && pass "and that file is restored byte-for-byte" \
  || fail "an assume-unchanged target was left mutated"
git -C "$MREPO" worktree remove --force "$AUWT" >/dev/null 2>&1; rm -rf "$AUWT"

# The two halves of the worktree requirement, each by its own slug.
STANDALONE_ERR=$( cd "$FIXTURE" && "$RM_SH" --spec "$SPECD/two.tsv" --test true 2>&1 >/dev/null ); STANDALONE_RC=$?
{ [ "$STANDALONE_RC" -eq 52 ] && printf '%s' "$STANDALONE_ERR" | grep -qF 'mutation_test_run_mutants: refused: not-a-worktree'; } \
  && pass "outside a git tree entirely, the runner refuses" || fail "non-repo invocation exited $STANDALONE_RC"

printf 'src/limits.py\t2\t>=\t>\n' > "$SPECD/nofile.tsv"
printf '\t2\t>=\t>\n' > "$SPECD/emptyfile.tsv"
rm_direct "$SPECD/emptyfile.tsv" ./t.sh; rm_expect 52 spec-no-file "an empty file field is refused"
printf 'src/limits.py\t2\t\t>\n' > "$SPECD/emptyfind.tsv"
rm_direct "$SPECD/emptyfind.tsv" ./t.sh; rm_expect 52 spec-no-find "an empty find field is refused"
RAW_ERR=$( cd "$MREPO" && "$WT_SH" run --test ./t.sh -- "$RM_SH" --spec 2>&1 >/dev/null ); RAW_RC=$?
{ [ "$RAW_RC" -eq 50 ] && printf '%s' "$RAW_ERR" | grep -qF 'mutation_test_run_mutants: refused: spec-needs-value'; } \
  && pass "--spec with no value is refused" || fail "--spec with no value exited $RAW_RC"
RAW_ERR=$( cd "$MREPO" && "$WT_SH" run --test ./t.sh -- "$RM_SH" --spec "$SPECD/two.tsv" --test 2>&1 >/dev/null ); RAW_RC=$?
{ [ "$RAW_RC" -eq 50 ] && printf '%s' "$RAW_ERR" | grep -qF 'mutation_test_run_mutants: refused: test-needs-value'; } \
  && pass "--test with no value is refused" || fail "--test with no value exited $RAW_RC"

RAW_ERR=$( cd "$MREPO" && "$WT_SH" run --test ./t.sh -- "$RM_SH" --test ./t.sh 2>&1 >/dev/null ); RAW_RC=$?
{ [ "$RAW_RC" -eq 50 ] && printf '%s' "$RAW_ERR" | grep -qF 'mutation_test_run_mutants: refused: no-spec'; } \
  && pass "a missing --spec is refused" || fail "missing --spec exited $RAW_RC"
RAW_ERR=$( cd "$MREPO" && "$WT_SH" run --test ./t.sh -- "$RM_SH" --spec "$SPECD/two.tsv" 2>&1 >/dev/null ); RAW_RC=$?
{ [ "$RAW_RC" -eq 50 ] && printf '%s' "$RAW_ERR" | grep -qF 'mutation_test_run_mutants: refused: no-test'; } \
  && pass "a missing --test is refused" || fail "missing --test exited $RAW_RC"
RAW_ERR=$( cd "$MREPO" && "$WT_SH" run --test ./t.sh -- "$RM_SH" --spec "$SPECD/two.tsv" --test ./t.sh --bogus 2>&1 >/dev/null ); RAW_RC=$?
{ [ "$RAW_RC" -eq 50 ] && printf '%s' "$RAW_ERR" | grep -qF 'mutation_test_run_mutants: refused: unknown-argument'; } \
  && pass "an unknown argument is refused" || fail "unknown argument exited $RAW_RC"

echo
if [ "$fail_n" -eq 0 ]; then echo "PASS — $pass_n assertion(s)"; exit 0; fi
echo "FAIL — $fail_n failure(s), $pass_n passed"
exit 1
