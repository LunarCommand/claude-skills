#!/usr/bin/env bash
# Apply mutations one at a time, run the tests, and restore.
#
#   mutation_test_run_mutants.sh --spec mutants.json [--map map.json] --test-cmd 'uv run pytest'
#
# Spec is a JSON list. find/replace apply to the ONE line given, not the file,
# so a common token like '>=' needs no uniqueness games, and the match is
# LITERAL -- no regex, so '(', '.' and '*' are safe:
#
#   [{"file": "utils/logging_config.py", "line": 165,
#     "find": ">=", "replace": ">", "desc": "trip boundary >= -> >"}]
#
# Language-agnostic: --test-cmd is the only stack-specific part. With --map,
# only the tests covering the mutated line are run. Without one, the full
# --test-cmd runs per mutant -- slower, but works on any stack.
#
# SAFETY. Originals are copied before anything is touched and restored on exit,
# interrupt, or crash via trap, then verified byte-for-byte. Serial by design:
# two mutants sharing one working tree cannot be told apart.

set -uo pipefail

SPEC=""; MAP=""; OUT=""; ROOT="."; TEST_CMD=""; SELECT_TMPL=""; DRY=0; TIMEOUT=900
# --timeout was parsed and then never read: a caller asking for a 60s guard got
# none, and a mutant that hangs the suite hung the whole run. Resolved below
# rather than assumed, because `timeout` is GNU coreutils and a stock macOS
# does not have it.
TIMEOUT_PREFIX=""

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec)      SPEC="$2"; shift 2 ;;
    --map)       MAP="$2"; shift 2 ;;
    --out)       OUT="$2"; shift 2 ;;
    --root)      ROOT="$2"; shift 2 ;;
    --test-cmd)  TEST_CMD="$2"; shift 2 ;;
    --select-cmd) SELECT_TMPL="$2"; shift 2 ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    --dry-run)   DRY=1; shift ;;
    -h|--help)   usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

