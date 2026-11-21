#!/usr/bin/env bash
# feature-plan-check-acceptance.sh — behavioural tests for feature_plan_check.sh.
#
# Everything in scripts/validate.sh is syntactic; so is every check the plan
# checker itself makes. This runs the checker and asserts on what it reports.
#
# It follows the rules mutation-test-acceptance.sh documents, for the same
# reasons:
#   * an assertion must be able to KILL the check it names. Every mutant below
#     is one targeted edit to the SAME clean fixture, so a check that stopped
#     firing takes its assertion red with it.
#   * feed each check the thing IT refuses. A mutant that trips two checks
#     proves neither.
#   * needles are FIXED strings (grep -F), never patterns.
#   * assert the exit status as well as the message. A check that prints the
#     right finding and exits 0 is worse than one that says nothing.
#
# Unlike the mutation-test suite this runs in well under a second, so
# validate.sh runs it even under --quick.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
CHECK="$REPO_ROOT/plugin/bin/feature_plan_check.sh"

command -v python3 >/dev/null 2>&1 \
  || { echo "  FAIL  missing required command: python3" >&2; exit 127; }
[ -x "$CHECK" ] || { echo "  FAIL  not executable: $CHECK" >&2; exit 127; }

pass_n=0; fail_n=0
pass() { pass_n=$((pass_n + 1)); printf '  ok    %s\n' "$*"; }
fail() { fail_n=$((fail_n + 1)); printf '  FAIL  %s\n' "$*"; }

FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/fpc-acceptance.XXXXXX") || exit 1
FIXTURE=$(cd "$FIXTURE" && pwd -P)
cleanup() { [ -n "${FIXTURE:-}" ] && [ -d "$FIXTURE" ] && rm -rf "$FIXTURE"; }
trap cleanup EXIT INT TERM

GOOD="$FIXTURE/good.md"
cat > "$GOOD" <<'PLAN'
# Plan: Fixture

## Invariants
- **INV-1:** one holds — because
- **INV-2:** two holds — because

## Implementation Plan

### Phase 1: build
- [ ] **P1.1** a task

**Verified by:** T-1, T-2

### Phase 2: finish
- [ ] **P2.1** another task

**Verified by:** T-3

## Test Definitions

### Unit

**T-1 — first**
- **Level:** unit

**T-2 — second**
- **Level:** unit

### Integration

**T-3 — third**
- **Level:** integration

## Coverage
- **INV-1** → T-1
- **INV-2** → T-3
- **Phase 1** → T-1, T-2
- **Phase 2** → T-3

## Status
`Drafted`
PLAN

# One targeted edit to the clean fixture. The anchor must occur exactly once,
# so a fixture edited later cannot silently stop producing the mutant.
mutate() { # label old new -> writes $FIXTURE/m.md
  python3 - "$GOOD" "$FIXTURE/m.md" "$2" "$3" <<'PY'
import sys
src = open(sys.argv[1]).read()
old, new = sys.argv[3], sys.argv[4]
if src.count(old) != 1:
    sys.exit(f'anchor occurs {src.count(old)} times, expected 1: {old!r}')
open(sys.argv[2], 'w').write(src.replace(old, new))
PY
}

# Asserts the checker's exit status, and that its output does or does not hold
# a fixed needle.
expect() { # label file want_status needle
  local label="$1" file="$2" want="$3" needle="$4" out status
  out=$("$CHECK" "$file" 2>&1); status=$?
  if [ "$status" -ne "$want" ]; then
    fail "$label — exit $status, expected $want"
    return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF "$needle"; then
    fail "$label — exit $want but output lacks: $needle"
    return
  fi
  pass "$label"
}

# --- the clean fixture must be silent, or every mutant below proves nothing ---
expect "a complete plan passes" "$GOOD" 0 "every INV and T traced"

# --- one assertion per check, each from its own mutant ---
mutate inv '- **INV-2** → T-3
' ''
expect "an INV absent from Coverage is reported" "$FIXTURE/m.md" 1 \
  "INV-2 is declared in Invariants but absent from Coverage"

mutate orphan '**T-3 — third**' '**T-4 — orphan**
- **Level:** unit

**T-3 — third**'
expect "a T defined but never cited is reported" "$FIXTURE/m.md" 1 \
  "T-4 is defined in Test Definitions but never cited"

mutate undefined '- **Phase 2** → T-3' '- **Phase 2** → T-3, T-9'
expect "a T cited but never defined is reported" "$FIXTURE/m.md" 1 \
  "T-9 is cited but never defined in Test Definitions"

mutate unverified '
**Verified by:** T-3
' '
'
expect "a phase with no Verified by is reported" "$FIXTURE/m.md" 1 \
  'no `Verified by:` line for ### Phase 2: finish'

mutate dupstatus '## Status
`Drafted`' '## Status
`Drafted`

## Status
`Drafted`'
expect "a duplicated ## Status is reported" "$FIXTURE/m.md" 1 \
  "## Status appears 2 times"

mutate noheading '## Coverage' '## Covrage'
expect "a missing required heading is reported" "$FIXTURE/m.md" 1 \
  "missing heading: ## Coverage"

# --- a prose mention is not a definition ---
# "Defined" once meant any T-<n> token inside Test Definitions, so one sentence
# naming a test satisfied the cited-but-undefined check -- a silent pass in the
# exact case that check exists for.
cat > "$FIXTURE/prose.md" <<'PLAN'
## Invariants
- **INV-1:** one holds — because

## Implementation Plan

### Phase 1: build
- [ ] **P1.1** a task

**Verified by:** T-1

## Test Definitions

### Unit

**T-1 — first**
- **Level:** unit

_(T-9 would duplicate T-1, so it is not written.)_

## Coverage
- **INV-1** → T-1
- **Phase 1** → T-1, T-9

## Status
`Drafted`
PLAN
expect "a T named only in prose is not a definition" "$FIXTURE/prose.md" 1 \
  "T-9 is cited but never defined in Test Definitions"

# --- an unfilled template is not a traceability gap ---
# T-<n> and INV-<n> are the template's own placeholders. Reporting them would
# make the checker fire on every plan before its first real test is written.
cat > "$FIXTURE/placeholders.md" <<'PLAN'
## Invariants
- **INV-<n>:** the property — why

## Implementation Plan

### Phase 1: x
**Verified by:** T-<n>

## Test Definitions
**T-<n> — name**

## Coverage
- **INV-<n>** → T-<n>

## Status
`Drafted`
PLAN
expect "template placeholders are not reported as gaps" "$FIXTURE/placeholders.md" 0 \
  "every INV and T traced"

# --- usage paths, which a reader without a plan file hits first ---
for flag in --help -h; do
  out=$("$CHECK" "$flag" 2>&1); status=$?
  if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -qF 'Usage: feature_plan_check.sh'; then
    pass "$flag prints usage and exits 0"
  else
    fail "$flag — exit $status, or no usage in output"
  fi
done

for args in "" "a b" "$FIXTURE/absent.md"; do
  # shellcheck disable=SC2086  # deliberate word split: "" must pass NO argument
  "$CHECK" $args >/dev/null 2>&1; status=$?
  label=${args:-"no arguments"}
  if [ "$status" -eq 2 ]; then
    pass "a usage error exits 2 — $label"
  else
    fail "a usage error exits $status, expected 2 — $label"
  fi
done

printf '\n'
if [ "$fail_n" -eq 0 ]; then
  printf 'PASS — %d assertion(s)\n' "$pass_n"
  exit 0
fi
printf 'FAIL — %d of %d assertion(s) failed\n' "$fail_n" "$((pass_n + fail_n))"
exit 1
