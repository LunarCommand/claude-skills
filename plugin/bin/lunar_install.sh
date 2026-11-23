#!/usr/bin/env bash
# lunar:unruled This script writes ~/.claude/settings.json, which is the file
# lunar:unruled that decides what the agent may run. A rule approving it would
# lunar:unruled live in its own output -- the toolkit pre-approving the script
# lunar:unruled that grants the toolkit its permissions, which is the consent
# lunar:unruled the prompt exists to collect. The prompt also shows whether
# lunar:unruled --apply was passed, which is the one argument that writes.
#
# Merges this toolkit's permission rules into ~/.claude/settings.json. The read
# half of this is lunar_doctor.sh, which names what is missing; this adds it.
#
# THE DEFAULT WRITES NOTHING. It prints what it would change, as a diff, and
# --apply is what commits it. The four gh_tasks_ scripts spell this the other
# way round, with --dry-run opting out of a write: a mis-closed task can be
# reopened, where a mangled settings file can withdraw the agent's ability to
# fix it. --dry-run is accepted as an alias for the default so the habitual
# spelling is never the wrong one.
#
# IT EDITS AS TEXT AND VERIFIES AS JSON. Rules are inserted as text so the
# file keeps the formatting and grouping its author gave it -- a serialiser
# drops blank lines inside arrays, which is most of what makes a long list
# readable. Text editing can land in the wrong place, so the result is parsed
# and compared against the original: every key outside `permissions` identical,
# every bucket equal to its old contents plus exactly the planned additions.
# Anything else and nothing is written. The two halves cover each other.
#
# Only `permissions` is touched. The other templates under install/ are prose,
# preferences, or values only the user has, and merging those is a judgement
# rather than a diff.
#
# ITS OUTPUT IS NOT REDACTED, unlike lunar_doctor.sh. The diff shows the edited
# region of your own settings file. Do not paste it into an issue.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: lunar_install.sh [--apply]

Merges this toolkit's permission rules into ~/.claude/settings.json, so the
bundled scripts stop prompting on every call. lunar_doctor.sh reports what is
missing; this adds it.

Options:
  --apply        write the change, after backing the file up
  --dry-run      report only, writing nothing (the default)
  -h, --help     this text

The default writes nothing: it prints the rules it would add and a diff of the
change. Read that, then re-run with --apply.

Only the `permissions` block is touched, and only by adding rules -- nothing is
removed, reordered or reformatted. Rules are inserted as text to preserve your
formatting, then the result is parsed and checked against the original; if it
differs anywhere but the planned additions, nothing is written.

The file is read before the plan is built and checked again before anything is
written, so an edit made to it while this runs is refused rather than silently
overwritten. That narrows the window; it does not close it. If the file is a
symlink, the file it points at is what changes, not the link, and the backup is
written beside the link.

A rule the template wants in one list while your file has it in another is
reported and skipped. Precedence is deny > ask > allow, so adding it would
silently change which one wins, and the file would not show why. That decision
is yours.

Exit status describes the FILE, not whether this script did something:
  0   the file holds every template rule
  1   it does not, and that is an ordinary outcome -- you have not passed
      --apply yet, or a rule's placement is yours to decide and was skipped. A
      run that adds most of the rules and skips a colliding one exits 1 too.
      Nothing here is a bug; do not go looking for one
  2   usage error
  3   refused. Nothing was written and stderr says why: either a shape this
      script will not edit, which the message tells you how to work around, or
      a defect in this script, which the message asks you to report. Re-running
      an unchanged file will refuse identically
  127 a required command or a bundled file is missing

Its output is NOT redacted -- the diff shows part of your own settings file.
lunar_doctor.sh is the one whose output is safe to paste into an issue.
USAGE
}

# --help is answered before the dependency preflight: a reader without python3
# is the one most likely to be asking what this needs.
# The leading `(` on each pattern is for bash 3.2, which macOS still ships.
for arg in "$@"; do
  case "$arg" in (-h|--help) usage; exit 0 ;; esac
done

