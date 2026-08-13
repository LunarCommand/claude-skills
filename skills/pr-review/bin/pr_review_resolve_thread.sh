#!/usr/bin/env bash
# Resolves a GitHub PR review thread via GraphQL.
# Usage: pr_review_resolve_thread.sh <thread_node_id>
set -euo pipefail

# Dependency preflight. Without it a missing binary surfaces mid-pipeline as
# `gh: command not found`, which reads as a bug in this script. The skill
# instructs the agent to fix a failing script rather than work around it, so an
# unclear failure sends it editing working code instead of naming the problem.
#
# gh only — the `--jq` below is gh's own embedded gojq engine, so the standalone
# jq binary is NOT required. Do not add `require_cmd jq` here: it refuses hosts
# where every code path would have worked.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "Missing required command: $1" >&2
  echo "  $2" >&2
  exit 127
}
require_cmd gh "Install the GitHub CLI and authenticate: https://cli.github.com then run 'gh auth login'."

if [[ $# -ne 1 ]]; then
  echo "Usage: pr_review_resolve_thread.sh <thread_node_id>" >&2
  exit 1
fi

THREAD_ID="$1"

# Node IDs are opaque base64-ish tokens. Reject anything else before it reaches
# the API: this input originates in a pull request, which is attacker-influenced
# content on any public repo.
if ! [[ "$THREAD_ID" =~ ^[A-Za-z0-9_=-]+$ ]]; then
  echo "Error: implausible thread node ID: $THREAD_ID" >&2
  exit 1
fi

# The ID travels as a typed GraphQL variable, never spliced into the document.
# String interpolation here let a crafted ID close the quote and append
# attacker-chosen mutations, executed with the user's gh token.
QUERY='mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread { isResolved }
  }
}'

RESOLVED=$(gh api graphql \
  -F threadId="$THREAD_ID" \
  -f query="$QUERY" \
  --jq '.data.resolveReviewThread.thread.isResolved') || {
  echo "Error resolving thread: $THREAD_ID" >&2
  exit 1
}

echo "Thread $THREAD_ID resolved: $RESOLVED"
