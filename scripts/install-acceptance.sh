#!/usr/bin/env bash
# install-acceptance.sh — behavioural tests for lunar_install.sh.
#
# Everything in scripts/validate.sh but this and mutation-test-acceptance.sh is
# syntactic. This one runs the artifact and asserts on what it did, because
# lunar_install.sh writes ~/.claude/settings.json: the file that decides what
# the agent may run. Syntax checks cannot see an insertion landing in the wrong
# array, and that is the defect with consequences here.
#
# Every case runs against a throwaway HOME under mktemp, so the suite never
# reads or writes the real ~/.claude. That is the whole reason it can run in
# CI and on a developer machine without a flag guarding it.
#
# The last block is the one that earns the rest. lunar_install.sh edits as text
# and verifies as JSON, and the verification is what makes the text editing
# safe; so these cases BREAK the insertion and require that nothing is written.
# Each mutation is applied to a copy and checked for having changed the file at
# all -- a sed expression that silently stops matching would otherwise turn
# every one of them into an assertion that the unmutated script works.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO/plugin/bin/lunar_install.sh"
TMPL="$REPO/plugin/install/user/settings.json"

usage() {
  cat <<'USAGE'
Usage: install-acceptance.sh

Behavioural tests for plugin/bin/lunar_install.sh. Runs against throwaway HOME
directories and never touches the real ~/.claude. Called by scripts/validate.sh.
USAGE
}

for arg in "$@"; do
  case "$arg" in (-h|--help) usage; exit 0 ;; esac
done

for required in "$SCRIPT" "$TMPL"; do
  if [ ! -r "$required" ]; then
    echo "install-acceptance.sh: missing $required" >&2
    exit 1
  fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/install-acceptance.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
trap 'rm -rf "$WORK"; exit 130' INT
trap 'rm -rf "$WORK"; exit 143' TERM

pass_n=0
fail_n=0
ok()  { pass_n=$((pass_n + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail_n=$((fail_n + 1)); printf '  FAIL  %s -- %s\n' "$1" "$2"; }

HOMEDIR=""
RC=0

# setup <name>; fixture on stdin, or nothing for "no settings file at all".
setup() {
  HOMEDIR="$WORK/$1"
  mkdir -p "$HOMEDIR/.claude"
  cat > "$WORK/$1.fixture"
  if [ -s "$WORK/$1.fixture" ]; then
    cp "$WORK/$1.fixture" "$HOMEDIR/.claude/settings.json"
  fi
}

# invoke <name> [args...]
invoke() {
  local name="$1"
  shift
  HOME="$HOMEDIR" "$SCRIPT" "$@" > "$WORK/$name.out" 2>&1
  RC=$?
}

# Every template rule present in the bucket the template puts it in.
fully_merged() {
  python3 - "$TMPL" "$HOMEDIR/.claude/settings.json" <<'PY'
import json
import sys
want = json.load(open(sys.argv[1]))['permissions']
try:
    have = json.load(open(sys.argv[2])).get('permissions', {})
except Exception as exc:
    print('unreadable: %s' % exc)
    raise SystemExit(1)
for bucket, rules in want.items():
    missing = [r for r in rules if r not in have.get(bucket, [])]
    if missing:
        print('%s missing %d rule(s)' % (bucket, len(missing)))
        raise SystemExit(1)
raise SystemExit(0)
PY
}

unchanged() {
  cmp -s "$WORK/$1.fixture" "$HOMEDIR/.claude/settings.json"
}

# Counted with a glob rather than `ls | grep`, which cannot be trusted with an
# arbitrary filename. A glob that matches nothing stays literal, so the -e test
# is what tells none from one.
# stat(1) spells this differently on macOS and Linux, and python3 is already a
# hard requirement of the script under test.
file_mode() {
  python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"
}

backup_count() {
  local n=0
  local f
  for f in "$1"/settings.json.bak-*; do
    if [ -e "$f" ]; then n=$((n + 1)); fi
  done
  printf '%s\n' "$n"
}

# ------------------------------------------------------------------ the cases ----

setup help </dev/null
invoke help --help
if [ "$RC" -eq 0 ] && grep -q '^Usage: lunar_install.sh' "$WORK/help.out"; then
  ok "--help answers with usage and exits 0"
else
  bad "--help" "rc=$RC"
fi

setup fresh </dev/null
invoke fresh --apply
if [ "$RC" -eq 0 ] && fully_merged >/dev/null; then
  ok "creates a settings file where none existed"
else
  bad "fresh" "rc=$RC $(fully_merged)"
fi

setup report <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(hdx_query.sh:*)"
    ]
  }
}
JSON
invoke report
# rc=1, not 0. The documented contract is that 0 means the file holds every
# template rule, and a report-mode run leaves it holding none of them. This
# assertion read -eq 0 when the suite was written, which is what let the script
# contradict its own header all the way into a PR.
if [ "$RC" -eq 1 ] && unchanged report; then
  ok "the default mode writes nothing and exits 1"
