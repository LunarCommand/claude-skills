#!/usr/bin/env bash
# Build a line -> covering-tests map from per-test coverage contexts.
#
#   mutation_test_build_map.sh --files utils/logging_config.py utils/telemetry.py --out map.json
#
# This is what removes test selection from the user's hands: test names are
# derived from what actually EXECUTES each line, so a suite whose filenames do
# not mirror its source layout maps correctly anyway.
#
# LANGUAGE SUPPORT. Per-test coverage contexts are a coverage.py feature. Jest,
# c8/istanbul and `go test -coverprofile` record which lines ran, but not which
# TEST ran them, so there is nothing to build a map from. This script therefore
# supports Python only, and exits 4 elsewhere. That is not a dead end: the map
# is an OPTIMISATION. mutation_test_run_mutants.sh without --map runs the full test command
# per mutant, which works on any stack.

set -euo pipefail

FILES=()
TESTS=()
OUT=""
TEST_CMD=""
ROOT="."

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --files)    shift; while [[ $# -gt 0 && "$1" != --* ]]; do FILES+=("$1"); shift; done ;;
    --tests)    shift; while [[ $# -gt 0 && "$1" != --* ]]; do TESTS+=("$1"); shift; done ;;
    --out)      OUT="$2"; shift 2 ;;
    --test-cmd) TEST_CMD="$2"; shift 2 ;;
    --root)     ROOT="$2"; shift 2 ;;
    -h|--help)  usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

[[ ${#FILES[@]} -gt 0 ]] || { echo "ERROR: --files is required" >&2; exit 1; }
[[ -n "$OUT" ]] || { echo "ERROR: --out is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 2; }

cd "$ROOT"

for f in "${FILES[@]}"; do
  [[ "$f" == *.py ]] || {
    cat >&2 <<EOF
ERROR: '$f' is not a Python file.

Per-test coverage contexts exist only in coverage.py. Other ecosystems record
line coverage but not which test produced it, so no map can be built.

Run without a map instead -- it works on any stack, just slower:
  mutation_test_run_mutants.sh --spec mutants.json --test-cmd '<your full test command>'
EOF
    exit 4
  }
done

if [[ -z "$TEST_CMD" ]]; then
  if   [[ -f uv.lock ]];     then TEST_CMD="uv run pytest"
  elif [[ -f poetry.lock ]]; then TEST_CMD="poetry run pytest"
  else                            TEST_CMD="python -m pytest"
  fi
fi
# The reporter must come from the same environment as the runner.
COV_CMD="${TEST_CMD% pytest} coverage"
[[ "$COV_CMD" == "$TEST_CMD" ]] && COV_CMD="coverage"

# Keep the context DB out of the repo: a stale ./.coverage from a previous
# `make test` has no contexts, and reading one by mistake yields a map whose
# every context is the empty string -- which looks like "1 covering test".
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export COVERAGE_FILE="$TMP/.coverage"

cov_args=()
for f in "${FILES[@]}"; do cov_args+=("--cov=$f"); done

echo "\$ $TEST_CMD ${TESTS[*]-} --cov-context=test" >&2
set +e
# shellcheck disable=SC2086
$TEST_CMD "${TESTS[@]-}" -q -p no:cacheprovider \
  --cov-context=test --cov-fail-under=0 --cov-report= "${cov_args[@]}"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  cat >&2 <<'EOF'

WARNING: the suite exited non-zero while building the map.
A map from a red suite is unreliable -- tests that errored register no context
at all, so their lines read as uncovered. Get the suite green first.
EOF
fi

# shellcheck disable=SC2086
$COV_CMD json --show-contexts -o "$TMP/cov.json" >/dev/null

# Two facts per file, not one. `tests` maps a line to the tests that executed
# it. `executed` is every line that ran at all -- including module-level lines
# (constants, imports, def/class statements) which run at IMPORT, before any
# test starts, and so are recorded under no test context. Those are not
# uncovered: collapsing the two made a mutation on a threshold constant report
# "nothing executes this line" when the suite in fact kills it.
jq --argjson want "$(printf '%s\n' "${FILES[@]}" | jq -R -s 'split("\n") | map(select(length>0))')" '
  .files
  | with_entries(
      .key |= sub("^\\./"; "")
    )
  | with_entries(select(.key as $k | $want | index($k)))
  | with_entries(
      .value |= {
        executed: (.executed_lines // []),
        tests: (
          (.contexts // {})
          | with_entries(
              .value |= (map(split("|")[0]) | map(select(length > 0)) | unique)
            )
          | with_entries(select(.value | length > 0))
        )
      }
    )
' "$TMP/cov.json" > "$OUT"

echo "" >&2
echo "map -> $OUT" >&2
jq -r 'to_entries[] | "  \(.key): \(.value.tests | length) line(s) with per-test contexts, " +
       "\(.value.executed | length) executed, " +
       "\([.value.tests[][]] | unique | length) distinct test(s)"' "$OUT" >&2
echo "  (executed-but-context-free lines are import-time; they fall back to the full suite)" >&2
for f in "${FILES[@]}"; do
  jq -e --arg f "$f" 'has($f)' "$OUT" >/dev/null || echo "  $f: NOT MEASURED -- no coverage recorded" >&2
done
