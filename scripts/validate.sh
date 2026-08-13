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
#
# Usage:
#   scripts/validate.sh            # everything
#   scripts/validate.sh --quick    # skip the install integration test (pre-commit hook)
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
mapfile -t SH_FILES < <(find . -name '*.sh' -not -path './.git/*' | sort)

for f in "${SH_FILES[@]}"; do
  if err=$(bash -n "$f" 2>&1); then pass "syntax      $f"
  else fail "syntax      $f"; printf '%s\n' "$err" | sed 's/^/        /'; fi
done

if command -v shellcheck >/dev/null 2>&1; then
  # The scripts were clean at `warning` on the first CI run, so that is the
  # gate. Loosen with SHELLCHECK_SEVERITY=error only to stage a noisy import.
  sev="${SHELLCHECK_SEVERITY:-warning}"
  for f in "${SH_FILES[@]}"; do
    if out=$(shellcheck --severity="$sev" --format=gcc "$f" 2>&1); then pass "shellcheck  $f"
    else fail "shellcheck  $f"; printf '%s\n' "$out" | sed 's/^/        /'; fi
  done
  if [[ "$sev" == "error" ]]; then
    for f in "${SH_FILES[@]}"; do
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

# GNU-only idioms in shipped scripts. CI and this workstation are Linux, so
# these pass here and fail on a user's Mac — the one class of bug the local
# checks structurally cannot catch by running the code. Dev-only scripts
# (scripts/, install.sh) are exempt; they never leave a machine we control.
GNU_RE="find [^|]*-printf|sed -i |date -d |date --date|readlink -f|grep -P|stat -c|mktemp -p|xargs -r|--iso-8601"
gnuisms=""
shopt -s nullglob
for f in skills/*/bin/*.sh; do
  # Blank out comments first — a script documenting why it AVOIDS an idiom is
  # not using it. sed leaves the lines in place, so grep -n stays accurate.
  hits=$(sed 's/#.*//' "$f" | grep -nE "$GNU_RE" || true)
  [[ -n "$hits" ]] && gnuisms+="$f:$hits"$'\n'
done
shopt -u nullglob
[[ -z "$gnuisms" ]] && pass "no GNU-only idioms in skills/*/bin" || {
  fail "GNU-only idiom in a shipped script (breaks on macOS/BSD):"
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
shipped = {os.path.basename(p) for p in glob.glob('skills/*/bin/*.sh')}
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

# --------------------------------------------------------------------------
section "Hygiene (this repo is public)"
# --------------------------------------------------------------------------
cruft=$(find . \( -name '.DS_Store' -o -name '__MACOSX' \) -not -path './.git/*')
[[ -z "$cruft" ]] && pass "no macOS cruft" || { fail "macOS cruft committed:"; printf '%s\n' "$cruft" | sed 's/^/        /'; }

# Personal absolute paths. This script names the patterns, so exclude itself.
markers=$(grep -rlnE '/home/|/Users/|~/Sandbox' \
  --include='*.md' --include='*.sh' --include='*.js' --include='*.json' --include='*.env' . 2>/dev/null \
  | grep -v './.git/' | grep -v 'scripts/validate.sh' || true)
[[ -z "$markers" ]] && pass "no personal absolute paths" || { fail "personal paths found in:"; printf '%s\n' "$markers" | sed 's/^/        /'; }

# Credential shapes — placeholders like 'sk-lf-...' must not become real keys.
secrets=$(grep -rEn 'sk-lf-[A-Za-z0-9]{8,}|pk-lf-[A-Za-z0-9]{8,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}' \
  --include='*.md' --include='*.sh' --include='*.js' --include='*.json' --include='*.env' . 2>/dev/null \
  | grep -v './.git/' | grep -v 'scripts/validate.sh' || true)
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
fi

# --------------------------------------------------------------------------
printf '\n%s' "$B"
if [[ $fails -eq 0 ]]; then printf '%sPASS%s' "$G" "$N"; else printf '%sFAIL%s' "$R" "$N"; fi
printf '%s — %d failure(s), %d warning(s)\n\n' "$N" "$fails" "$warns"
exit $(( fails > 0 ? 1 : 0 ))