else
  bad "default mode" "rc=$RC, file changed"
fi

# The other direction, and the reason the one above is not satisfied by a script
# that simply always exits 1 in report mode: with nothing left to add, the same
# mode exits 0.
setup report-complete <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(hdx_query.sh:*)"
    ]
  }
}
JSON
invoke report-complete --apply
invoke report-complete-again
if [ "$RC" -eq 0 ] && grep -q 'Nothing to add' "$WORK/report-complete-again.out"; then
  ok "report mode exits 0 once the file holds every rule"
else
  bad "report-complete" "rc=$RC"
fi

setup append <<'JSON'
{
  "env": { "SECRET": "keep-me" },
  "permissions": {
    "allow": [
      "Bash(hdx_query.sh:*)",
      "Bash(my_own_tool.sh:*)"
    ],
    "ask": [
      "Bash(git commit:*)"
    ],
    "deny": [
      "Bash(env)"
    ]
  },
  "theme": "dark"
}
JSON
invoke append --apply
if [ "$RC" -eq 0 ] && fully_merged >/dev/null; then
  ok "appends to one-rule-per-line arrays"
else
  bad "append" "rc=$RC $(fully_merged)"
fi
if grep -q '"SECRET": "keep-me"' "$HOMEDIR/.claude/settings.json" \
  && grep -q '"theme": "dark"' "$HOMEDIR/.claude/settings.json" \
  && grep -q 'Bash(my_own_tool.sh:\*)' "$HOMEDIR/.claude/settings.json"; then
  ok "other settings and the user's own rules survive"
else
  bad "append" "an unrelated key or rule was lost"
fi
if [ "$(backup_count "$HOMEDIR/.claude")" -eq 1 ]; then
  ok "a backup is left beside the file"
else
  bad "append" "no backup"
fi

APPEND_HOME="$HOMEDIR"
invoke append-again --apply
BAK_N=$(backup_count "$APPEND_HOME/.claude")
if [ "$RC" -eq 0 ] && grep -q 'Nothing to add' "$WORK/append-again.out" \
  && [ "$BAK_N" -eq 1 ]; then
  ok "a second run is a no-op and makes no second backup"
else
  bad "idempotence" "rc=$RC, backups=$BAK_N"
fi

setup bucket-absent <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(hdx_query.sh:*)"
    ]
  },
  "model": "opus"
}
JSON
invoke bucket-absent --apply
if [ "$RC" -eq 0 ] && fully_merged >/dev/null; then
  ok "adds a bucket the file does not have"
else
  bad "bucket-absent" "rc=$RC $(fully_merged)"
fi
# A whole bucket is built by array_text rather than appended, so it carries the
# template's grouping on its own code path. Killed by passing set() in place of
# group_breaks at that call site -- which a mutation of the append path leaves
# untouched, so both paths need asserting separately.
TMPL_ASK=$(sed -n '/"ask": \[/,/^    \]/p' "$TMPL" | grep -c '^$')
LIVE_ASK=$(sed -n '/"ask": \[/,/^    \]/p' "$HOMEDIR/.claude/settings.json" | grep -c '^$')
if [ "$TMPL_ASK" -gt 0 ] && [ "$LIVE_ASK" -eq "$TMPL_ASK" ]; then
  ok "a bucket added whole keeps the template's blank-line groups"
else
  bad "bucket-absent" "grouping: template=$TMPL_ASK live=$LIVE_ASK"
fi

setup bucket-empty <<'JSON'
{
  "permissions": {
    "allow": [],
    "ask": [],
    "deny": []
  }
}
JSON
invoke bucket-empty --apply
if [ "$RC" -eq 0 ] && fully_merged >/dev/null; then
  ok "fills buckets that are present but empty"
else
  bad "bucket-empty" "rc=$RC $(fully_merged)"
fi

