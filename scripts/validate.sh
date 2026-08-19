#!/usr/bin/env bash
# validate.sh — mechanical checks for this repo.
#
# There is no test suite here (the artifacts are Markdown contracts and bash
# scripts), but several invariants ARE checkable, and each check below maps to a
# class of bug that has actually shipped from this repo before:
#
#   - a permission allowlist naming a script that does not exist (typo)
#   - macOS cruft / personal paths committed into a public repo
#   - a workflow JS file using an API that breaks Workflow-tool resume
#   - a SKILL.md whose frontmatter name does not match its directory
#   - a plugin manifest whose name drifts from its directory, or a marketplace
#     entry pointing at a directory that is not a plugin
#   - a skill changed without bumping its plugin version, which strands every
#     user who already installed it (see docs/RELEASING.md)
#
# Usage:
#   scripts/validate.sh            # everything
#   scripts/validate.sh --quick    # skip the install integration test (pre-commit hook)
#
# Environment:
#   SHELLCHECK_SEVERITY=error   stage a noisy new script without failing the run
#   SHELLCHECK_OPTIONAL=1       tolerate shellcheck being absent (normally fatal)
#   SKIP_VERSION_CHECK=1        bypass the plugin version-bump check; for a clone
#                               with no tags, not for skipping a real bump
#
# Exit code is non-zero if any check FAILS. Warnings do not fail the run.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

QUICK=false
[[ "${1:-}" == "--quick" ]] && QUICK=true