MODE=report
while [ $# -gt 0 ]; do
  case "$1" in
    (--apply) MODE=apply; shift ;;
    (--dry-run) MODE=report; shift ;;
    (*) echo "lunar_install.sh: unknown argument: $1" >&2
        usage >&2
        exit 2 ;;
  esac
done

# Shared dependency preflight: require_cmd lives in lib/ beside this script,
# sourced by explicit path because bin/lib/ is not a PATH entry. See
# plugin/bin/lib/require_cmd.sh for why it does not sit in bin/ itself.
_require_cmd_lib="$(dirname "${BASH_SOURCE[0]}")/lib/require_cmd.sh"
if [ -r "$_require_cmd_lib" ]; then
  # shellcheck source=lib/require_cmd.sh
  . "$_require_cmd_lib"
else
  echo "Missing required file: $_require_cmd_lib" >&2
  echo "  This plugin install is incomplete; reinstall lunar." >&2
  exit 127
fi

# python3 is required here where lunar_doctor.sh only warns about it. The doctor
# answers a question and a partial answer beats none; this one edits a file and
# cannot check its own work without parsing, so it declines instead.
require_cmd python3 "Install python3 -- this script parses and verifies JSON before writing it."

# Resolved from this file rather than from PATH or a glob, because more than one
# copy of the plugin exists on any machine that has ever installed it and only
# one of them is running. Same reasoning as adversarial_review_path.sh.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$BIN_DIR/.." && pwd)"
TEMPLATE="$PLUGIN_ROOT/install/user/settings.json"

if [ ! -r "$TEMPLATE" ]; then
  echo "lunar_install.sh: template missing from the plugin at $TEMPLATE" >&2
  echo "  This plugin install is incomplete; reinstall lunar." >&2
  exit 3
fi

if [ -z "${HOME:-}" ]; then
  echo "lunar_install.sh: HOME is unset, so there is no ~/.claude/settings.json to merge into" >&2
  exit 3
fi
LIVE="$HOME/.claude/settings.json"

exec python3 - "$TEMPLATE" "$LIVE" "$MODE" <<'PY'
import difflib
import json
import os
import re
import sys
import time

TMPL, LIVE, MODE = sys.argv[1], sys.argv[2], sys.argv[3]
# Written through a symlink rather than over it. ~/.claude/settings.json is
# commonly a link into a dotfiles repo, and renaming onto the link replaces the
# link itself: the real file never gets the rules, the repo shows no change, and
# the run reports success. Reading already followed the link; this makes writing
# agree with it.
TARGET = os.path.realpath(LIVE)
BUCKETS = ('allow', 'ask', 'deny')


def out(line=''):
    print(line)


def decline(msg, *detail):
    # stdout is block-buffered into a pipe, so without this the refusal lands
    # ahead of the report it refers to in anything that captures the output.
    sys.stdout.flush()
    print('lunar_install.sh: %s' % msg, file=sys.stderr)
    for line in detail:
        print('  %s' % line, file=sys.stderr)
    # 3, not 1. Exit 1 means "work remains", which is what the report and a
    # skipped collision mean and is an ordinary outcome. A refusal is not, and
    # two of the paths through here say "this is a defect in this script" --
    # under one status with the usage text promising exit 1 is never a bug, an
    # agent re-runs the same refusal forever.
    raise SystemExit(3)


def paste_instead(rules_by_bucket):
    lines = ['Add these by hand instead, inside "permissions":']
    for bucket in BUCKETS:
        rules = rules_by_bucket.get(bucket) or []
        if rules:
            lines.append('  "%s": [' % bucket)
            lines.extend('    %s,' % json.dumps(r) for r in rules)
            lines.append('  ]')
    return lines


def read(path):
    # newline='' so line endings arrive as they are written on disk. The default
    # translates CRLF to LF on the way in and nothing puts it back, so a CRLF
    # file -- a dotfiles repo checked out with core.autocrlf=true -- had every
    # line ending in it rewritten, invisibly: the diff compares the already
    # translated text against itself, and the backup was written from the same
    # translated text, so it could not restore the original bytes either.
    # utf-8 rather than the locale's encoding, because JSON is utf-8 by spec.
    with open(path, encoding='utf-8', newline='') as fh:
        return fh.read()


def write_new(path, text, mode):
    # Created at its final mode instead of chmod'd into it afterwards: between
    # the two the file already holds the settings at whatever the umask gave,
    # and a copy of a 0600 file has no business being readable in that window.
    # O_EXCL also means a symlink sitting at this path is an error rather than
    # something written through.
    #
    # The mode is then set exactly, because the umask can only clear bits and a
    # copy that is tighter than its original is as wrong as one that is looser.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(fd, 'w', encoding='utf-8', newline='') as fh:
        fh.write(text)
    os.chmod(path, mode)


def discard(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def blame(where):
    # These helpers are run against the shipped template as well as the user's
    # file, and a template that cannot be parsed is a broken install, not a
    # defect in settings the user may never have touched.
    return ('This plugin install is incomplete; reinstall lunar.',) if where == TMPL else ()


def unique(text, needle, what, where=None):
    where = where or LIVE
    first = text.find(needle)
    if first < 0:
        decline('cannot find %s in %s' % (what, where),
                'The file is valid JSON but not a shape this script can edit as text.',
                *blame(where))
    if text.find(needle, first + 1) >= 0:
        decline('%s appears more than once in %s' % (what, where),
                'Which one to edit is a guess, and guessing is how the wrong line gets',
                'rewritten. Resolve the duplicate, or add the rules by hand.',
                *blame(where))
    return first


def line_bounds(text, offset):
    start = text.rfind('\n', 0, offset) + 1
    end = text.find('\n', offset)
    return start, (len(text) if end < 0 else end)


def indent_of(text, offset, what, *detail, **kw):
    # A caller that reused whatever precedes the offset as indentation built
    # unparseable JSON out of a one-line file, and left the guard to report a
    # shape this script simply does not edit as a defect in itself.
    start, _ = line_bounds(text, offset)
    prefix = text[start:offset]
    if prefix.strip():
        decline('%s in %s does not start its own line' % (what, kw.get('where') or LIVE),
                'This script only edits a file written one key per line, so that it',
                'never has to reflow a line you wrote.',
                *detail)
    return prefix


def detect_indent(text):
    m = re.search(r'\n([ \t]+)"', text)
    return m.group(1) if m else '  '


def reindent(span, outer_from, outer_to):
    if outer_from == outer_to:
        return span
    lines = span.split('\n')
    kept = [lines[0]]
    for line in lines[1:]:
        if line.startswith(outer_from):
            kept.append(outer_to + line[len(outer_from):])
        else:
            kept.append(line)
    return '\n'.join(kept)


def array_text(rules, outer, step, breaks=()):
    inner = outer + step
    body = ',\n'.join(('\n' if r in breaks and n else '') + inner + json.dumps(r)
                      for n, r in enumerate(rules))
    return '[\n%s\n%s]' % (body, outer)


def group_breaks(text, bucket):
    """Rules the template introduces with a blank line.

    The blank-line grouping is the stated reason this script edits as text
    rather than reserialising, and copying the template verbatim delivered it
    only when creating a file from nothing. Appending to a list the user
    already has is the common case, and it was emitting one flat block.
    """
    _, open_at, close = member_value_span(text, bucket, '[', TMPL)
    marked, blank = set(), False
    for row in text[open_at + 1:close - 1].split('\n'):
        stripped = row.strip()
        if not stripped:
            blank = True
            continue
        if blank:
            value = stripped[:-1].rstrip() if stripped.endswith(',') else stripped
            try:
                marked.add(json.loads(value))
            except ValueError:
                pass
        blank = False
    return marked


def member_value_span(text, key, opener, where=None):
    """Span of a top-level-ish member's container value, located by a unique key."""
    off = unique(text, json.dumps(key), 'the %s key' % json.dumps(key), where)
    m = re.compile(r'\s*:\s*\%s' % opener).match(text, off + len(json.dumps(key)))
    if not m:
        decline('the %s key in %s is not followed by %s' % (json.dumps(key), LIVE, opener),
                'Not a shape this script can edit as text.')
    open_at = m.end() - 1
    closer = {'{': '}', '[': ']'}[opener]
    depth, i, n = 0, open_at, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while i < n:
                if text[i] == '\\':
                    i += 2
                    continue
                if text[i] == '"':
                    break
                i += 1
        elif c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return off, open_at, i + 1
        i += 1
    decline('unbalanced %s after the %s key in %s' % (opener, json.dumps(key), LIVE))


# ----------------------------------------------------------------- the plan ----

try:
    tmpl_perms = json.loads(read(TMPL)).get('permissions') or {}
except (OSError, ValueError) as exc:
    decline('cannot read the shipped template: %s' % exc,
            'This plugin install is incomplete; reinstall lunar.')

live_text, live_obj = None, None
if os.path.exists(LIVE):
    try:
        live_text = read(LIVE)
        live_obj = json.loads(live_text)
    except OSError as exc:
        decline('cannot read %s: %s' % (LIVE, exc))
    except ValueError as exc:
        decline('%s is not valid JSON: %s' % (LIVE, exc),
                'Fix the syntax first. Editing a file that does not parse means',
                'guessing at what it meant, and the result would be unverifiable.')
    if not isinstance(live_obj, dict):
        decline('%s does not hold a JSON object' % LIVE)

live_perms = (live_obj or {}).get('permissions')
if live_perms is not None and not isinstance(live_perms, dict):
    decline('"permissions" in %s is not an object' % LIVE)
live_perms = live_perms or {}

for bucket in BUCKETS:
    if not isinstance(live_perms.get(bucket, []), list):
        decline('"permissions.%s" in %s is not an array' % (bucket, LIVE))

elsewhere = {}
for bucket in BUCKETS:
    for rule in live_perms.get(bucket, []):
        if isinstance(rule, str):
            elsewhere.setdefault(rule, []).append(bucket)

plan, collisions = {}, []
for bucket in BUCKETS:
    additions = []
    for rule in tmpl_perms.get(bucket, []):
        held = elsewhere.get(rule, [])
        if bucket in held:
            continue
        if held:
            collisions.append((rule, bucket, held[0]))
            continue
        if rule not in additions:
            additions.append(rule)
    plan[bucket] = additions

total = sum(len(v) for v in plan.values())

out('template  %s' % TMPL)
out('settings  %s%s' % (LIVE, '' if live_text is not None else '  (does not exist yet)'))
if os.path.islink(LIVE):
    # Only when the settings file is itself a link. TARGET also differs when a
    # parent directory is one -- routine on macOS, where /tmp and /var resolve
    # into /private -- and claiming a link that is not there sends the reader
    # looking for it.
    out('          -> %s  (a symlink; the file it points at is what changes)' % TARGET)
out()

if collisions:
    out('%d rule(s) skipped -- your file already has them in another list:' % len(collisions))
    for rule, wanted, found in collisions:
        out('  %s' % rule)
        out('    the template puts it in %s; yours has it in %s' % (wanted, found))
    out()
    # Split by direction. The paragraph below is written for a template rule
    # that is stricter than where the user keeps it -- there, leaving theirs
    # alone is the conservative answer. When the template's bucket is deny and
    # theirs is allow or ask, the same neutral wording describes dropping a
    # protection as the safe choice, which is backwards: the merge reports as
    # applied while the permissive placement stands.
    dropped = [c for c in collisions if c[1] == 'deny' and c[2] != 'deny']
    if dropped:
        out('  Denied by the template, permitted by your file:')
        for rule, _, found in dropped:
            out('    %s  (yours: %s)' % (rule, found))
        out('  Those denials are not in force, and this merge does not put them in')
        out('  force. The template denies Bash(env) and Bash(printenv:*) because a')
        out('  transcript is not somewhere an API key can be withdrawn from. If you')
        out('  did not put these in allow on purpose, move them to deny yourself.')
        out()
    out('  Your placement is the only one in the file, so it is what applies today.')
    out('  Precedence is deny > ask > allow, so adding the template\'s rule beside')
    out('  yours would hand the stricter list the decision, and the file would not')
    out('  show that it had. Move the rule yourself, or leave it and keep yours.')
    out()

if total == 0:
    if collisions:
        out('Nothing else to add.')
        raise SystemExit(1)
    out('Nothing to add -- every template rule is already in place.')
    raise SystemExit(0)

out('%d rule(s) to add: %s' % (total, ', '.join(
    '%d to %s' % (len(plan[b]), b) for b in BUCKETS if plan[b])))
out('Each one is a + line in the diff below.')
out()

# ------------------------------------------------------------- the new text ----

if live_text is None or not live_obj:
    # Nothing to preserve, so the template's own text is used verbatim: it
    # carries the blank-line grouping that makes a list this long navigable,
    # which is exactly what rebuilding it from parsed rules would drop.
    tmpl_text = read(TMPL)
    key_at, _, close_at = member_value_span(tmpl_text, 'permissions', '{', TMPL)
    new_text = '{\n  %s\n}\n' % tmpl_text[key_at:close_at]
    note = ('creating the file with only a permissions block' if live_text is None
            else 'replacing an empty object with a permissions block')
else:
    indent = detect_indent(live_text)
    # Read once: every bucket's grouping comes out of the same template text.
    tmpl_all = read(TMPL)
    edits = []
    if not live_perms:
        tmpl_text = read(TMPL)
        key_at, _, close_at = member_value_span(tmpl_text, 'permissions', '{', TMPL)
        member = reindent(tmpl_text[key_at:close_at], '  ', indent)
        if 'permissions' in (live_obj or {}):
            _, open_at, close = member_value_span(live_text, 'permissions', '{')
            edits.append((open_at, close, member.split(':', 1)[1].lstrip()))
        else:
            brace = live_text.find('{')
            if brace < 0 or live_text[:brace].strip():
                decline('%s does not open with a JSON object' % LIVE)
            edits.append((brace + 1, brace + 1, '\n%s%s,' % (indent, member)))
        note = 'adding the whole permissions block'
    else:
        note = 'adding rules to the lists you already have'
        for bucket in BUCKETS:
            if not plan[bucket]:
                continue
            existing = live_perms.get(bucket, [])
            if bucket not in live_perms:
                _, open_at, close = member_value_span(live_text, 'permissions', '{')
                member_indent = indent * 2
                body = array_text(plan[bucket], member_indent, indent,
                                  group_breaks(tmpl_all, bucket))
                edits.append((open_at + 1, open_at + 1,
                              '\n%s%s: %s,' % (member_indent, json.dumps(bucket), body)))
            elif not existing:
                key_at, open_at, close = member_value_span(live_text, bucket, '[')
                outer = indent_of(live_text, key_at, '"permissions.%s"' % bucket,
                                  *paste_instead({bucket: plan[bucket]}))
                edits.append((open_at, close,
                              array_text(plan[bucket], outer, indent,
                                         group_breaks(tmpl_all, bucket))))
            else:
                last = existing[-1]
                if not isinstance(last, str):
                    decline('the last entry in "permissions.%s" is not a string' % bucket)
                # Located from the array's own span, not by searching the whole
                # file for the last rule's text. A whole-file search refused the
                # entire merge when the user held that rule in two buckets at
                # once -- a file Claude Code resolves by precedence and runs
                # fine -- and missed outright when their spelling of the string
                # differed from json.dumps's, an escaped slash or a raw accent.
                # Neither makes the file uneditable.
                _, open_at, close = member_value_span(live_text, bucket, '[')
                # close is one past the ']', so the bracket itself is excluded.
                rows = live_text[open_at + 1:close - 1].split('\n')
                filled = [i for i, row in enumerate(rows) if row.strip()]
                # rows[0] is what follows '[' on its own line, so a last rule
                # found there means the array opens and closes without ever
                # starting a line of its own. That is the inline shape, and
                # reflowing it is the one thing this script will not do.
                if not filled or filled[-1] == 0:
                    decline('"permissions.%s" in %s is not one rule per line' % (bucket, LIVE),
                            'This script only appends to a one-rule-per-line array, so that',
                            'it never has to reflow a line you wrote.',
                            *paste_instead({bucket: plan[bucket]}))
                idx = filled[-1]
                tail = rows[idx].strip()
                tail = tail[:-1].rstrip() if tail.endswith(',') else tail
                try:
                    parsed = json.loads(tail)
                except ValueError:
                    parsed = None
                if parsed != last:
                    decline('"permissions.%s" in %s is not one rule per line' % (bucket, LIVE),
                            'This script only appends to a one-rule-per-line array, so that',
                            'it never has to reflow a line you wrote.',
                            *paste_instead({bucket: plan[bucket]}))
                end = open_at + 1 + sum(len(row) + 1 for row in rows[:idx]) + len(rows[idx])
                pad = rows[idx][:len(rows[idx]) - len(rows[idx].lstrip())]
                # A blank line before the first added rule separates the
                # user's own entries from the block this script appends, and
                # then wherever the template starts a new group.
                marked = group_breaks(tmpl_all, bucket)
                ins = ''.join(
                    ',%s\n%s%s' % ('\n' if (n == 0 or r in marked) else '',
                                   pad, json.dumps(r))
                    for n, r in enumerate(plan[bucket]))
                edits.append((end, end, ins))

    new_text = live_text
    for start, end, replacement in sorted(edits, key=lambda e: -e[0]):
        new_text = new_text[:start] + replacement + new_text[end:]

# Everything above is built with \n, including the template text copied in, so
# an insertion into a CRLF file leaves the two mixed. One pass at the end puts
# the file back on the endings it arrived with.
if live_text and '\r\n' in live_text:
    new_text = new_text.replace('\r\n', '\n').replace('\n', '\r\n')

# ----------------------------------------------------------------- the check ----

# The guard that makes text editing safe to do at all. An insertion that landed
# in the wrong array, duplicated a rule, dropped one, or disturbed any other
# setting shows up here as an inequality, and nothing is written.
try:
    new_obj = json.loads(new_text)
except ValueError as exc:
    decline('the edited file would not parse: %s' % exc,
            'Nothing was written. This is a defect in this script, not in your',
            'settings file -- please report it with lunar_doctor.sh output.')

old_obj = live_obj or {}
old_perms = old_obj.get('permissions') or {}
new_perms = new_obj.get('permissions')
if not isinstance(new_perms, dict):
    decline('the edited file has no permissions object', 'Nothing was written.')

problems = []
for key in set(old_obj) | set(new_obj):
    if key == 'permissions':
        continue
    if old_obj.get(key) != new_obj.get(key):
        problems.append('the %s setting changed' % json.dumps(key))
for key in set(old_perms) | set(new_perms):
    if key in BUCKETS:
        continue
    if old_perms.get(key) != new_perms.get(key):
        problems.append('permissions.%s changed' % key)
for bucket in BUCKETS:
    want = list(old_perms.get(bucket, [])) + plan[bucket]
    got = new_perms.get(bucket, [])
    if got != want:
        problems.append('permissions.%s is not its old contents plus the planned rules'
                        % bucket)
if problems:
    decline('the edit did not come out as planned, so nothing was written',
            *(problems + ['', 'This is a defect in this script. Please report it with',
                          'lunar_doctor.sh output.']))

# ---------------------------------------------------------------- the output ----

# n=0, so only added and removed lines print and never a line of surrounding
# context. Context is what leaks: the keys next to "permissions" in a real
# settings file are "env" and "apiKeyHelper", and three lines of it printed a
# live API key into the agent transcript on a plain report -- the whole env
# block on a first install, where the insertion lands at the top of the file.
# The shipped template denies Bash(env) to keep keys out of a transcript, so
# printing them here defeated the toolkit's own control. Every +/- line is a
# permission rule by construction, which is the only thing this script writes.
diff = list(difflib.unified_diff(
    (live_text or '').splitlines(keepends=True),
    new_text.splitlines(keepends=True),
    fromfile=LIVE + '  (now)', tofile=LIVE + '  (after)', n=0))

if MODE != 'apply':
    out('Would change %s -- %s:' % (LIVE, note))
    out()
    sys.stdout.writelines(diff)
    out()
    out('Nothing has been written. Re-run with --apply to commit this.')
    out('(Exit 1: the file does not hold every template rule yet.)')
    raise SystemExit(1)

for directory in {os.path.dirname(TARGET), os.path.dirname(LIVE)}:
    try:
        # 0o700: this directory holds the file that decides what the agent may
        # run. A group-writable ~/.claude on a shared machine or in a container
        # with umask 002 lets another local account edit that file.
        os.makedirs(directory, 0o700, exist_ok=True)
    except OSError as exc:
        decline('cannot create %s: %s' % (directory, exc))

# The file was read before the plan was built, and what is about to be written
# is that text plus the planned rules. An edit landing in between would be
# overwritten without trace, so the file is read again and the run declines if
# it moved. The window between this check and the rename below stays open --
# narrowing it is worth the lines, closing it would mean locking a file nothing
# else locks. The stat sits inside this try because the same disappearance it
# guards against would otherwise raise here, ten lines above the message
# written for it.
if live_text is not None:
    try:
        # The replacement and the backup both inherit the mode of the file
        # being replaced, so neither is readable to anyone the original was not.
        mode = os.stat(TARGET).st_mode & 0o7777
        if read(TARGET) != live_text:
            decline('%s changed while this was running' % LIVE,
                    'Nothing was written. Re-run to see a diff of the file as it',
                    'stands now.')
    except OSError as exc:
        decline('cannot re-read %s: %s' % (LIVE, exc),
                'Nothing was written. The settings file is untouched.')
else:
    # 0600 rather than the umask default for a file this script creates: it
    # decides what the agent may run, and 0664 hands that decision to every
    # account in the user's group.
    mode = 0o600

backup = None
if live_text is not None:
    # Beside the path the user named, not beside the resolved target: when that
    # target is a file in a dotfiles repo, a backup written next to it lands in
    # their working tree as an untracked file, and a version-controlled file is
    # the one case that already has a history.
    #
    # Numbered off the timestamp rather than overwriting it: a backup is only
    # worth making if a second run in the same second cannot take the first
    # one's place.
    stem = '%s.bak-%s' % (LIVE, time.strftime('%Y%m%d%H%M%S'))
    for attempt in range(1, 100):
        backup = stem if attempt == 1 else '%s-%d' % (stem, attempt)
        try:
            write_new(backup, live_text, mode)
            break
        except FileExistsError:
            continue
        except OSError as exc:
            # A write that stopped partway leaves a short file under a name
            # claiming to be a full copy, which is worse than no backup at all:
            # restoring from it would drop whatever rules did not make it.
            discard(backup)
            decline('cannot write the backup %s: %s' % (backup, exc),
                    'Nothing was written. The settings file is untouched.')
    else:
        decline('cannot find an unused backup name beside %s' % LIVE,
                'Nothing was written. The settings file is untouched.')

# Written beside the target and renamed over it, so an interrupted write cannot
# leave a half-file where the permissions live. This one must sit on the
# target's filesystem for the rename to be atomic, so it goes beside the
# resolved path even when the backup does not.
tmp = '%s.lunar-new-%d' % (TARGET, os.getpid())
try:
    write_new(tmp, new_text, mode)
    if live_text is None:
        # The file did not exist when the plan was built, so this run has no
        # backup of anything and never saw whatever created it since -- Claude
        # Code persisting an "always allow", a dotfiles stow, a second apply.
        # os.replace would overwrite that silently. A link fails instead if the
        # name has been taken, which is the only path here that is a guarantee
        # rather than a narrowing.
        try:
            os.link(tmp, TARGET)
        except FileExistsError:
            decline('%s appeared while this was running' % LIVE,
                    'It did not exist when this started, so there is no backup of',
                    'what it now holds. Nothing was written. Re-run to see a diff',
                    'against the file as it stands.')
    else:
        os.replace(tmp, TARGET)
except FileExistsError:
    decline('a temporary file from an interrupted run is in the way: %s' % tmp,
            'Nothing was written. Delete that file and re-run.')
except OSError as exc:
    detail = ['The settings file is untouched.'] if live_text is not None else []
    if backup:
        # Naming it because the line above says the settings file is untouched,
        # which a reader can otherwise take to mean the run left nothing behind.
        detail.append('The backup this run made is still at %s' % backup)
    decline('cannot write %s: %s' % (LIVE, exc), *detail)
finally:
    # Also covers an interruption between the write and the rename, which is
    # not an OSError and would otherwise strand the file until a later run drew
    # the same pid and failed on it.
    discard(tmp)

out('Applied -- %s.' % note)
if backup:
    out('Backup   %s' % backup)
out()
sys.stdout.writelines(diff)
out()
out('Permissions load at startup, so this session keeps the rules it began with:')
out('restart Claude Code before expecting the prompting to stop. Run')
out('lunar_doctor.sh afterwards to confirm what landed.')
if collisions:
    raise SystemExit(1)
PY