setup perms-absent <<'JSON'
{
  "theme": "dark"
}
JSON
invoke perms-absent --apply
if [ "$RC" -eq 0 ] && fully_merged >/dev/null; then
  ok "adds a permissions block to a file without one"
else
  bad "perms-absent" "rc=$RC $(fully_merged)"
fi

setup perms-empty <<'JSON'
{
  "theme": "dark",
  "permissions": {}
}
JSON
invoke perms-empty --apply
if [ "$RC" -eq 0 ] && fully_merged >/dev/null; then
  ok "fills an empty permissions block"
else
  bad "perms-empty" "rc=$RC $(fully_merged)"
fi

setup indent4 <<'JSON'
{
    "permissions": {
        "allow": [
            "Bash(hdx_query.sh:*)"
        ]
    }
}
JSON
invoke indent4 --apply
# A new bucket has to take the file's own indent unit, not a hardcoded two
# spaces: the indent is detected, so a file written with four gets four.
if [ "$RC" -eq 0 ] && grep -qE '^        "deny"' "$HOMEDIR/.claude/settings.json" \
  && ! grep -qE '^      "deny"' "$HOMEDIR/.claude/settings.json"; then
  ok "a new bucket takes the file's own indent unit"
else
  bad "indent4" "rc=$RC, indent not matched"
fi

setup inline <<'JSON'
{
  "permissions": {
    "allow": ["Bash(hdx_query.sh:*)", "Bash(langfuse_query.sh:*)"]
  }
}
JSON
invoke inline --apply
if [ "$RC" -eq 3 ] && unchanged inline \
  && grep -q 'not one rule per line' "$WORK/inline.out" \
  && grep -q 'Add these by hand' "$WORK/inline.out"; then
  ok "declines an inline array and prints the rules to paste"
else
  bad "inline" "rc=$RC"
fi

setup oneline <<'JSON'
{ "permissions": { "allow": [], "ask": [], "deny": [] } }
JSON
invoke oneline --apply
# This shape used to reach the verification step instead, which reported a file
# the script simply does not edit as a defect in the script.
if [ "$RC" -eq 3 ] && unchanged oneline \
  && grep -q 'does not start its own line' "$WORK/oneline.out" \
  && ! grep -q 'defect in this script' "$WORK/oneline.out"; then
  ok "declines a one-line file without blaming itself"
else
  bad "oneline" "rc=$RC"
fi

# The fixture above carries all three buckets, so it reaches the append path.
# Two other paths build the permissions block instead -- an empty permissions
# object, and no permissions key at all -- and neither ran the one-key-per-line
# check, so a one-line file WAS edited after all, reflowing the line the usage
# text promises never to touch. Killed by removing either guard.
setup oneline-emptyperms <<'JSON'
{ "permissions": {} }
JSON
invoke oneline-emptyperms --apply
if [ "$RC" -eq 3 ] && unchanged oneline-emptyperms \
  && grep -q 'Add these by hand' "$WORK/oneline-emptyperms.out"; then
  ok "declines a one-line file whose permissions block is empty"
else
  bad "oneline-emptyperms" "rc=$RC"
fi

setup oneline-noperms <<'JSON'
{ "model": "opus", "env": { "A": "1" } }
JSON
invoke oneline-noperms --apply
if [ "$RC" -eq 3 ] && unchanged oneline-noperms \
  && grep -q 'Add these by hand' "$WORK/oneline-noperms.out"; then
  ok "declines a one-line file with no permissions key"
else
  bad "oneline-noperms" "rc=$RC"
fi

# The same two shapes written across lines must still merge: the guard above is
# a one-line check, and a CRLF file must not read as one line because of its \r.
setup multiline-noperms <<'JSON'
{
  "model": "opus"
}
JSON
invoke multiline-noperms --apply
if [ "$RC" -eq 0 ] && fully_merged >/dev/null; then
  ok "a multi-line file with no permissions key still merges"
else
  bad "multiline-noperms" "rc=$RC $(fully_merged)"
fi

HOMEDIR="$WORK/crlf-noperms"
mkdir -p "$HOMEDIR/.claude"
printf '{\r\n  "model": "opus"\r\n}\r\n' > "$HOMEDIR/.claude/settings.json"
invoke crlf-noperms --apply
if [ "$RC" -eq 0 ] && fully_merged >/dev/null; then
  ok "a CRLF file is not mistaken for a one-line file"
