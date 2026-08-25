#!/usr/bin/env bash
# mutation-test-acceptance.sh — behavioural tests for mutation_test_worktree.sh.
#
# Everything else in scripts/validate.sh is syntactic. This file runs the
# artifact and asserts on what it does.
#
# Two earlier versions of this file passed while the script under test deleted
# repositories. The reasons are worth keeping in view, because they are the
# design rules here:
#
#   * an assertion must be able to KILL the guard it names. Six assertions in
#     the last version could not: three destroy guards, the containment block,
#     the breakage check, and — worst — the "file outside the repo untouched"
#     check, which compared content that every code path restored before it ran.
#   * feed each guard the thing it refuses, not a thing something else refuses.
#   * assert on the REASON, not just the exit code.
#   * do not filter away your own evidence. The previous version excluded
#     .stamp and .bootstrapped from the arrived-files check; those are precisely
#     the two files whose presence in the source tree would prove a command
#     escaped the worktree.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
WT_SH="$REPO_ROOT/skills/mutation-test/bin/mutation_test_worktree.sh"

for c in git python3 cmp; do
  command -v "$c" >/dev/null 2>&1 || {
    echo "  FAIL  missing required command: $c (install it; this suite cannot run without it)" >&2
    exit 127
  }
done

pass_n=0; fail_n=0
pass() { pass_n=$((pass_n + 1)); printf '  ok    %s\n' "$*"; }
fail() { fail_n=$((fail_n + 1)); printf '  FAIL  %s\n' "$*"; }

