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
# drift independently, and a glob picks whichever it finds first. This script
# ships inside the copy that is actually loaded, so it always answers for that
# copy.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: adversarial_review_path.sh <bundled-filename>" >&2
  echo "  e.g. adversarial_review_path.sh adversarial-review.workflow.js" >&2
  exit 1
fi

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