else
  bad "crlf-noperms" "rc=$RC $(fully_merged)"
fi

setup malformed <<'JSON'
{ "permissions": { "allow": [ "Bash(hdx_query.sh:*)", ] } }
JSON
invoke malformed --apply
if [ "$RC" -eq 3 ] && unchanged malformed \
  && grep -q 'not valid JSON' "$WORK/malformed.out"; then
  ok "declines a file that does not parse"
else
  bad "malformed" "rc=$RC"
fi

# ~/.claude/settings.json is commonly a link into a dotfiles repo. Renaming onto
# the link replaces the link with a regular file: the real file never gets the
# rules, the repo shows no change, and the run still exits 0. Killed by reverting
# TARGET to LIVE in the write path.
setup symlink </dev/null
mkdir -p "$HOMEDIR/dotfiles"
cat > "$HOMEDIR/dotfiles/settings.json" <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(hdx_query.sh:*)"
    ]
  }
}
JSON
ln -s "$HOMEDIR/dotfiles/settings.json" "$HOMEDIR/.claude/settings.json"
invoke symlink --apply
if [ "$RC" -eq 0 ] && [ -L "$HOMEDIR/.claude/settings.json" ] \
  && grep -q 'Bash(gh_tasks_add.sh:\*)' "$HOMEDIR/dotfiles/settings.json"; then
  ok "a symlinked settings file is followed, not replaced"
elif [ -L "$HOMEDIR/.claude/settings.json" ]; then
  bad "symlink" "rc=$RC, the link survived but the file it points at did not change"
else
  bad "symlink" "rc=$RC, the link was replaced by a regular file"
fi

# The backup belongs beside the link, not beside the resolved file: that file is
# typically in a version-controlled dotfiles repo, where a .bak- lands as an
# untracked file in the user's working tree.
if [ "$(backup_count "$HOMEDIR/.claude")" -eq 1 ] \
  && [ "$(backup_count "$HOMEDIR/dotfiles")" -eq 0 ]; then
  ok "the backup stays beside the link, not in the dotfiles directory"
else
  bad "symlink" "backup landed in the wrong directory"
fi

# The backup is a verbatim copy of the settings file, so it must carry the same
# mode. It was being created at the umask default, which widens a 0600 file to
# 0644 on a stock umask. Killed by dropping the mode argument in write_new.
setup backup-mode <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(hdx_query.sh:*)"
    ]
  }
}
JSON
chmod 600 "$HOMEDIR/.claude/settings.json"
# An explicit permissive umask: under umask 077 the unfixed code produced 0600
# by accident and this assertion would pass for the wrong reason.
OLD_UMASK=$(umask)
umask 022
invoke backup-mode --apply
umask "$OLD_UMASK"
BAK=""
for f in "$HOMEDIR/.claude/"settings.json.bak-*; do
  if [ -e "$f" ]; then BAK="$f"; fi
done
if [ "$RC" -eq 0 ] && [ -n "$BAK" ] \
  && [ "$(file_mode "$HOMEDIR/.claude/settings.json")" = "600" ] \
  && [ "$(file_mode "$BAK")" = "600" ]; then
  ok "the backup and the replacement keep the file's mode"
else
  bad "backup-mode" "rc=$RC, settings=$(file_mode "$HOMEDIR/.claude/settings.json"), backup=${BAK:+$(file_mode "$BAK")}"
fi

setup collide <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(git push:*)"
    ],
    "ask": [
      "Bash(git commit:*)"
    ],
    "deny": [
      "Bash(env)"
    ]
  }
}
JSON
invoke collide --apply
if [ "$RC" -eq 1 ] && grep -q 'already has them in another list' "$WORK/collide.out"; then
  ok "a rule held in another bucket is reported, and exits 1"
else
  bad "collide" "rc=$RC"
fi
if python3 - "$HOMEDIR/.claude/settings.json" <<'PY'
import json
import sys
p = json.load(open(sys.argv[1]))['permissions']
moved = 'Bash(git push:*)' in p.get('ask', [])
kept = 'Bash(git push:*)' in p.get('allow', [])
raise SystemExit(0 if kept and not moved else 1)
PY
then
  ok "the colliding rule stays where the user put it"
else
  bad "collide" "the rule was moved or duplicated"
fi
if grep -q 'Bash(git add:\*)' "$HOMEDIR/.claude/settings.json"; then
  ok "the non-colliding rules are still applied"