fails=0
warns=0
if [[ -t 1 ]]; then R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else R=''; G=''; Y=''; B=''; N=''; fi
pass()    { printf '  %sok%s    %s\n' "$G" "$N" "$1"; }
fail()    { printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"; fails=$((fails + 1)); }
warn()    { printf '  %swarn%s  %s\n' "$Y" "$N" "$1"; warns=$((warns + 1)); }
section() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

# --------------------------------------------------------------------------
section "Shell scripts"
# --------------------------------------------------------------------------
# `mapfile` is bash 4; macOS ships 3.2, where it does not exist. With no `set -e`
# the run continued past the failure into an unset SH_FILES, so every check below
# this line was skipped on a Mac — reported as a pass on bash 4.4+, which stopped
# treating an unset array under `set -u` as an error.
SH_FILES=()
while IFS= read -r f; do
  SH_FILES+=("$f")
done < <(find . -name '*.sh' -not -path './.git/*' | sort)

# The ${a[@]+"${a[@]}"} guard is for the same bash 3.2: there, expanding an empty
# array under `set -u` is itself an "unbound variable" error.
for f in ${SH_FILES[@]+"${SH_FILES[@]}"}; do
  if err=$(bash -n "$f" 2>&1); then pass "syntax      $f"
  else fail "syntax      $f"; printf '%s\n' "$err" | sed 's/^/        /'; fi
done

if command -v shellcheck >/dev/null 2>&1; then
  # The scripts were clean at `warning` on the first CI run, so that is the
  # gate. Loosen with SHELLCHECK_SEVERITY=error only to stage a noisy import.
  sev="${SHELLCHECK_SEVERITY:-warning}"
  for f in ${SH_FILES[@]+"${SH_FILES[@]}"}; do
    if out=$(shellcheck --severity="$sev" --format=gcc "$f" 2>&1); then pass "shellcheck  $f"
    else fail "shellcheck  $f"; printf '%s\n' "$out" | sed 's/^/        /'; fi
  done
  if [[ "$sev" == "error" ]]; then
    for f in ${SH_FILES[@]+"${SH_FILES[@]}"}; do
      if ! out=$(shellcheck --severity=warning --format=gcc "$f" 2>&1); then
        warn "shellcheck  $f — non-blocking findings:"
        printf '%s\n' "$out" | sed 's/^/        /'
      fi
    done
  fi
elif [[ -n "${SHELLCHECK_OPTIONAL:-}" ]]; then
  warn "shellcheck not installed — lint skipped (SHELLCHECK_OPTIONAL is set)"
else
  # Deliberately a failure, not a warning. A machine without shellcheck still
  # passed the pre-commit hook, so unlinted shell reached the push and CI was
  # the first thing to see it. A skipped check should not look like a clean run.
  fail "shellcheck not installed — no shell linting happened"
  printf '        %s\n' \
    "Install it:  sudo apt-get install -y shellcheck  (or: brew install shellcheck)" \
    "Or skip deliberately:  SHELLCHECK_OPTIONAL=1 scripts/validate.sh"
fi

# Non-portable idioms. This workstation is Linux, so these pass locally and fail
# on a user's Mac. The macOS CI job is what catches them for real; this scan is
# the local approximation that fires before a push, and it names the idiom
# instead of leaving you to read a failure log from a machine you do not have.
# Nothing in this repo is exempt: the earlier carve-out for
# scripts/ and install.sh assumed they never leave a machine we control, but the
# repo is public, so install.sh runs on every clone-route user's machine and this
# script on every contributor's. That exemption is how a bash 4 builtin sat in
# validate.sh from its first commit until a macOS user reported it.
# `\\x` covers sed/printf hex escapes: GNU substitutes the byte, BSD emits the
# literal characters, which is a SILENT wrong answer rather than an error.
# grep's -P is matched inside a bundled short-option run (-oP, -qP), not just
# alone. timeout/realpath/base64 -w are GNU coreutils, absent on a stock macOS.
GNU_RE="find [^|]*-printf|sed -i |sed -r |date -d |date --date|readlink -f"
GNU_RE="$GNU_RE|grep -[a-zA-Z]*P|stat -c|mktemp -p|xargs -[a-zA-Z]*r|--iso-8601"
# timeout/realpath only in command position — otherwise the word "timeout" in
# an error message matches.
GNU_RE="$GNU_RE|\\\\x[0-9a-fA-F][0-9a-fA-F]|base64 -w"
GNU_RE="$GNU_RE|(^|[|;&(]|&&|\\\$\\()[[:space:]]*(timeout|realpath)[[:space:]]"
# bash 4 features. macOS ships 3.2.57 and Apple has not shipped a newer bash
# since, for licensing reasons, so 3.2 is the floor for anything a Mac runs.
# Word boundaries are spelled out rather than with \b, which is a GNU extension
# absent from POSIX ERE: on a grep without it the pattern simply stops matching,
# and a scan that finds nothing is indistinguishable from a clean tree.
BASH4_RE="(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$)"
BASH4_RE="$BASH4_RE|(declare|local|typeset) -A|shopt -s globstar"
BASH4_RE="$BASH4_RE|^[[:space:]]*coproc[[:space:]]|;;&|wait -n|\\[\\[ -v "
# ${v,,} and ${v^^} case conversion, with or without an array subscript.
BASH4_RE="$BASH4_RE|\\\$\\{[A-Za-z_][A-Za-z0-9_]*(\\[[^]]*\\])?[,^]"
PORT_RE="$GNU_RE|$BASH4_RE"

# Positive control. Every check below reports "nothing found" both when the tree
# is clean and when the pattern has quietly stopped matching — and the two are
# indistinguishable in a green run, which is how a GNU-only \b could have gone
# unnoticed on the one platform this scan exists to protect. So assert the
# pattern still matches known-bad input before any clean result is believed.
port_canary='mapfile -t X; declare -A M; find . -printf "%f"; echo "${v,,}"'
canary_hits=$(printf '%s\n' "$port_canary" | grep -cE "$PORT_RE" || true)
[[ "$canary_hits" -ge 1 ]] \
  && pass "portability regex matches its canary (scan is live)" \
  || fail "portability regex matched NOTHING in known-bad input — this grep lacks a feature the pattern uses, so a clean result below is meaningless"

gnuisms=""
shopt -s nullglob
# Every shell artifact in the repo, plus SKILL.md, which ships shell the agent
# runs verbatim.
for f in skills/*/bin/*.sh skills/*/SKILL.md install.sh scripts/*.sh .githooks/*; do
  [[ -f "$f" ]] || continue
  # Blank FULL-LINE comments only. Stripping from any '#' also blanked real code
  # — ${#ARR[@]}, ${var#prefix}, and `[[ $# -gt 0 ]]` all contain one — which hid
  # every idiom appearing later on such a line. Blank rather than delete, so the
  # line numbers grep reports still match the file. The GNU_RE/BASH4_RE/PORT_RE
  # assignments, and the canary, are blanked for the same reason: this script
  # defines the patterns it scans for, so its own definitions match themselves.
  # -E, not BRE with \|: alternation via \| is a GNU sed extension that BSD sed
  # does not have, and it would silently fail to blank on a Mac.
  hits=$(sed -E -e 's/^[[:space:]]*#.*//' -e 's/^(GNU_RE|BASH4_RE|PORT_RE|port_canary)=.*//' "$f" \
    | grep -nE "$PORT_RE" || true)
  [[ -n "$hits" ]] && gnuisms+="$f:$hits"$'\n'
