#!/usr/bin/env bash
# Reports whether this toolkit is installed and configured, and names what is
# missing. Read-only: it writes nothing and changes nothing.
#
# IT DOES NOT PREFLIGHT ITS DEPENDENCIES, which every other script here does.
# That is deliberate and it is the whole point of a diagnostic: a doctor that
# exits 127 because jq is absent has refused to answer at the moment it was most
# needed, and "jq: command not found" is exactly the output that sends an agent
# editing working code. A missing command is reported as a finding and the rest
# of the run continues. The preflight convention's purpose is served better this
# way than by obeying it -- see the `.agent.env` config convention in CLAUDE.md.
#
# It always exits 0 when it ran. A non-zero status would read as "the doctor
# failed" rather than "your install has a problem", and the findings are the
# result. Only a usage error exits non-zero.
#
# PATHS ARE REDACTED by default: $HOME prints as `~`, because the output is
# meant to be pasted into a public issue. --raw turns that off.
set -uo pipefail

REDACT=yes

usage() {
  cat <<'USAGE'
Usage: lunar_doctor.sh [options]

Reports whether the lunar toolkit is installed and configured. Read-only --
it writes nothing. Checks the loaded plugin copy and its version, the install
record, the permission rules in ~/.claude/settings.json against the shipped
template, the user CLAUDE.md, this project's .agent.env, and the commands each
skill shells out to.

Options:
  --raw          print full paths instead of redacting $HOME to `~`
  -h, --help     this text

Output is grouped by area, one finding per line:

  ok      nothing to do
  warn    works, but something is absent or unverifiable
  FAIL    this will not work until it is fixed

Exits 0 whenever it ran, whatever it found; the findings are the result.
A usage error exits 2.

Paths are redacted by default so the output can be pasted into an issue.
Pass --raw when reading it yourself. Nothing here reads a credential: the
permission check reads rule strings, never values, and .agent.env is reported
by key name only.
USAGE
}