else
  bad "collide" "a collision blocked the whole merge"
fi

setup nohome </dev/null
env -u HOME "$SCRIPT" > "$WORK/nohome.out" 2>&1
RC=$?
if [ "$RC" -eq 3 ] && grep -q 'HOME is unset' "$WORK/nohome.out"; then
  ok "declines cleanly when HOME is unset"
else
  bad "no-home" "rc=$RC"
fi

# --------------------------------------------- the verification step itself ----

mkdir -p "$WORK/root/bin/lib" "$WORK/root/install/user"
cp "$REPO/plugin/bin/lib/require_cmd.sh" "$WORK/root/bin/lib/"
cp "$TMPL" "$WORK/root/install/user/"

# guard <label> <sed expression>
guard() {
  # Separate declarations: within one `local`, every word is expanded before any
  # assignment takes effect, so a later value cannot refer to an earlier one.
  local label="$1"
  local expr="$2"
  local home="$WORK/g-$label"
  # Its own path per case. On one shared path, a sed that EXITS NON-ZERO leaves
  # the previous case's mutant in place, cmp sees a difference, and the case
  # silently re-tests the mutation before it -- four assertions reported, one
  # made.
  local mutant="$WORK/root/bin/mutant-$label.sh"
  # sed -i is not portable to the BSD sed macOS ships, so the edit goes through
  # a second file rather than in place.
  if ! sed "$expr" "$SCRIPT" > "$mutant.tmp"; then
    bad "guard/$label" "the sed expression failed, so this asserts nothing"
    return
  fi
  mv "$mutant.tmp" "$mutant"
  if cmp -s "$mutant" "$SCRIPT"; then
    bad "guard/$label" "the mutation changed nothing, so this asserts nothing"
    return
  fi
  chmod +x "$mutant"
  mkdir -p "$home/.claude"
  cat > "$home/.claude/settings.json" <<'JSON'
{
  "env": { "SECRET": "keep-me" },
  "permissions": {
    "allow": [
      "Bash(hdx_query.sh:*)"
    ],
    "ask": [
      "Bash(git commit:*)"
    ],
    "deny": [
      "Bash(env)"
    ]
  }
}
JSON
  cp "$home/.claude/settings.json" "$WORK/g-$label.before"
  HOME="$home" "$mutant" --apply > "$WORK/g-$label.out" 2>&1
  local rc=$?
  if [ "$rc" -eq 3 ] \
    && grep -qE 'did not come out as planned|would not parse' "$WORK/g-$label.out" \
    && cmp -s "$WORK/g-$label.before" "$home/.claude/settings.json"; then
    ok "a broken insertion is caught and nothing is written ($label)"
  else
    bad "guard/$label" "rc=$rc, the file may have been written"
  fi
}

# The concurrent-edit check has no positive case that is not a race, so its
# liveness is established the other way round: inverting the comparison must
# make every apply refuse. A check that had been deleted would survive the
# inversion with nothing to show for it, and this case would go red.
STALE="$WORK/root/bin/stale.sh"
sed 's/if read(TARGET) != live_text:/if read(TARGET) == live_text:/' "$SCRIPT" > "$STALE.tmp" \
  && mv "$STALE.tmp" "$STALE"
chmod +x "$STALE"
setup stale <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(hdx_query.sh:*)"
    ]
  }
}
JSON
if cmp -s "$STALE" "$SCRIPT"; then
  bad "stale-check" "the mutation changed nothing, so this asserts nothing"
else
  HOME="$HOMEDIR" "$STALE" --apply > "$WORK/stale.out" 2>&1
  RC=$?
  if [ "$RC" -eq 3 ] && grep -q 'changed while this was running' "$WORK/stale.out" \
    && unchanged stale; then
    ok "every apply reaches the concurrent-edit check"
  else
    bad "stale-check" "rc=$RC"
  fi
fi

# The diff is printed into the agent transcript on every run, including the
# plain report. Printed with context lines it carried the values of whatever
# keys sit next to "permissions" -- in a real file that is `env` and
# `apiKeyHelper`, so a live API key reached the transcript, which is the egress
# the shipped template denies Bash(env) to prevent. Killed by restoring any
# non-zero n= to difflib.unified_diff.
setup secrets <<'JSON'
{
  "env": {
    "LANGFUSE_SECRET_KEY": "sk-lf-NOT-A-REAL-KEY-0000"
  },
  "apiKeyHelper": "NOT-A-REAL-HELPER-PATH",
  "permissions": {
    "deny": [
      "Bash(env)"
    ]
  }
}
JSON
invoke secrets
if grep -qE 'sk-lf-NOT-A-REAL-KEY|NOT-A-REAL-HELPER-PATH' "$WORK/secrets.out"; then
  bad "secrets" "a neighbouring settings value was printed"