done
shopt -u nullglob
[[ -z "$gnuisms" ]] && pass "no GNU-only or bash-4 idioms in any shell artifact" || {
  fail "non-portable idiom (breaks on macOS/BSD, or on bash 3.2):"
  printf '%s\n' "$gnuisms" | sed 's/^/        /'
}

# --------------------------------------------------------------------------
section "Workflow JS (Workflow-tool constraints)"
# --------------------------------------------------------------------------
shopt -s nullglob
for f in skills/*/*.workflow.js; do
  if err=$(node --check "$f" 2>&1); then pass "syntax      $f"
  else fail "syntax      $f"; printf '%s\n' "$err" | sed 's/^/        /'; fi

  # Strip // comments so the files' own prose about these APIs is not a hit.
  code=$(sed 's|//.*||' "$f")
  for bad in 'Date\.now\(' 'Math\.random\(' 'new Date\('; do
    if grep -qE "$bad" <<<"$code"; then
      fail "forbidden   ${bad//\\/} in $f — breaks workflow resume"
    fi
  done
  grep -qE '^export const meta = \{' "$f" \
    && pass "meta block  $f" \
    || fail "meta block  $f — must open with a pure-literal 'export const meta = {'"

  # phase() calls with no matching meta.phases entry still run, so warn only.
  titles=$(grep -oE "title: '[^']+'" "$f" | sed "s/title: '//; s/'$//" | sort -u)
  calls=$(grep -oE "phase\('[^']+'\)" "$f" | sed "s/phase('//; s/')$//" | sort -u)
  missing=$(comm -13 <(printf '%s\n' "$titles") <(printf '%s\n' "$calls"))
  [[ -n "$missing" ]] && warn "phases      $f — phase() titles absent from meta.phases: $(tr '\n' ' ' <<<"$missing")"
done
shopt -u nullglob

# --------------------------------------------------------------------------
section "Skills"
# --------------------------------------------------------------------------
for d in skills/*/; do
  name=$(basename "$d")
  f="$d/SKILL.md"
  if [[ ! -f "$f" ]]; then fail "$name — no SKILL.md"; continue; fi

  if [[ "$(head -1 "$f")" != "---" ]]; then
    fail "$name — SKILL.md must open with '---' frontmatter"; continue
  fi
  fm_name=$(awk '/^---$/{n++; next} n==1 && /^name:/{sub(/^name:[[:space:]]*/, ""); print; exit}' "$f")
  if [[ -z "$fm_name" ]]; then fail "$name — frontmatter missing 'name'"
  elif [[ "$fm_name" != "$name" ]]; then fail "$name — frontmatter name '$fm_name' != directory '$name'"
  else pass "frontmatter $name"; fi

  # The description is the auto-activation trigger text — a skill without one
  # loads but never fires on its own.
  awk '/^---$/{n++; next} n==1 && /^description:/{found=1} END{exit !found}' "$f" \
    || fail "$name — frontmatter missing 'description' (the auto-trigger text)"

  # bin/ is what Claude Code puts on the Bash tool's PATH. A non-executable file
  # there is invisible to the skill, which then falls back to prompting.
  for s in "$d"bin/*.sh; do
    [[ -e "$s" ]] || continue
    [[ -x "$s" ]] && pass "executable  $s" || fail "not executable: $s"
  done
  # scripts/ was the pre-plugin layout; anything left there is not on PATH.
  if [[ -d "$d/scripts" ]]; then
    fail "$name — has scripts/; bundled executables belong in bin/ to reach PATH"
  fi
done

# --------------------------------------------------------------------------
section "Plugin manifests"
# --------------------------------------------------------------------------
for f in .claude-plugin/marketplace.json skills/*/.claude-plugin/plugin.json; do
  if python3 -c "import json,sys; json.load(open('$f'))" 2>/dev/null; then
    pass "valid JSON  $f"
  else
    fail "invalid JSON $f"
  fi
