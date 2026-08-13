#!/usr/bin/env bash
# Resolves a GitHub PR review thread via GraphQL.
# Usage: resolve_thread.sh <thread_node_id>
set -euo pipefail

# Dependency preflight. Without it a missing binary surfaces mid-pipeline as
# `gh: command not found`, which reads as a bug in this script. The skill
# instructs the agent to fix a failing script rather than work around it, so an
# unclear failure sends it editing working code instead of naming the problem.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "Missing required command: $1" >&2
  echo "  $2" >&2
  exit 127
}
require_cmd gh "Install the GitHub CLI and authenticate: https://cli.github.com then run 'gh auth login'."
require_cmd jq "Install jq — apt install jq, brew install jq, or https://jqlang.github.io/jq/"

if [[ $# -ne 1 ]]; then
  echo "Usage: resolve_thread.sh <thread_node_id>" >&2
  exit 1
fi

THREAD_ID="$1"

QUERY='mutation { resolveReviewThread(input: {threadId: "'"$THREAD_ID"'"}) { thread { isResolved } } }'

RESOLVED=$(gh api graphql -f query="$QUERY" --jq '.data.resolveReviewThread.thread.isResolved') || {
  echo "Error resolving thread: $THREAD_ID" >&2
  exit 1
}

echo "Thread $THREAD_ID resolved: $RESOLVED"