else
  ok "the diff prints no value from outside the permissions block"
fi
# The same file with no permissions block at all: the first-install shape, where
# the insertion lands at the top and the context ran over the whole file.
setup secrets-fresh <<'JSON'
{
  "env": {
    "LANGFUSE_SECRET_KEY": "sk-lf-NOT-A-REAL-KEY-0000"
  }
}
JSON
invoke secrets-fresh
if grep -q 'sk-lf-NOT-A-REAL-KEY' "$WORK/secrets-fresh.out"; then
  bad "secrets-fresh" "a secret was printed on the first-install shape"
else
  ok "the first-install diff prints no value from outside permissions"
fi

# A file this script creates decides what the agent may run, so it does not get
# the umask default. Under umask 002 -- shared build hosts, many container
# images -- 0664 would let any account in the user's group grant themselves
# Bash(*). Killed by dropping the explicit mode in the live_text is None branch.
# Not via setup(), which pre-creates .claude: the directory mode is only this
# script's business when this script is the one creating it.
HOMEDIR="$WORK/newmode"
mkdir -p "$HOMEDIR"
OLD_UMASK=$(umask)
umask 002
invoke newmode --apply
umask "$OLD_UMASK"
if [ "$RC" -eq 0 ] && [ "$(file_mode "$HOMEDIR/.claude/settings.json")" = "600" ] \
  && [ "$(file_mode "$HOMEDIR/.claude")" = "700" ]; then
  ok "a created settings file and its directory are not group-readable"
else
  bad "newmode" "settings=$(file_mode "$HOMEDIR/.claude/settings.json") dir=$(file_mode "$HOMEDIR/.claude")"
fi

# The other half of that decision: a ~/.claude the user already has is left at
# whatever mode they chose. Re-permissioning a directory this script did not
# create is a side effect nobody asked for.
HOMEDIR="$WORK/existingdir"
mkdir -p "$HOMEDIR/.claude"
chmod 755 "$HOMEDIR/.claude"
invoke existingdir --apply
if [ "$RC" -eq 0 ] && [ "$(file_mode "$HOMEDIR/.claude")" = "755" ]; then
  ok "an existing .claude keeps the mode the user gave it"
else
  bad "existingdir" "rc=$RC, dir=$(file_mode "$HOMEDIR/.claude")"
fi

# An interruption between the temp write and the rename used to strand the temp
# file forever, and a later run drawing the same pid then failed on it.
if [ -z "$(find "$HOMEDIR/.claude" -name '*.lunar-new-*' 2>/dev/null)" ]; then
  ok "a successful apply leaves no temporary file"
else
  bad "newmode" "a .lunar-new- file was left behind"
fi

# When the write fails after the backup was taken, the message says the settings
# file is untouched -- true, and read alone it implies the run left nothing
# behind. The backup has to be named or it is invisible.
setup rofail <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(hdx_query.sh:*)"
    ]
  }
}
JSON
mkdir -p "$HOMEDIR/ro"
mv "$HOMEDIR/.claude/settings.json" "$HOMEDIR/ro/settings.json"
ln -s "$HOMEDIR/ro/settings.json" "$HOMEDIR/.claude/settings.json"
chmod 500 "$HOMEDIR/ro"
invoke rofail --apply
chmod 700 "$HOMEDIR/ro"
if [ "$RC" -eq 3 ] && grep -q 'The backup this run made is still at' "$WORK/rofail.out" \
  && [ -z "$(find "$HOMEDIR/.claude" -name '*.lunar-new-*')" ]; then
  ok "a failed write names the backup it left and strands no temp file"
else
  bad "rofail" "rc=$RC"
fi

# 127 is now a documented status, so it needs pinning like the others. The shim
# carries the few commands the bash half runs before the preflight -- without
# bash itself on PATH, `env bash` fails and returns 127 for the wrong reason,
# which is a green light that tests nothing.
SHIM="$WORK/shim-bin"
mkdir -p "$SHIM"
SHIM_OK=yes
for c in bash dirname cat sed; do
  if command -v "$c" > /dev/null 2>&1; then
    ln -s "$(command -v "$c")" "$SHIM/$c"
  else
    SHIM_OK=no
  fi