done

# A plugin whose manifest name drifts from its directory installs under the
# wrong identifier, and the marketplace entry then points at nothing.
if out=$(python3 - <<'PY' 2>&1
import json, os, sys
bad = []
mp = json.load(open('.claude-plugin/marketplace.json'))
listed = set()
for entry in mp.get('plugins', []):
    name, src = entry.get('name'), entry.get('source')
    listed.add(name)
    if not isinstance(src, str):
        bad.append(f'{name}: source is not a relative path'); continue
    d = os.path.normpath(src)
    if not os.path.isdir(d):
        bad.append(f'{name}: source {src} is not a directory'); continue
    man = os.path.join(d, '.claude-plugin', 'plugin.json')
    if not os.path.isfile(man):
        bad.append(f'{name}: {d} has no .claude-plugin/plugin.json'); continue
    pn = json.load(open(man)).get('name')
    if pn != name:
        bad.append(f'{name}: plugin.json name is {pn!r}')
    if pn != os.path.basename(d):
        bad.append(f'{name}: plugin.json name {pn!r} != directory {os.path.basename(d)!r}')
for d in sorted(os.listdir('skills')):
    if os.path.isdir(os.path.join('skills', d)) and d not in listed:
        bad.append(f'{d}: skill exists but is not listed in marketplace.json')
if bad:
    print('\n'.join(bad)); sys.exit(1)
PY
); then
  pass "marketplace every entry resolves, names agree, no skill unlisted"
else
  fail "marketplace manifest inconsistency:"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# A plugin whose files changed since the last release but whose version did not
# is invisible to everyone who already installed it: marketplace clients offer an
# update only when `version` changes. Nothing else surfaces that, so it is a
# check rather than a convention. See docs/RELEASING.md.
# The baseline is the highest v<number> tag in the REPOSITORY, not the nearest
# one reachable from HEAD. `git describe` walks ancestry, so on a branch cut
# before the tag — or with the release tag on a sibling — it reports an older tag
# or none at all, and "none" reads as "nothing released yet" and passes. The glob
# is v[0-9]* rather than v*, or a tag like `vendor-snapshot` becomes the baseline.
last_tag=$(git tag --list 'v[0-9]*' --sort=-v:refname 2>/dev/null | head -1 || true)
case "${SKIP_VERSION_CHECK:-}" in 1|true|yes|TRUE|YES) skip_versions=true ;; *) skip_versions=false ;; esac

if [[ "$skip_versions" == true ]]; then
  warn "versions    bump check bypassed (SKIP_VERSION_CHECK)"
elif [[ -z "$last_tag" ]]; then
  # A shallow or --no-tags clone has tags upstream but none locally, which is
  # indistinguishable from "nothing released" unless we say so. CI sets
  # fetch-depth: 0 precisely to avoid this.
  if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo unknown)" != "false" ]]; then
    fail "versions    no tags available locally (shallow clone?) — the bump check cannot run"
    printf '        %s\n' "Give actions/checkout 'fetch-depth: 0', run 'git fetch --tags'," \
      "or set SKIP_VERSION_CHECK=1 to bypass deliberately."
  else
    warn "versions    no v<number> tag yet — nothing released, so no bump is required"
  fi
