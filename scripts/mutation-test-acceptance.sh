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

# Content and mode, deliberately WITHOUT the inode. Both the apply and the
# restore put the file in place by renaming, which is what makes them atomic --
# and a rename necessarily gives the path a new inode. What the runner promises
# is that the BYTES and the MODE come back, not that the identity survives.
#
# content_id, which does include the inode, passed on Linux anyway: the original
# inode is freed by the first rename and the kernel handed the same number back
# for the second temp file. On APFS it does not, so the macOS runner failed
# every restore assertion while Linux reported them green -- an assertion that
# was measuring the wrong thing and only accidentally agreeing with the right
# one. Keep content_id for the cases that assert a file was never written.
restored_id() { python3 -c "
import hashlib,os,sys
p=sys.argv[1]; st=os.lstat(p)
print(f'{st.st_mode:o}:{st.st_size}:{hashlib.sha256(open(p,\"rb\").read()).hexdigest()}')" "$1"; }

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
printf 'diff --git a/src/auth.py b/src/auth.py\n--- a/src/auth.py\n+++ b/src/auth.py\n@@ -10,1 +10,4 @@\n context\n+# note:\n+++ b/README.md\n+    tok = "letmein"\n' > "$FIXTURE/inject.diff"
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
printf 'diff --git a/src/auth.py b/src/auth.py\n--- a/src/auth.py\n+++ b/src/auth.py\n@@ -10,2 +10,4 @@\n context\n--- legacy sql comment\n+++ b/README.md\n+    tok = "letmein"\n+    passwd = "hunter2"\n@@ -40,1 +41,2 @@\n other\n+    another_secret = 1\n' > "$FIXTURE/rearm.diff"
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

# A hunk left open at EOF means the declared lengths did not match the content:
# a truncated or hand-edited patch, whose line numbers past that point are a
# guess. This caught two fixtures in this very suite when it was added.
printf 'diff --git a/x.py b/x.py\n--- a/x.py\n+++ b/x.py\n@@ -1,5 +1,9 @@\n ctx\n+one\n' > "$FIXTURE/trunc.diff"
CL_ERR=$("$CL_SH" --file "$FIXTURE/trunc.diff" 2>&1 >/dev/null); CL_RC=$?
cl_expect 42 malformed-diff "a hunk claiming more lines than it contains is refused, not guessed at"
echo
if [ "$fail_n" -eq 0 ]; then echo "PASS — $pass_n assertion(s)"; exit 0; fi
echo "FAIL — $fail_n failure(s), $pass_n passed"
exit 1