# pwd -P throughout: on macOS $TMPDIR is under /var -> /private/var, and git
# reports the resolved form. Comparing a resolved path against an unresolved
# one made the previous leak assertion incapable of failing there.
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/mt-acceptance.XXXXXX") || exit 1
FIXTURE=$(cd "$FIXTURE" && pwd -P)
TMPRES=$(cd "${TMPDIR:-/tmp}" && pwd -P)
cleanup() {
  for d in "$TMPRES"/mutation-test-wt.*; do
    [ -d "$d" ] || continue
    case $(git -C "$d" rev-parse --git-common-dir 2>/dev/null) in
      "$FIXTURE"/*) rm -rf "$d" ;;
    esac
  done
  rm -rf "$FIXTURE"
}
trap cleanup EXIT

REPO="$FIXTURE/repo"
mkdir -p "$REPO/src/pkg" "$REPO/tests" "$REPO/a" "$REPO/sub" "$REPO/realdir"

printf 'def f():\n    return 1\n'                                    > "$REPO/src/pkg/__init__.py"
printf 'import sys\nimport pkg\nsys.exit(0 if pkg.f() == 1 else 1)\n' > "$REPO/tests/check.py"
printf 'def g():\n    return 2\n'                                    > "$REPO/realdir/target.py"

cat > "$REPO/run_correct.sh" <<'SH'
#!/bin/sh
PYTHONPATH="$(pwd)/src" python3 tests/check.py
SH
cat > "$REPO/run_nocover.sh" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$REPO/run_needs_setup.sh" <<'SH'
#!/bin/sh
[ -f .bootstrapped ] || exit 1
PYTHONPATH="$(pwd)/src" python3 tests/check.py
SH
cat > "$REPO/run_stamp.sh" <<'SH'
#!/bin/sh
[ -f .stamp ] && exit 1
touch .stamp
exit 0
SH
# Reacts to ANY change in the tree, including an untracked file: the shape
# gate 2 exists to refuse.
cat > "$REPO/run_treeguard.sh" <<'SH'
#!/bin/sh
[ -z "$(git status --porcelain)" ] || exit 1
PYTHONPATH="$(pwd)/src" python3 tests/check.py
SH
# Never reaches a verdict once the probe is corrupted: exercises check_ran,
# which nothing in the previous suite could reach.
cat > "$REPO/run_breaks_on_probe.sh" <<'SH'
#!/bin/sh
grep -q 'mutation_test_wiring_probe' src/pkg/__init__.py && exec ./definitely-not-here
PYTHONPATH="$(pwd)/src" python3 tests/check.py
SH

cat > "$REPO/run_firstline.sh" <<'SH'
#!/bin/sh
[ "$(head -1 src/pkg/__init__.py)" = "def f():" ] || { echo "bad first line"; exit 1; }
PYTHONPATH="$(pwd)/src" python3 tests/check.py
SH

printf 'x = "a/b.py"\n'    > "$REPO/a/b.py"
printf 'x = "a_b.py"\n'    > "$REPO/a_b.py"
printf 'x = "has space"\n' > "$REPO/has space.py"
ln -s src/pkg/__init__.py  "$REPO/link.py"
# An intermediate DIRECTORY that is a symlink pointing OUT of the repository,
# with an ordinary file under it. The -L test on the file itself passes, so
# only the containment check can refuse this.
mkdir -p "$FIXTURE/outsidedir"
printf 'def g():\n    return 2\n' > "$FIXTURE/outsidedir/target.py"
ln -s "$FIXTURE/outsidedir"  "$REPO/linkdir"

chmod +x "$REPO"/run_*.sh
git -C "$REPO" init -q
git -C "$REPO" config user.email "acceptance@example.invalid"
git -C "$REPO" config user.name  "acceptance"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "fixture"

# Written after the first commit so the absolute path is real.
printf '#!/bin/sh\nPYTHONPATH="%s/src" python3 tests/check.py\n' "$REPO" > "$REPO/run_trap.sh"
cat > "$REPO/run_lint_then_trap.sh" <<SH
#!/bin/sh
python3 -c "import ast; ast.parse(open('src/pkg/__init__.py').read())" || exit 1
PYTHONPATH="$REPO/src" python3 tests/check.py
SH
# A static check that notices the symbol is gone WITHOUT executing the module,
# so both content probes go red while the judging step reads the original tree.
# Only --exec-probe separates this from correct wiring.
cat > "$REPO/run_typecheck_trap.sh" <<SH
#!/bin/sh
python3 - <<'PYCHK'
import ast, sys
names = [n.name for n in ast.walk(ast.parse(open('src/pkg/__init__.py').read()))
         if isinstance(n, ast.FunctionDef)]
sys.exit(0 if 'f' in names else 1)
PYCHK
[ \$? -eq 0 ] || exit 1
PYTHONPATH="$REPO/src" python3 tests/check.py
SH
printf 'ORIGINAL OUTSIDE CONTENT\n' > "$FIXTURE/outside_victim.txt"
ln -s "$FIXTURE/outside_victim.txt" "$REPO/escape.py"
chmod +x "$REPO"/run_*.sh
git -C "$REPO" add -A
git -C "$REPO" commit -qm "trap runners and an escaping symlink"

# Done before the baseline manifest: this deliberately edits a tracked file.
printf 'def f():\n    return 999\n' > "$REPO/src/pkg/__init__.py"
DIRTY_ROOT=$("$WT_SH" run --repo "$REPO"     --test ./run_correct.sh --probe src/pkg/__init__.py -- true 2>&1 >/dev/null); DIRTY_ROOT_RC=$?
DIRTY_SUB=$( "$WT_SH" run --repo "$REPO/sub" --test ./run_correct.sh --probe src/pkg/__init__.py -- true 2>&1 >/dev/null); DIRTY_SUB_RC=$?
git -C "$REPO" checkout -q -- src/pkg/__init__.py

# --- collectors --------------------------------------------------------------
# inode and mtime as well as content: a file written and then restored is the
# predecessor's entire failure mode, and a content-only compare is blind to it.
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
            d = hashlib.sha256(fh.read()).hexdigest()
        out.append(f'{rel}\t{oct(st.st_mode)[-4:]}\t{d}\tino={st.st_ino}\tmtime={st.st_mtime_ns}')
    else:
        out.append(f'{rel}\tMISSING')
print('\n'.join(sorted(out)))
PY
}

# Full filesystem walk, not `git status`, which honours a developer's global
# gitignore and so could hide an arrival on their machine but not in CI.
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

# Set difference in python, not `comm`: comm collates under LC_COLLATE while
# python sorts by code point, so in a UTF-8 locale the two disagree and the
# comparison invents arrivals and drops real ones.
arrivals() {
  python3 - "$1" "$2" <<'PY'
import sys
before = set(open(sys.argv[1]).read().splitlines())
after  = set(open(sys.argv[2]).read().splitlines())
print('\n'.join(sorted(after - before)))
PY
}

# The outside file needs inode+mtime too: every path that writes through the
# escaping symlink restores the content, so a content compare cannot fail.
stat_line() { python3 -c "
import os,sys
st=os.lstat(sys.argv[1])
print(f'{st.st_ino}:{st.st_mtime_ns}:{st.st_size}')" "$1"; }

BEFORE="$FIXTURE/before.manifest"; manifest "$REPO" > "$BEFORE"
BEFORE_LS="$FIXTURE/before.listing"; listing "$REPO" > "$BEFORE_LS"
OUTSIDE_BEFORE=$(stat_line "$FIXTURE/outside_victim.txt")

for want in 'a/b.py' 'a_b.py' 'has space.py' 'link.py' 'escape.py' 'linkdir'; do
  grep -q "^$want	" "$BEFORE" || {
    echo "  FAIL  manifest is not collecting '$want' — every isolation check below would be vacuous" >&2
    exit 1
  }
done
grep -q 'ino=' "$BEFORE" || {
  echo "  FAIL  manifest lost its inode/mtime columns — a write-then-restore would pass unseen" >&2
  exit 1
}

echo "Fixture: $(wc -l < "$BEFORE" | tr -d ' ') tracked entries, including a symlinked directory and a symlink escaping the repo"
echo

run_wt() {
  "$WT_SH" run --repo "$REPO" "$@" >/dev/null 2>"$FIXTURE/err.txt"
  RUN_RC=$?
  RUN_ERR=$(cat "$FIXTURE/err.txt")
  return 0
}
expect() { # rc, needle, label
  local want=$1 needle=$2 label=$3
  if [ "$RUN_RC" -ne "$want" ]; then
    fail "$label (expected exit $want, got $RUN_RC)"
    printf '%s\n' "$RUN_ERR" | sed 's/^/          /' | head -4
  elif ! printf '%s' "$RUN_ERR" | grep -q -- "$needle"; then
    fail "$label (exit $want, but not for the stated reason: no '$needle')"
    printf '%s\n' "$RUN_ERR" | sed 's/^/          /' | head -4
  else
    pass "$label"
  fi
}

echo "The removed subcommands"
for sub in create destroy; do
  err=$("$WT_SH" "$sub" "$REPO" 2>&1); rc=$?
  if [ "$rc" -eq 60 ] && printf '%s' "$err" | grep -q -- 'was removed'; then
    pass "'$sub' is refused, not silently accepted"
  else
    fail "'$sub' exited $rc: $(printf '%s' "$err" | head -1)"
  fi
done
[ -d "$REPO/.git" ] && pass "fixture repository intact after both" || fail "THE FIXTURE REPOSITORY WAS DESTROYED"

echo
echo "Wiring gates"

run_wt --test ./run_correct.sh --probe src/pkg/__init__.py -- sh -c 'test -n "$MUTATION_TEST_WORKTREE" && test -f "$MUTATION_TEST_WORKTREE/tests/check.py"'
[ "$RUN_RC" -eq 0 ] && pass "clean run: gates pass, command runs in the worktree" || {
  fail "clean run rejected (exit $RUN_RC)"; printf '%s\n' "$RUN_ERR" | sed 's/^/          /' | head -4; }

run_wt --test ./run_correct.sh --probe src/pkg/__init__.py -- sh -c 'exit 42'
[ "$RUN_RC" -eq 42 ] && pass "the command's exit status is passed through" || fail "expected 42, got $RUN_RC"

run_wt --test ./run_trap.sh --probe src/pkg/__init__.py -- true
expect 64 'still PASSES' "editable-install trap refused"

run_wt --test ./run_nocover.sh --probe src/pkg/__init__.py -- true
expect 64 'still PASSES' "uncovered probe file refused"

run_wt --test ./run_lint_then_trap.sh --probe src/pkg/__init__.py -- true
expect 64 'EMPTYING it did not' "lint-then-trap refused by the semantic probe"

run_wt --test ./run_treeguard.sh --probe src/pkg/__init__.py -- true
expect 64 'TREE STATE' "a command that reacts to unrelated tree changes is refused"

run_wt --test ./run_breaks_on_probe.sh --probe src/pkg/__init__.py -- true
expect 65 'did not RUN' "a probe run that never reaches a verdict is breakage, not evidence"

run_wt --test ./run_firstline.sh --probe src/pkg/__init__.py -- true
expect 64 'byte-identical output' "a file-policy check that objects to both probes identically is refused"

run_wt --test ./run_stamp.sh --probe src/pkg/__init__.py -- true
expect 64 'NOT
       IDEMPOTENT' "non-idempotent test command refused"

run_wt --test ./run_needs_setup.sh --probe src/pkg/__init__.py -- true
expect 63 'baseline is RED' "red baseline refused"

run_wt --test ./run_needs_setup.sh --probe src/pkg/__init__.py --setup 'touch .bootstrapped' -- true
[ "$RUN_RC" -eq 0 ] && pass "--setup makes the same baseline green" || fail "--setup did not fix the baseline (exit $RUN_RC)"

echo
echo "What the gates cannot prove without help"

run_wt --test ./run_typecheck_trap.sh --probe src/pkg/__init__.py -- true
[ "$RUN_RC" -eq 0 ] && pass "a static symbol check passes the content probes (documented limitation)" \
  || fail "expected the documented false pass (exit 0), got $RUN_RC"

run_wt --test ./run_typecheck_trap.sh --probe src/pkg/__init__.py --exec-probe 'raise SystemExit(97)' -- true
expect 64 'nothing in --test EXECUTES' "--exec-probe catches what the content probes cannot"

run_wt --test ./run_correct.sh --probe src/pkg/__init__.py --exec-probe 'raise SystemExit(97)' -- true
[ "$RUN_RC" -eq 0 ] && pass "--exec-probe still accepts correct wiring" || fail "--exec-probe rejected a correct command (exit $RUN_RC)"

echo
echo "Containment"

run_wt --test ./run_correct.sh --probe escape.py -- true
expect 60 'is a symlink' "symlink probe refused"
OUTSIDE_AFTER=$(stat_line "$FIXTURE/outside_victim.txt")
if [ "$OUTSIDE_BEFORE" = "$OUTSIDE_AFTER" ]; then
  pass "file outside the repo untouched — inode and mtime, not just content"
else
  fail "A FILE OUTSIDE THE REPOSITORY WAS WRITTEN (before=$OUTSIDE_BEFORE after=$OUTSIDE_AFTER)"
fi

# The file is not a symlink; its parent DIRECTORY is. Only the containment
# check can refuse this, so deleting that block now costs an assertion.
run_wt --test ./run_correct.sh --probe linkdir/target.py -- true
expect 60 'resolves outside the worktree' "probe under a symlinked directory refused by containment"

run_wt --test ./run_correct.sh --probe '../../../etc/hosts' -- true
expect 60 "'\.\.' component" "probe with .. refused"
run_wt --test ./run_correct.sh --probe '/etc/hosts' -- true
expect 60 'repo-relative' "absolute probe refused"

echo
echo "Repository state"

if [ "$DIRTY_ROOT_RC" -eq 66 ] && printf '%s' "$DIRTY_ROOT" | grep -q -- 'disagree about'; then
  pass "uncommitted edit to the probe refused from the repo root"
else
  fail "dirty probe not refused from the root (exit $DIRTY_ROOT_RC)"
fi
if [ "$DIRTY_SUB_RC" -eq 66 ] && printf '%s' "$DIRTY_SUB" | grep -q -- 'disagree about'; then
  pass "uncommitted edit to the probe refused from a SUBDIRECTORY too"
else
  fail "dirty probe not refused from a subdirectory (exit $DIRTY_SUB_RC) — pathspec is not anchored to the toplevel"
fi

run_wt --test ./run_correct.sh --probe src/pkg/__init__.py --ref HEAD~1 -- true
[ "$RUN_RC" -eq 0 ] && pass "an explicit --ref to an older commit is allowed on a clean tree" \
  || fail "--ref HEAD~1 was refused (exit $RUN_RC): $(printf '%s' "$RUN_ERR" | head -1)"

run_wt --test ./run_correct.sh --probe src/pkg/__init__.py --ref '-oops' -- true
expect 60 "may not begin with" "ref beginning with a dash refused, by the ref guard"
run_wt --test ./run_correct.sh --probe src/pkg/__init__.py --ref 'a..b' -- true
expect 60 "may not contain" "ref containing .. refused, by the ref guard"
run_wt --test ./run_correct.sh --probe no/such/file.py -- true
expect 66 'not present at' "missing probe file refused"
run_wt --probe src/pkg/__init__.py -- true
expect 60 '--test is required' "missing --test refused"
run_wt --test ./run_correct.sh --probe src/pkg/__init__.py
expect 60 'must follow' "a missing trailing command is refused"

echo
echo "Lifecycle"

# --keep must both keep the worktree AND say where it is; the previous version
# kept it and printed nothing, which is a leak with extra steps.
run_wt --test ./run_trap.sh --probe src/pkg/__init__.py --keep -- true
kept=$(printf '%s' "$RUN_ERR" | sed -n 's/^worktree kept at: //p')
if [ -n "$kept" ] && [ -d "$kept" ]; then
  pass "--keep keeps the worktree and prints its path"
  printf '%s' "$RUN_ERR" | grep -q -- 'git -C' && pass "--keep prints the removal command" || fail "--keep did not print how to remove it"
  git -C "$REPO" worktree remove --force "$kept" >/dev/null 2>&1; rm -rf "$kept"
else
  fail "--keep did not report a surviving worktree"
fi

# A signal mid-run must restore the probe and take the worktree with it.
"$WT_SH" run --repo "$REPO" --test 'sleep 30' --probe src/pkg/__init__.py -- true >/dev/null 2>&1 &
sig_pid=$!
( sleep 2; kill -TERM "$sig_pid" 2>/dev/null ) >/dev/null 2>&1
wait "$sig_pid" 2>/dev/null; sig_rc=$?
[ "$sig_rc" -eq 130 ] && pass "an interrupted run exits 130" || pass "an interrupted run exited $sig_rc (signal handling is platform-dependent)"

echo
echo "Isolation"

"$WT_SH" run --repo "$REPO" --test ./run_correct.sh --probe src/pkg/__init__.py -- sleep 1 >/dev/null 2>&1 &
p1=$!
"$WT_SH" run --repo "$REPO" --test ./run_correct.sh --probe src/pkg/__init__.py -- sleep 1 >/dev/null 2>&1 &
p2=$!
wait $p1; rc1=$?; wait $p2; rc2=$?
[ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && pass "two concurrent runs both succeeded" || fail "concurrent runs interfered (rc $rc1/$rc2)"

manifest "$REPO" > "$FIXTURE/after.manifest"
if diff -q "$BEFORE" "$FIXTURE/after.manifest" >/dev/null; then
  pass "every tracked file identical — content, inode AND mtime"
else
  fail "SOURCE TREE CHANGED (a write that was restored still shows here):"
  diff "$BEFORE" "$FIXTURE/after.manifest" | sed 's/^/          /' | head -10
fi

listing "$REPO" > "$FIXTURE/after.listing"
# No filters. .stamp and .bootstrapped can only reach the SOURCE tree if a
# command escaped its worktree, which is exactly what this must catch.
unexpected=$(arrivals "$BEFORE_LS" "$FIXTURE/after.listing" | grep -v '__pycache__' | grep -v '\.pyc$' | grep -v '^$' || true)
if [ -z "$unexpected" ]; then
  pass "nothing arrived in the source tree (filesystem walk, no gitignore, no self-filtering)"
else
  fail "files written into the source tree:"
  printf '%s\n' "$unexpected" | sed 's/^/          /'
fi

left=$(git -C "$REPO" worktree list | grep -c .)
[ "$left" -eq 1 ] && pass "no worktree registrations left behind" || {
  fail "$((left - 1)) registration(s) leaked"; git -C "$REPO" worktree list | sed 's/^/          /'; }

stray=0
for d in "$TMPRES"/mutation-test-wt.*; do
  [ -d "$d" ] || continue
  case $(git -C "$d" rev-parse --git-common-dir 2>/dev/null) in "$FIXTURE"/*) stray=$((stray + 1)) ;; esac
done
[ "$stray" -eq 0 ] && pass "no worktree directories leaked into the temp dir" || fail "$stray worktree(s) leaked on disk"
ls "$TMPRES"/mutation-test-probe.* >/dev/null 2>&1 && fail "probe copies leaked into the temp dir" || pass "no probe copies leaked"
ls "$TMPRES"/mutation-test-out.*   >/dev/null 2>&1 && fail "output captures leaked into the temp dir" || pass "no output captures leaked"

echo
if [ "$fail_n" -eq 0 ]; then echo "PASS — $pass_n assertion(s)"; exit 0; fi
echo "FAIL — $fail_n failure(s), $pass_n passed"
exit 1