elif out=$(LAST_TAG="$last_tag" python3 - <<'PY' 2>&1
import json, os, re, subprocess, sys

tag = os.environ['LAST_TAG']
SEMVER = re.compile(r'^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$')

def git(*a):
    """Returns (ok, stdout). Never raises: a git failure must be reported, not
    silently treated as 'this plugin is new and therefore exempt'."""
    p = subprocess.run(('git',) + a, capture_output=True, text=True)
    return p.returncode == 0, p.stdout

def parsed(raw, where):
    try:
        v = json.loads(raw).get('version')
    except Exception as e:
        return None, f'{where}: manifest is not valid JSON ({e})'
    if v is None:
        return None, f'{where}: manifest has no "version" field'
    if not SEMVER.match(str(v)):
        return None, f'{where}: version {v!r} is not X.Y.Z'
    return str(v), None

bad = []
for d in sorted(p for p in os.listdir('skills') if os.path.isdir(os.path.join('skills', p))):
    sk = f'skills/{d}'
    man = f'{sk}/.claude-plugin/plugin.json'
    # Compare the tag against the INDEX: that is exactly what the commit will
    # contain. Comparing to HEAD hides a staged change from the pre-commit hook;
    # comparing to the working tree makes unrelated dirty state in some other
    # skill block a commit that does not touch it.
    unchanged, _ = git('diff', '--cached', '--quiet', tag, '--', sk)
    if unchanged:
        continue
    existed, old_raw = git('cat-file', '-p', f'{tag}:{man}')
    if not existed:
        # Genuinely absent at the tag => a new plugin, which needs no bump. This
        # is the one exemption, and it is granted only on an explicit "the blob
        # is not there", never on an unexplained read failure.
        ok_probe, _ = git('cat-file', '-e', f'{tag}:{sk}')
        if ok_probe:
            bad.append(f'{d}: changed, and {man} is unreadable at {tag} (renamed?)')
        continue
    was, err = parsed(old_raw, f'{d} at {tag}')
    if err:
        bad.append(err); continue
    # Index only — never fall back to the working tree. Falling back let a
    # commit that STAGES A DELETION of the manifest pass, because the on-disk
    # copy still carried a bumped version. A manifest absent from the index is
    # absent from the commit, and a plugin without one cannot be installed.
    ok_now, now_raw = git('show', f':{man}')
    if not ok_now:
        bad.append(f'{d}: changed, but {man} is not in the index '
                   '(staged for deletion, or never added?)')
        continue
    now, err = parsed(now_raw, d)
    if err:
        bad.append(err); continue
    if tuple(map(int, SEMVER.match(now).groups())) <= tuple(map(int, SEMVER.match(was).groups())):
        rel = 'is still' if now == was else f'went BACKWARDS from {was} to'
        bad.append(f'{d}: changed since {tag} but {rel} {now}')

if bad:
    print('\n'.join(bad)); sys.exit(1)
PY
); then
  pass "versions    every plugin changed since $last_tag has a higher version"
else
  fail "versions    a plugin changed since $last_tag without a valid bump:"
  printf '%s\n' "$out" | sed 's/^/        /'
  printf '        %s\n' "Users who installed it will never be offered the update." \
    "Bump the version in skills/<name>/.claude-plugin/plugin.json and add a" \
    "CHANGELOG.md entry under Unreleased. See docs/RELEASING.md."
fi