[[ -n "$SPEC" ]] || { echo "ERROR: --spec is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 2; }

cd "$ROOT"

if [[ -z "$TEST_CMD" ]]; then
  if   [[ -f uv.lock ]];     then TEST_CMD="uv run pytest"
  elif [[ -f poetry.lock ]]; then TEST_CMD="poetry run pytest"
  elif [[ -f package.json ]]; then TEST_CMD="npm test --"
  elif [[ -f go.mod ]];      then TEST_CMD="go test ./..."
  else echo "ERROR: could not detect a test command; pass --test-cmd" >&2; exit 1
  fi
fi
# How selected test ids are handed to the runner. Appending suits pytest, go and
# most JS runners; override for anything that needs a flag (e.g. jest -t).
[[ -n "$SELECT_TMPL" ]] || SELECT_TMPL="$TEST_CMD {tests}"

# Resolve the timeout binary once. GNU coreutils on Linux, `gtimeout` from
# coreutils on macOS, absent otherwise — in which case say so rather than drop
# the guard silently, because the caller asked for it.
if [[ "${TIMEOUT}" != "0" ]]; then
  if _to=$(command -v timeout 2>/dev/null); then TIMEOUT_PREFIX="$_to ${TIMEOUT}s "
  elif _to=$(command -v gtimeout 2>/dev/null); then TIMEOUT_PREFIX="$_to ${TIMEOUT}s "
  else
    echo "warning: no timeout binary found; --timeout ${TIMEOUT} cannot be enforced." >&2
    echo "         A mutant that hangs the suite will hang this run. Install coreutils, or pass --timeout 0 to silence this." >&2
  fi
fi

# BASELINE. Run the unmutated suite once before scoring anything. Without it a
# command that fails for its own reasons — a bad flag, a missing dependency, the
# wrong working directory — exits non-zero for every mutant and reports a clean
# sweep that proves nothing. A green baseline is the only thing that makes a
# later non-zero exit mean "the tests noticed".
if [[ "$DRY" -eq 0 && -n "$TEST_CMD" ]]; then
  echo "baseline: running the suite unmutated..."
  set +e
  ( eval "$TIMEOUT_PREFIX$TEST_CMD" ) >/dev/null 2>&1
  base_rc=$?
  set -e 2>/dev/null || true
  if [[ $base_rc -ne 0 ]]; then
    echo "" >&2
    echo "ABORT: the test command exits $base_rc on UNMUTATED code." >&2
    echo "  cmd: $TEST_CMD" >&2
    echo "  Every mutant would read as killed and the run would report a clean" >&2
    echo "  sweep proving nothing. Fix the command (or the suite) and re-run." >&2
    exit 2
  fi
  echo "baseline: green"
fi

BACKUP=$(mktemp -d)
declare -a PROTECTED=()

restore_all() {
  local f rel
  for rel in "${PROTECTED[@]-}"; do
    [[ -n "$rel" ]] || continue
    f="$BACKUP/$(printf '%s' "$rel" | tr '/' '_')"
    [[ -f "$f" ]] && cp "$f" "$rel"
  done
}
on_signal() { restore_all; echo "" >&2; echo "interrupted -- source files restored" >&2; exit 130; }
trap restore_all EXIT
trap on_signal INT TERM HUP

protect() {
  local rel="$1" f
  for existing in "${PROTECTED[@]-}"; do [[ "$existing" == "$rel" ]] && return 0; done
  f="$BACKUP/$(printf '%s' "$rel" | tr '/' '_')"
  cp "$rel" "$f"
  PROTECTED+=("$rel")
}

count=$(jq 'length' "$SPEC")

# ---- dry run -------------------------------------------------------------
if [[ $DRY -eq 1 ]]; then
  for ((i = 0; i < count; i++)); do
    file=$(jq -r ".[$i].file" "$SPEC")
    line=$(jq -r ".[$i].line" "$SPEC")
    desc=$(jq -r ".[$i].desc // \"\(.[$i].find) -> \(.[$i].replace)\"" "$SPEC")
    # Must read the SAME map shape as the live run below. This read `.[$f][$l]`
    # while the live path reads `.[$f].tests[$l]`, so every mutant showed
    # "0 covering test(s)" and anyone sizing a run concluded the whole diff was
    # uncovered. Distinguish import-time lines here too, for the same reason the
    # live run does: they have no per-test context but are very much under test.
    n="all"
    if [[ -n "$MAP" ]]; then
      n=$(jq -r --arg f "$file" --arg l "$line" '(.[$f].tests[$l] // []) | length' "$MAP")
      if [[ "$n" != "0" ]]; then
        n="$n covering test(s)"
      else
        if jq -e --arg f "$file" --argjson l "$line" '(.[$f].executed // []) | index($l)' "$MAP" >/dev/null; then
          n="import-time, full suite"
        else
          n="0 — nothing executes this line"
        fi
      fi
    fi
    printf '  m%-3s %s:%s  %s  [%s]\n' "$((i + 1))" "$file" "$line" "$desc" "$n"
  done
  exit 0
fi

# ---- run -----------------------------------------------------------------
killed=0; survived=0; uncovered=0; errored=0
results="[]"

for ((i = 0; i < count; i++)); do
  id="m$((i + 1))"
  file=$(jq -r ".[$i].file" "$SPEC")
  line=$(jq -r ".[$i].line" "$SPEC")
  find_s=$(jq -r ".[$i].find" "$SPEC")
  repl_s=$(jq -r ".[$i].replace" "$SPEC")
  desc=$(jq -r ".[$i].desc // \"\(.[$i].find) -> \(.[$i].replace)\"" "$SPEC")

  tests=""
  if [[ -n "$MAP" ]]; then
    tests=$(jq -r --arg f "$file" --arg l "$line" '(.[$f].tests[$l] // []) | join(" ")' "$MAP")
    override=$(jq -r ".[$i].tests // [] | join(\" \")" "$SPEC")
    [[ -n "$override" ]] && tests="$override"
    if [[ -z "$tests" ]]; then
      # No per-test context. Distinguish a line that never ran from one that ran
      # at import time (constants, defs) -- the latter has no context but is very
      # much under test, so it falls back to the full suite rather than skipping.
      if jq -e --arg f "$file" --argjson l "$line" '(.[$f].executed // []) | index($l)' "$MAP" >/dev/null; then
        printf '  %-11s %-5s %s  <- import-time line, running full suite\n' "..." "$id" "$desc"
      else
        printf '  %-11s %-5s %s  <- nothing executes this line\n' "no-coverage" "$id" "$desc"
        results=$(jq --argjson r "$(jq -n --arg i "$id" --arg f "$file" --argjson l "$line" --arg d "$desc" \
          '{id:$i,file:$f,line:$l,desc:$d,status:"no-coverage"}')" '. + [$r]' <<<"$results")
        uncovered=$((uncovered + 1)); continue
      fi
    fi
  fi

  if [[ ! -f "$file" ]]; then
    printf '  %-11s %-5s %s  <- no such file: %s\n' "ERROR" "$id" "$desc" "$file"
    errored=$((errored + 1)); continue
  fi

  protect "$file"

  # Literal first-occurrence replace on that line only. Values travel through
  # the environment so awk cannot reinterpret backslashes in them.
  if ! LN="$line" FIND="$find_s" REPL="$repl_s" awk '
      NR == ENVIRON["LN"] {
        p = index($0, ENVIRON["FIND"])
        if (p == 0) { exit 3 }
        $0 = substr($0, 1, p - 1) ENVIRON["REPL"] substr($0, p + length(ENVIRON["FIND"]))
      }
      { print }
    ' "$file" > "$BACKUP/mutated"; then
    printf '  %-11s %-5s %s  <- %s not found on line %s\n' "ERROR" "$id" "$desc" "$find_s" "$line"
    errored=$((errored + 1)); continue
  fi
  cp "$BACKUP/mutated" "$file"

  if [[ -n "$tests" ]]; then
    cmd="${SELECT_TMPL/\{tests\}/$tests}"
  else
    cmd="$TEST_CMD"
  fi

  # Those extra flags are pytest's. Appending them to anything else makes the
  # runner exit non-zero on an unknown option, which reads as "killed" for every
  # mutant and reports a clean sweep that proves nothing. Measured on vitest:
  # exit 1 with them, exit 0 without, on identical unmutated code.
  case "$cmd" in
    *pytest*) run="$cmd -q --no-cov -p no:cacheprovider -x" ;;
    *)        run="$cmd" ;;
  esac

  set +e
  # Subshell, because a `cd` inside the test command otherwise escapes into this
  # script and breaks every later relative path, the restore included. That has
  # already left a mutated file behind in a real tree.
  ( eval "$TIMEOUT_PREFIX$run" ) >/dev/null 2>&1
  rc=$?
  set -e 2>/dev/null || true

  # A mutant that hangs the suite — an inverted loop condition, say — would
  # otherwise hang the whole run. `timeout` reports 124 on expiry. Name it
  # rather than folding it into the kill count: the suite did not catch the
  # mutant, it failed to finish.
  if [[ $rc -eq 124 && -n "$TIMEOUT_PREFIX" ]]; then
    printf '  %-11s %-5s %s  <- exceeded %ss\n' "TIMEOUT" "$id" "$desc" "$TIMEOUT"
  fi

  restore_all

  if [[ $rc -ne 0 ]]; then status="killed"; killed=$((killed + 1))
  else status="SURVIVED"; survived=$((survived + 1)); fi

  ntests=$([[ -n "$tests" ]] && wc -w <<<"$tests" | tr -d ' ' || echo "all")
  printf '  %-11s %-5s %s  [%s test(s)]\n' "$status" "$id" "$desc" "$ntests"
  results=$(jq --argjson r "$(jq -n --arg i "$id" --arg f "$file" --argjson l "$line" \
    --arg d "$desc" --arg s "$status" '{id:$i,file:$f,line:$l,desc:$d,status:$s}')" '. + [$r]' <<<"$results")
done

restore_all

drift=0
for rel in "${PROTECTED[@]-}"; do
  [[ -n "$rel" ]] || continue
  f="$BACKUP/$(printf '%s' "$rel" | tr '/' '_')"
  if ! cmp -s "$f" "$rel"; then
    echo "!! NOT RESTORED: $rel" >&2; drift=1
  fi
done

echo ""
if [[ $drift -eq 1 ]]; then
  echo "!! FILES NOT RESTORED -- fix before doing anything else" >&2
  exit 3
fi

echo "  $killed killed, $survived SURVIVED, $uncovered uncovered, $errored error -- all files restored"
if [[ -n "$OUT" ]]; then
  printf '%s\n' "$results" > "$OUT"
  echo "  results -> $OUT"
fi