# --help is answered before anything else can fail, including before the plugin
# root is resolved: a reader asking what this needs is the one least able to
# satisfy it.
while [ $# -gt 0 ]; do
  case "$1" in
    (-h|--help) usage; exit 0 ;;
    (--raw) REDACT=no; shift ;;
    (*) echo "lunar_doctor.sh: unknown argument: $1" >&2
        echo "Try 'lunar_doctor.sh --help'." >&2
        exit 2 ;;
  esac
done

# Resolved from this file rather than from PATH or a glob, because more than one
# copy of the plugin exists on any machine that has ever installed it and only
# one of them is running. Same reasoning as adversarial_review_path.sh.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$BIN_DIR/.." && pwd)"

redact() {
  if [ "$REDACT" = yes ] && [ -n "${HOME:-}" ]; then
    printf '%s' "${1//$HOME/\~}"
  else
    printf '%s' "$1"
  fi
}

say() { printf '  %-6s %-14s %s\n' "$1" "$2" "$3"; }
head_() { printf '\n%s\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- plugin ----
head_ "Plugin"

PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
if [ -r "$PLUGIN_JSON" ]; then
  # Deliberately not jq or python: the version is the one fact needed to say
  # anything at all, and reporting "cannot tell you the version because a tool
  # is missing" is the failure this script exists to avoid.
  VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUGIN_JSON" | head -1)"
  [ -n "$VERSION" ] || VERSION="?"
  say ok "version" "$VERSION"
else
  VERSION="?"
  say FAIL "version" "no manifest at $(redact "$PLUGIN_JSON")"
fi

say ok "loaded from" "$(redact "$PLUGIN_ROOT")"

case "$PLUGIN_ROOT" in
  (*/plugins/cache/*)
    say ok "install kind" "marketplace cache -- an installed copy" ;;
  (*)
    say warn "install kind" "a checkout, loaded by a directory marketplace" ;;
esac

# ---------------------------------------------------------- install record ----
head_ "Install record"

RECORD="${HOME:-}/.claude/plugins/installed_plugins.json"
if [ ! -r "$RECORD" ]; then
  say warn "record" "none at $(redact "$RECORD") -- never installed from GitHub"
elif ! have python3; then
  say warn "record" "python3 absent, cannot read it"
else
  python3 - "$RECORD" "$PLUGIN_ROOT" "$REDACT" "${HOME:-}" <<'PY'
import json, sys
path, loaded, redact, home = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def r(s):
    return s.replace(home, '~') if redact == 'yes' and home else s

def say(status, label, detail):
    print('  %-6s %-14s %s' % (status, label, detail))

try:
    plugins = json.load(open(path)).get('plugins', {})
except Exception as exc:
    say('FAIL', 'record', 'unreadable: %s' % exc)
    raise SystemExit(0)

entries = plugins.get('lunar@lunar-skills') or []
if not entries:
    say('warn', 'record', 'no lunar@lunar-skills entry -- never installed from GitHub')
    raise SystemExit(0)

for e in entries:
    say('ok', 'version', e.get('version', '?'))
    say('ok', 'commit', (e.get('gitCommitSha') or '?')[:12])
    say('ok', 'updated', e.get('lastUpdated', '?'))
    install_path = e.get('installPath', '')
    if install_path and install_path != loaded:
        say('warn', 'not loaded',
            'this record is for %s, which is NOT the copy running' % r(install_path))
        say('warn', '', 'a directory marketplace wins over the cache; the record is stale here')
PY
fi

# ----------------------------------------------------------- permissions ----
head_ "Permissions"

LIVE="${HOME:-}/.claude/settings.json"
TEMPLATE="$PLUGIN_ROOT/install/user/settings.json"

if [ ! -r "$TEMPLATE" ]; then
  say FAIL "template" "missing from the plugin at $(redact "$TEMPLATE")"
elif [ ! -r "$LIVE" ]; then
  say FAIL "settings" "no $(redact "$LIVE") -- every script call will prompt"
  say FAIL "" "merge $(redact "$TEMPLATE") into it"
elif ! have python3; then
  say warn "settings" "python3 absent, cannot compare against the template"
else
  python3 - "$TEMPLATE" "$LIVE" "$PLUGIN_ROOT/bin" "$REDACT" <<'PY'
import glob, json, os, sys

tmpl_path, live_path, bin_dir, redact = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def say(status, label, detail):
    print('  %-6s %-14s %s' % (status, label, detail))

def load(p):
    with open(p) as fh:
        return json.load(fh).get('permissions', {}) or {}

try:
    tmpl, live = load(tmpl_path), load(live_path)
except Exception as exc:
    say('FAIL', 'settings', 'unreadable: %s' % exc)
    raise SystemExit(0)

live_allow = set(live.get('allow', []))

# The scripts are enumerated from bin/ rather than read out of the template, so
# a script that ships without a template rule is still reported. The template is
# the second opinion here, not the only one.
def unruled(path):
    # A script may declare that it ships without a rule on purpose, as
    # `# lunar:unruled <why>` in its header. scripts/validate.sh reads the same
    # marker, so the two cannot disagree about which absence is deliberate.
    try:
        with open(path) as fh:
            for line in fh:
                if not line.startswith('#'):
                    return False
                if line.startswith('# lunar:unruled'):
                    return True
    except OSError:
        pass
    return False

scripts = sorted(glob.glob(os.path.join(bin_dir, '*.sh')))
missing_scripts, by_design, wrongly_ruled = [], [], []
for path in scripts:
    name = os.path.basename(path)
    ruled = 'Bash(%s:*)' % name in live_allow
    # The marker is consulted BEFORE the rule. Checking the rule first and
    # skipping meant an approved script never reached the marker, so a rule
    # defeating a deliberate exemption read as healthy -- while validate.sh
    # calls that same state an error. Two readers of one marker, disagreeing.
    if unruled(path):
        (wrongly_ruled if ruled else by_design).append(name)
    elif not ruled:
        missing_scripts.append(name)

want = len(scripts) - len(by_design) - len(wrongly_ruled)
if missing_scripts:
    say('FAIL', 'script rules', '%d of %d present -- these prompt on every call:'
        % (want - len(missing_scripts), want))
    for name in missing_scripts:
        say('FAIL', '', '  %s' % name)
else:
    say('ok', 'script rules', '%d of %d present' % (want, want))
for name in by_design:
    say('ok', 'by design', '%s prompts on purpose' % name)
for name in wrongly_ruled:
    say('warn', 'over-approved', '%s is approved but ships unruled on purpose' % name)
    say('warn', '', '  the rule approves the bash -c wrapper, not the payload -- remove it')

for bucket in ('ask', 'deny'):
    want = tmpl.get(bucket, [])
    has = set(live.get(bucket, []))
    absent = [r for r in want if r not in has]
    if absent:
        status = 'FAIL' if bucket == 'deny' else 'warn'
        say(status, bucket, '%d of %d template rules present' % (len(want) - len(absent), len(want)))
        for rule in absent[:6]:
            say(status, '', '  %s' % rule)
        if len(absent) > 6:
            say(status, '', '  ... and %d more' % (len(absent) - 6))
    else:
        say('ok', bucket, '%d of %d template rules present' % (len(want), len(want)))

# A rule from the shipped template is public text. A rule the user wrote is
# theirs, and can carry a hostname, a path outside $HOME, a URL or a token
# inside a command string -- and this report is documented as safe to paste into
# a public issue, so the default cannot print one whole.
template_rules = set()
for bucket in ('allow', 'ask', 'deny'):
    template_rules.update(tmpl.get(bucket, []))

def abbreviate(rule):
    # Keep the tool and the command name, drop every argument: enough to find
    # the rule in your own settings file, not enough to disclose what it names.
    head, sep, rest = rule.partition('(')
    if not sep or ' ' not in rest:
        return rule
    return '%s(%s ...)' % (head, rest.split()[0])

# Precedence is deny > ask > allow, so a rule in two buckets silently resolves to
# the stricter one. That is a behaviour change the file itself does not show.
buckets = {b: set(live.get(b, [])) for b in ('allow', 'ask', 'deny')}
collisions = []
for a, b in (('allow', 'ask'), ('allow', 'deny'), ('ask', 'deny')):
    for rule in sorted(buckets[a] & buckets[b]):
        collisions.append((rule, a, b, b))
if collisions:
    say('warn', 'collisions', '%d rule(s) in two buckets -- the stricter wins:' % len(collisions))
    hidden = 0
    for rule, a, b, wins in collisions:
        if rule in template_rules or redact == 'no':
            shown = rule
        else:
            shown = abbreviate(rule)
            if shown != rule:
                hidden += 1
        say('warn', '', '  %s  (%s + %s -> %s)' % (shown, a, b, wins))
    if hidden:
        say('warn', '', '  %d rule(s) abbreviated: not from the shipped template, so the'
                        ' arguments are yours -- --raw prints them whole' % hidden)
else:
    say('ok', 'collisions', 'no rule sits in two buckets')
PY
fi

# ------------------------------------------------------------- user files ----
head_ "User files"

USER_MD="${HOME:-}/.claude/CLAUDE.md"
TMPL_MD="$PLUGIN_ROOT/install/user/CLAUDE.md"
if [ ! -r "$USER_MD" ]; then
  say warn "CLAUDE.md" "absent -- the skills assume the workflow it carries"
  say warn "" "template: $(redact "$TMPL_MD")"
elif [ ! -r "$TMPL_MD" ]; then
  say ok "CLAUDE.md" "$(redact "$USER_MD")"
  say warn "" "no shipped template to compare against"
else
  # Section headings, not content. A user edits this file -- that is what it is
  # for -- so a diff would warn forever and mean nothing. A heading the template
  # has and the file does not is the case worth reporting: it is what a copy
  # merged from an older version looks like, and the whole section is missing
  # rather than stale.
  MISSING=''
  while IFS= read -r h; do
    grep -qxF "$h" "$USER_MD" || MISSING="$MISSING${MISSING:+, }${h#\#\# }"
  done <<EOF
$(grep '^## ' "$TMPL_MD")
EOF
  if [ -n "$MISSING" ]; then
    say warn "CLAUDE.md" "$(redact "$USER_MD")"
    say warn "" "sections the template has and this file does not: $MISSING"
    say warn "" "a copy merged from an older version looks like this"
  else
    say ok "CLAUDE.md" "every template section present"
  fi
fi

CONF="${HOME:-}/.claude/gh-tasks.conf"
if [ -r "$CONF" ]; then
  say ok "gh-tasks.conf" "$(redact "$CONF")"
else
  say ok "gh-tasks.conf" "absent -- optional, a linked board needs no rows"
fi

# ---------------------------------------------------------------- project ----
head_ "This project ($(redact "$PWD"))"

ENVF="$PWD/.agent.env"
if [ ! -r "$ENVF" ]; then
  say warn ".agent.env" "absent -- hyperdx and langfuse need it here"
  say warn "" "template: $(redact "$PLUGIN_ROOT/install/project/.agent.env")"
else
  # Key names only. The values are credentials and this output is meant to be
  # pasted into an issue.
  KEYS="$(sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*[:=].*/\1/p' "$ENVF" | sort -u | tr '\n' ' ')"
  if [ -n "$KEYS" ]; then
    say ok ".agent.env" "keys: $KEYS"
  else
    say warn ".agent.env" "present but no KEY: VALUE or KEY=VALUE lines found"
  fi
fi

# ----------------------------------------------------------- dependencies ----
head_ "Dependencies"

dep() {
  if have "$1"; then
    say ok "$1" "$2"
  else
    say warn "$1" "absent -- needed by: $2"
  fi
}

dep jq "hyperdx"
dep curl "hyperdx (cloud), langfuse"
dep python3 "langfuse, and this script's settings check"
dep docker "hyperdx (local mode only)"
dep gh "pr-review, gh-tasks"

if have gh; then
  if gh auth status >/dev/null 2>&1; then
    say ok "gh auth" "authenticated"
    # gh prints its scopes on stderr; grep decides, so the text is never parsed
    # for anything but this one answer.
    if gh auth status 2>&1 | grep -q "'project'"; then
      say ok "gh scope" "project scope present -- gh-tasks can read boards"
    else
      say warn "gh scope" "no 'project' scope -- gh-tasks will exit 77"
      say warn "" "fix: gh auth refresh -s project"
    fi
  else
    say FAIL "gh auth" "not authenticated -- fix: gh auth login"
  fi
fi

printf '\n'
exit 0