done
if [ "$SHIM_OK" = no ]; then
  bad "no-python3" "could not build a shim PATH, so this asserts nothing"
else
  HOMEDIR="$WORK/nopython"
  mkdir -p "$HOMEDIR/.claude"
  PATH="$SHIM" HOME="$HOMEDIR" "$SCRIPT" --apply > "$WORK/nopython.out" 2>&1
  RC=$?
  PATH="$SHIM" HOME="$HOMEDIR" "$SCRIPT" --help > "$WORK/nopython-help.out" 2>&1
  HELP_RC=$?
  if [ "$RC" -eq 127 ] && grep -q 'Missing required command: python3' "$WORK/nopython.out" \
    && [ "$HELP_RC" -eq 0 ]; then
    ok "a missing python3 exits 127, and --help still answers without it"
  else
    bad "no-python3" "rc=$RC help=$HELP_RC"
  fi
fi

# A CRLF file -- a dotfiles repo checked out with core.autocrlf=true -- had
# every line ending rewritten, invisibly: the diff compares the already
# translated text against itself, so the report showed only the added rules.
# Killed by removing newline='' from either read() or write_new().
HOMEDIR="$WORK/crlf"
mkdir -p "$HOMEDIR/.claude"
printf '{\r\n  "permissions": {\r\n    "allow": [\r\n      "Bash(hdx_query.sh:*)"\r\n    ]\r\n  }\r\n}\r\n' \
  > "$HOMEDIR/.claude/settings.json"
cp "$HOMEDIR/.claude/settings.json" "$WORK/crlf.orig"
invoke crlf --apply
BAK=""
for f in "$HOMEDIR/.claude/"settings.json.bak-*; do
  if [ -e "$f" ]; then BAK="$f"; fi
done
if [ "$RC" -eq 0 ] && [ -n "$BAK" ] && cmp -s "$WORK/crlf.orig" "$BAK" \
  && python3 -c "
import sys
b = open(sys.argv[1], 'rb').read()
raise SystemExit(0 if b.count(b'\r\n') and b.count(b'\n') == b.count(b'\r\n') else 1)
" "$HOMEDIR/.claude/settings.json"; then
  ok "a CRLF file keeps its line endings and its backup is byte-exact"
else
  bad "crlf" "rc=$RC, endings mixed or backup not byte-exact"
fi

# The same rule in two buckets is a file Claude Code resolves by precedence and
# runs. Anchoring on a whole-file search for the last rule's text refused the
# entire merge on it. Killed by reverting the append anchor to unique().
setup dup-across <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(rm:*)"
    ],
    "ask": [
      "Bash(rm:*)"
    ]
  }
}
JSON
invoke dup-across --apply
if [ "$RC" -eq 0 ] && fully_merged >/dev/null; then
  ok "a rule the user lists in two buckets does not block the merge"
else
  bad "dup-across" "rc=$RC $(fully_merged)"
fi

# A rule spelled with an escaped solidus is the same JSON value but different
# bytes, so a json.dumps comparison could not find it and the script claimed the
# file was a shape it cannot edit.
setup escaped <<'JSON'
{
  "permissions": {
    "allow": [
      "Read(\/tmp\/x\/**)"
    ]
  }
}
JSON
invoke escaped --apply
if [ "$RC" -eq 0 ] && fully_merged >/dev/null \
  && python3 -c "
import json, sys
allow = json.load(open(sys.argv[1]))['permissions']['allow']
raise SystemExit(0 if 'Read(/tmp/x/**)' in allow else 1)
" "$HOMEDIR/.claude/settings.json"; then
  ok "a rule escaped differently from json.dumps is found, and survives"
else
  bad "escaped" "rc=$RC"
fi

# The blank-line grouping is the stated reason this script edits as text. It was
# delivered only when creating a file from nothing; an append emitted one flat
# block. Killed by dropping the breaks argument from either insertion path.
setup grouped <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(my_own_tool:*)"
    ]
  }
}
JSON
invoke grouped --apply
TMPL_GROUPS=$(sed -n '/"allow": \[/,/^    \]/p' "$TMPL" | grep -c '^$')
LIVE_GROUPS=$(sed -n '/"allow": \[/,/^    \]/p' "$HOMEDIR/.claude/settings.json" | grep -c '^$')
if [ "$RC" -eq 0 ] && [ "$LIVE_GROUPS" -ge "$TMPL_GROUPS" ] && [ "$TMPL_GROUPS" -gt 0 ]; then
  ok "an append keeps the template's blank-line groups"
