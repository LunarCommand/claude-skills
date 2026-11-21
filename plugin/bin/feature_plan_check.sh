#!/usr/bin/env bash
# Checks a feature-planning plan file for traceability gaps.
# Usage: feature_plan_check.sh <plan-file>
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: feature_plan_check.sh <plan-file>

Checks a plan written by the feature-planning skill for the gaps its Coverage
rollup is supposed to make impossible:

  - a required heading is missing, or `## Status` appears more than once
  - an INV-<n> is declared in Invariants but absent from Coverage
  - a T-<n> is defined in Test Definitions but never cited
  - a T-<n> is cited by Coverage or `Verified by:` but never defined
  - an implementation phase carries no `Verified by:` line

Every check is textual. It can tell you a test ID is unreferenced; it cannot
tell you the test is worth writing, or that the mapping is honest.

Exit: 0 clean, 1 gaps found, 2 usage error.
USAGE
}

# --help is answered before anything else, including the argument check: what
# this script looks for is exactly what someone running it blind is asking.
# The leading `(` on the pattern is for bash 3.2, which macOS still ships.
for arg in "$@"; do
  case "$arg" in (-h|--help) usage; exit 0 ;; esac
done

# No require_cmd preflight: this reads one text file with awk, sed, tr, sort
# and grep. Requiring those would refuse hosts where every path would have
# worked, which is the same reason pr_review_resolve_thread.sh does not
# require jq.

if [[ $# -ne 1 ]]; then
  echo "Error: expected one plan file, got $#" >&2
  usage >&2
  exit 2
fi

PLAN="$1"
if [[ ! -f "$PLAN" ]]; then
  echo "Error: no such plan file: $PLAN" >&2
  exit 2
fi

# Body of one section, from its heading to the next heading of the same or a
# higher level. Interval expressions like /^#{1,2} / are avoided because the
# awk macOS ships does not support them.
section() {
  awk -v want="$1" '
    $0 == want { inside = 1; next }
    inside && ($0 ~ /^## / || $0 ~ /^# /) { inside = 0 }
    inside { print }
  ' "$PLAN"
}

# Every ID of one prefix on stdin, deduplicated. tr first so a line holding
# several — `**Phase 1** → T-1, T-2` — yields both; `grep -o` would be neater
# and is not POSIX.
ids() {
  tr -c 'A-Za-z0-9-' '\n' | grep "^$1-[0-9][0-9]*\$" | sort -u || true
}

findings=""
note() { findings="$findings
  $1"; }

# --- Required headings -----------------------------------------------------
for h in '## Invariants' '## Test Definitions' '## Coverage' \
         '## Implementation Plan' '## Status'; do
  grep -qxF "$h" "$PLAN" || note "missing heading: $h"
done

status_lines=$(grep -cxF '## Status' "$PLAN" || true)
if [[ "$status_lines" -gt 1 ]]; then
  note "## Status appears $status_lines times; it must appear exactly once"
fi

# --- Invariants reach Coverage ---------------------------------------------
coverage=$(section '## Coverage')
declared_inv=$(section '## Invariants' | ids INV)
covered_inv=$(printf '%s\n' "$coverage" | ids INV)
for inv in $declared_inv; do
  printf '%s\n' "$covered_inv" | grep -qx "$inv" \
    || note "$inv is declared in Invariants but absent from Coverage"
done

# --- Test IDs defined, cited, and matching --------------------------------
# A test is DEFINED by a definition line -- an optional list marker, then the
# bold ID at the start of the line, as the template writes it. Reading every
# T-<n> token in the section instead would let one prose sentence naming a test
# satisfy the cited-but-undefined check below, which is a silent pass in the
# exact case that check exists for. Permissive about what follows the ID on
# purpose: too strict reports a real test as undefined, which is noise someone
# fixes, while too loose is the failure this replaces.
defined_t=$(section '## Test Definitions' \
  | { grep '^[-* ]*\*\*T-[0-9]' || true; } | ids T)
# A citation is a Coverage row or a phase's `Verified by:` line. Both are read
# so a test cited in only one of them still counts as referenced.
cited_t=$( { printf '%s\n' "$coverage"; grep -F 'Verified by:' "$PLAN" || true; } | ids T)

for t in $defined_t; do
  printf '%s\n' "$cited_t" | grep -qx "$t" \
    || note "$t is defined in Test Definitions but never cited by Coverage or a phase"
done
for t in $cited_t; do
  printf '%s\n' "$defined_t" | grep -qx "$t" \
    || note "$t is cited but never defined in Test Definitions"
done

# --- Every phase cites its tests ------------------------------------------
# Phase headings and `Verified by:` lines in document order; a phase whose next
# marker is another phase heading has none of its own.
phase_report=$(awk '
  /^### Phase / { if (phase != "" && !seen) print "nocite:" phase
                  phase = $0; seen = 0; next }
  /Verified by:/ { if (phase != "") seen = 1 }
  /^## / { if (phase != "" && !seen) { print "nocite:" phase; phase = "" } }
  END { if (phase != "" && !seen) print "nocite:" phase }
' "$PLAN")
if [[ -n "$phase_report" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    note "no \`Verified by:\` line for ${line#nocite:}"
  done <<EOF
$phase_report
EOF
fi

# --- Report ---------------------------------------------------------------
if [[ -z "$findings" ]]; then
  echo "ok  $PLAN — every INV and T traced, every phase verified"
  exit 0
fi
echo "Traceability gaps in $PLAN:" >&2
printf '%s\n' "$findings" | sed '/^$/d' >&2
exit 1
