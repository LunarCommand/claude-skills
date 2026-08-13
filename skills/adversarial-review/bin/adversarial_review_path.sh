#!/usr/bin/env bash
# Prints the absolute path of a file bundled with this skill.
# Usage: adversarial_review_path.sh <bundled-filename>
#
# The workflow engines are handed to the Workflow tool as a scriptPath — a file
# to read, not a command to run — so unlike the other bundled scripts they are
# not on PATH and cannot be named directly. This resolves them instead.
#
# Do not replace this with a glob for the filename: more than one copy of the
# skill can exist on a machine (a marketplace install under
# ~/.claude/plugins/cache/ and a copied install under ~/.claude/skills/), they
# drift independently, and a glob picks whichever it finds first.
#
# Scope of the guarantee: this answers for the copy of the skill that CONTAINS
# THIS SCRIPT, which is not automatically the copy whose SKILL.md you are
# reading. Invoked by bare name, which copy runs is decided by PATH order across
# enabled plugin bins. That is still strictly better than globbing — the answer
# is always a real, self-consistent skill directory rather than an arbitrary
# match — but if two copies are installed, prefer removing one. install.sh and
# /plugin install are alternatives, not complements.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: adversarial_review_path.sh <bundled-filename>" >&2
  echo "  e.g. adversarial_review_path.sh adversarial-review.workflow.js" >&2
  exit 1
fi

# A bundled filename is flat, so anything path-shaped is rejected outright.
# Without this, `../../..`-bearing or absolute arguments resolve and get printed,
# and SKILL.md tells the caller to pass the result straight to the Workflow tool
# as a scriptPath — turning a pre-approved helper into an arbitrary-path oracle.
case "$1" in
  */*|..|.|"")
    echo "Error: expected a bare filename bundled with this skill, got: $1" >&2
    exit 1
    ;;
esac

# BASH_SOURCE[0] is the absolute path even when invoked by bare name from PATH.
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$SKILL_DIR/$1"

if [[ ! -f "$TARGET" ]]; then
  echo "No such file bundled with this skill: $1" >&2
  echo "Skill directory is: $SKILL_DIR" >&2
  echo "Available:" >&2
  # Portable listing — `find -printf` is GNU-only and this ships to macOS too.
  for f in "$SKILL_DIR"/*.workflow.js; do
    [[ -e "$f" ]] && echo "  $(basename "$f")" >&2
  done
  exit 1
fi

echo "$TARGET"