else
  bad "grouped" "rc=$RC, template=$TMPL_GROUPS live=$LIVE_GROUPS"
fi

# A template rule the user keeps in allow means the denial is not in force. Said
# in the same neutral words as the allow/ask direction, it reads as the safe
# choice, which is backwards.
setup denied <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(env)"
    ]
  }
}
JSON
invoke denied --apply
if grep -q 'Denied by the template, permitted by your file' "$WORK/denied.out"; then
  ok "a denial the user permits is called out, not reported neutrally"
else
  bad "denied" "the deny direction was reported in the neutral wording"
fi

# HOME under a symlinked path is routine -- macOS resolves /tmp into /private,
# and these fixtures are mktemp dirs. The notice claimed the settings file was a
# link whenever any parent was one, sending the reader after a link that is not
# there. Killed by gating on TARGET != LIVE again.
setup parentlink <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(hdx_query.sh:*)"
    ]
  }
}
JSON
mkdir -p "$WORK/real-home"
cp -r "$HOMEDIR/.claude" "$WORK/real-home/"
rm -rf "$HOMEDIR"
ln -s "$WORK/real-home" "$HOMEDIR"
invoke parentlink
if ! grep -q 'a symlink' "$WORK/parentlink.out"; then
  ok "a symlinked parent directory is not reported as a symlinked settings file"
else
  bad "parentlink" "claimed a symlink that is not there"
fi

# Two races, each made deterministic by injecting the other party's write into
# the script itself. A sleep-and-background-write version of these would be
# timing-dependent; this asks the same question with no clock in it.
race() {
  local label="$1"
  local expr="$2"
  local want="$3"
  local mutant="$WORK/root/bin/race-$label.sh"
  if ! sed "$expr" "$SCRIPT" > "$mutant.tmp"; then
    bad "race/$label" "the sed expression failed, so this asserts nothing"
    return
  fi
  mv "$mutant.tmp" "$mutant"
  if cmp -s "$mutant" "$SCRIPT"; then
    bad "race/$label" "the mutation changed nothing, so this asserts nothing"
    return
  fi
  chmod +x "$mutant"
  local home="$WORK/r-$label"
  mkdir -p "$home/.claude"
  if [ "$label" = "vanished" ]; then
    printf '{\n  "permissions": {\n    "allow": [\n      "Bash(hdx_query.sh:*)"\n    ]\n  }\n}\n' \
      > "$home/.claude/settings.json"
  fi
  HOME="$home" "$mutant" --apply > "$WORK/r-$label.out" 2>&1
  local rc=$?
  if [ "$rc" -eq 3 ] && grep -q "$want" "$WORK/r-$label.out"; then
    ok "a settings file that $label mid-run is refused, not overwritten"
  else
    bad "race/$label" "rc=$rc"
  fi
}

# The create path has no backup of anything, so unlike the replace path its
# guard is a real guarantee: os.link fails if the name was taken. Killed by
# reverting it to os.replace, which overwrites whatever appeared.
race appeared \
  's|^            os.link(tmp, TARGET)|            open(TARGET, "w").close(); os.link(tmp, TARGET)|' \
  'appeared while this was running'

# os.stat used to sit above the try that handles exactly this, so a file removed
# mid-run ended in a traceback rather than the message written for it.
race vanished \
  's|^        mode = os.stat(TARGET)|        os.unlink(TARGET); mode = os.stat(TARGET)|' \
  'cannot re-read'

guard wrong-bucket "s/enumerate(plan\[bucket\]))/enumerate(plan['allow']))/"
guard dropped-rule "s/enumerate(plan\[bucket\]))/enumerate(plan[bucket][:-1]))/"
guard duplicated-rule "s/enumerate(plan\[bucket\]))/enumerate(plan[bucket] + plan[bucket][:1]))/"
guard clobbered-key 's|    new_text = live_text$|    new_text = live_text.replace("keep-me", "gone")|'

echo
if [ "$fail_n" -eq 0 ]; then echo "PASS — $pass_n assertion(s)"; exit 0; fi
echo "FAIL — $fail_n failure(s), $pass_n passed"
exit 1