# The authoritative check, when the CLI is on hand. CI has no Claude Code, so
# the python checks above stand alone there.
if command -v claude >/dev/null 2>&1; then
  for t in . skills/*/; do
    if out=$(claude plugin validate "$t" 2>&1); then pass "plugin validate $t"
    else fail "plugin validate $t"; printf '%s\n' "$out" | sed 's/^/        /'; fi
  done
else
  warn "claude CLI not installed — 'claude plugin validate' skipped"
fi

# --------------------------------------------------------------------------
section "Config templates"
# --------------------------------------------------------------------------
if python3 -c "import json,sys; json.load(open('project-files/.claude/settings.json'))" 2>/dev/null; then
  pass "valid JSON  project-files/.claude/settings.json"
else
  fail "invalid JSON project-files/.claude/settings.json"
fi

# The allowlist approves skill scripts by bare name, because bin/ is on the
# Bash tool's PATH. Every such rule must name a script that actually ships, and
# every shipped script must have a rule — a missing rule is a silent prompt.
# (A path-shaped rule was how the 'langfus' typo shipped unnoticed; the bare
# form moves the same failure here.)
if out=$(python3 - <<'PY' 2>&1
import glob, json, os, re, sys
bad = []
try:
    cfg = json.load(open('project-files/.claude/settings.json'))
except Exception as e:
    print(f'could not parse settings.json: {e}'); sys.exit(1)
shipped_paths = glob.glob('skills/*/bin/*.sh')
shipped = {os.path.basename(p) for p in shipped_paths}
# A basename shipped by two skills is unreachable for one of them: bare-name
# invocation resolves through PATH, which can only ever pick one. The set
# comparison below would happily pass such a pair.
seen = {}
for p in shipped_paths:
    seen.setdefault(os.path.basename(p), []).append(p)
for base, paths in sorted(seen.items()):
    if len(paths) > 1:
        bad.append(f'{base} is shipped by {len(paths)} skills ({", ".join(sorted(paths))}); '
                   'bare-name invocation can only ever reach one')
ruled = set()
for rule in cfg.get('permissions', {}).get('allow', []):
    m = re.fullmatch(r'Bash\(([A-Za-z0-9_.-]+\.sh):\*\)', rule)
    if m:
        ruled.add(m.group(1))
    elif re.search(r'~/\.claude/skills/', rule):
        bad.append(f'path-shaped skill rule will not match a PATH invocation: {rule}')
for name in sorted(ruled - shipped):
    bad.append(f'rule approves {name}, which no skill ships')
for name in sorted(shipped - ruled):
    bad.append(f'{name} ships but has no allowlist rule — it will prompt')
if bad:
    print('\n'.join(bad)); sys.exit(1)
PY
); then
  pass "allowlist   bare-name rules and shipped scripts agree"
else
  fail "allowlist   inconsistent with the shipped scripts:"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# The central invariant of the plugin layout: a SKILL.md must name its scripts
# by bare name only. A path works on one install route and silently fails on the
# other — ${CLAUDE_PLUGIN_ROOT} resolves under a marketplace install and passes
# through literally under install.sh, where the Bash call is then rejected. Four
# SKILL.md files were rewritten by hand to satisfy this; nothing but this check
# stops the next edit from reintroducing it.
# The tilde is bracketed so shellcheck does not read it as a path (SC2088);
# `[~]` and `~` are the same character class to grep.
pathrefs=$(grep -nE '[~]/\.claude/skills/|\$\{CLAUDE_PLUGIN_ROOT\}|\bscripts/[A-Za-z0-9_.-]+\.sh' \
  skills/*/SKILL.md 2>/dev/null | grep -v 'never\|NOT\|not resolve\|passes through' || true)
[[ -z "$pathrefs" ]] && pass "skill paths  no SKILL.md names a script by path" || {
  fail "a SKILL.md references a script by path (breaks one install route):"
  printf '%s\n' "$pathrefs" | sed 's/^/        /'
}

# Every script name mentioned in the docs must be a script that exists. A rename
# otherwise leaves working prose pointing at a command that is not on PATH, and
# the check above only covers SKILL.md — which is exactly how CLAUDE.md kept
# naming parse_comments.sh after it became pr_review_parse_comments.sh.
if out=$(python3 - <<'PY' 2>&1
import glob, os, re, sys
shipped = {os.path.basename(p) for p in glob.glob('skills/*/bin/*.sh')}
# The repo's own tooling, named in docs but never installed as a skill script.
own = {'install.sh', 'validate.sh', 'pre-commit.sh'}
bad = []
for md in sorted(glob.glob('*.md') + glob.glob('skills/*/SKILL.md') + glob.glob('docs/**/*.md', recursive=True)):
    for n, line in enumerate(open(md), 1):
        for name in re.findall(r'\b[A-Za-z0-9_.-]+\.sh\b', line):
            if name not in shipped and name not in own:
                bad.append(f'{md}:{n}: {name}')
if bad:
    print('\n'.join(bad)); sys.exit(1)
PY
); then
  pass "doc scripts every *.sh named in the docs actually ships"
else
  fail "docs name a script that does not exist (stale after a rename?):"
  printf '%s\n' "$out" | sed 's/^/        /'
fi

# --------------------------------------------------------------------------
section "Hygiene (this repo is public)"
# --------------------------------------------------------------------------
cruft=$(find . \( -name '.DS_Store' -o -name '__MACOSX' \) -not -path './.git/*')
[[ -z "$cruft" ]] && pass "no macOS cruft" || { fail "macOS cruft committed:"; printf '%s\n' "$cruft" | sed 's/^/        /'; }

# Personal absolute paths. This script names the patterns, so exclude itself.
# Exclusions are by PATH, not a `grep -v` on the output: that tests the whole
# matched LINE, so a real hit is dropped whenever its text happens to contain
# the filter string. That is not hypothetical — it is how a search of this repo
# for `mapfile` came back empty, the one hit being on a line that itself reads
# `-not -path './.git/*'`.
# Self-exclusion is an ANCHORED filter on the path, not `--exclude=validate.sh`:
# GNU grep lets --include win over --exclude when a file matches both, so the
# --exclude is silently inert here.
markers=$(grep -rlnE '/home/|/Users/|~/Sandbox' \
  --exclude-dir=.git \
  --include='*.md' --include='*.sh' --include='*.js' --include='*.json' --include='*.env' . 2>/dev/null \
  | grep -v '^\./scripts/validate\.sh$' || true)
