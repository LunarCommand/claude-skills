#!/usr/bin/env bash
# Resolves a GitHub PR review thread via GraphQL.
# Usage: resolve_thread.sh <thread_node_id>
set -euo pipefail

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
