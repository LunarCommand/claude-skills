#!/usr/bin/env bash
# Prints the absolute path of a file bundled with this plugin.
# Usage: adversarial_review_path.sh <bundled-filename>
#
# The workflow engines are handed to the Workflow tool as a scriptPath — a file
# to read, not a command to run — so unlike the other bundled scripts they are
# not on PATH and cannot be named directly. This resolves them instead.
#
# Do not replace this with a glob for the filename: more than one copy of the
# plugin can exist on a machine (a cached install under ~/.claude/plugins/cache/
# and a directory-source install pointing at a clone), they drift independently,
# and a glob picks whichever it finds first.
#
# Scope of the guarantee: this answers for the copy that CONTAINS THIS SCRIPT,
# which is not automatically the copy whose SKILL.md you are reading. Invoked by
# bare name, which copy runs is decided by PATH order across enabled plugin bins.
# That is still strictly better than globbing — the answer is always a real,
# self-consistent plugin directory rather than an arbitrary match — but if two
# copies are installed, prefer removing one.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: adversarial_review_path.sh <bundled-filename>

Prints the absolute path of a file bundled with this plugin, within whichever
copy of the plugin contains this script.

  adversarial_review_path.sh adversarial-review.workflow.js
  adversarial_review_path.sh spec-accept-review.workflow.js

The argument is a bare filename, never a path. Pass the result to the Workflow
tool as a scriptPath, copying it into the session scratchpad first — the tool
accepts a path only inside the working directory, and the plugin lives outside
every project it reviews.
USAGE
}

# --help is answered before the dependency preflight below: what the script does
# and what it needs are exactly what a reader without the tool installed is
# asking for, so exiting 127 at them is the one moment help is least useful.
# The leading `(` on the pattern is for bash 3.2, which macOS still ships.
for arg in "$@"; do
  case "$arg" in (-h|--help) usage; exit 0 ;; esac
done

if [[ $# -ne 1 ]]; then
  usage >&2
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
# Resolved from THIS script's own location, never a glob: bin/ sits at the
# plugin root, so one level up is the root and the engines live beside the skill
# they belong to. Resolving this way means the answer is always the copy that
# contains this script -- which is the point, since more than one copy of the
# plugin can exist on a machine and a glob cannot tell them apart.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_DIR="$PLUGIN_ROOT/skills/adversarial-review"
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