[[ -z "$markers" ]] && pass "no personal absolute paths" || { fail "personal paths found in:"; printf '%s\n' "$markers" | sed 's/^/        /'; }

# Credential shapes — placeholders like 'sk-lf-...' must not become real keys.
# Same anchored self-exclusion. `-n` puts the matched text in the output, so an
# unanchored `grep -v` would test the line CONTENT and drop real hits.
secrets=$(grep -rEn 'sk-lf-[A-Za-z0-9]{8,}|pk-lf-[A-Za-z0-9]{8,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}' \
  --exclude-dir=.git \
  --include='*.md' --include='*.sh' --include='*.js' --include='*.json' --include='*.env' . 2>/dev/null \
  | grep -v '^\./scripts/validate\.sh:' || true)
[[ -z "$secrets" ]] && pass "no credential-shaped strings" || { fail "possible secret:"; printf '%s\n' "$secrets" | sed 's/^/        /'; }

# --------------------------------------------------------------------------
if [[ "$QUICK" == false ]]; then
section "Install integration"
# --------------------------------------------------------------------------
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  if CLAUDE_HOME="$tmp" ./install.sh >"$tmp/out.log" 2>&1; then
    pass "install.sh ran clean"
  else
    fail "install.sh failed:"; sed 's/^/        /' "$tmp/out.log"
  fi
  for d in skills/*/; do
    name=$(basename "$d")
    [[ -f "$tmp/skills/$name/SKILL.md" ]] && pass "installed   $name" || fail "install.sh did not install $name"
    [[ -f "$tmp/skills/$name/.claude-plugin/plugin.json" ]] \
      && pass "manifest    $name" \
      || fail "install.sh did not install $name's plugin.json"
  done
  # A script that arrives without +x is on PATH but unrunnable.
  for s in "$tmp"/skills/*/bin/*.sh; do
    [[ -e "$s" ]] || continue
    [[ -x "$s" ]] && pass "installed +x ${s#"$tmp"/}" || fail "installed non-executable: ${s#"$tmp"/}"
  done
  # An existing user CLAUDE.md must never be clobbered.
  printf 'PRESERVE ME\n' >"$tmp/CLAUDE.md"
  CLAUDE_HOME="$tmp" ./install.sh >/dev/null 2>&1
  [[ "$(cat "$tmp/CLAUDE.md")" == "PRESERVE ME" ]] \
    && pass "existing CLAUDE.md preserved" \
    || fail "install.sh overwrote an existing ~/.claude/CLAUDE.md"

  # Re-install must leave the skills root holding ONLY the skills. Claude Code
  # loads every directory under it that carries a manifest, so a backup left in
  # place becomes a second plugin claiming the live name, and the stale copy can
  # win. install.sh has now run 3x above, so any accumulation shows here.
  expected=$(find skills -mindepth 1 -maxdepth 1 -type d | wc -l)
  actual=$(find "$tmp/skills" -mindepth 1 -maxdepth 1 -type d | wc -l)
  manifests=$(find "$tmp/skills" -name plugin.json | wc -l)
  if [[ "$actual" -eq "$expected" && "$manifests" -eq "$expected" ]]; then
    pass "re-install    skills root holds exactly $expected skills, $expected manifests"
  else
    fail "re-install left $actual dirs / $manifests manifests in the skills root (expected $expected / $expected):"
    find "$tmp/skills" -mindepth 1 -maxdepth 1 -type d | sed 's/^/        /'
  fi
fi

# --------------------------------------------------------------------------
printf '\n%s' "$B"
if [[ $fails -eq 0 ]]; then printf '%sPASS%s' "$G" "$N"; else printf '%sFAIL%s' "$R" "$N"; fi
printf '%s — %d failure(s), %d warning(s)\n\n' "$N" "$fails" "$warns"
exit $(( fails > 0 ? 1 : 0 ))
