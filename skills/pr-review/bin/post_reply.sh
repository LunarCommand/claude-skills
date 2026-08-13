#!/usr/bin/env bash
# Posts a reply to a GitHub PR review comment thread.
# Usage: post_reply.sh <owner/repo> <pr_number> <comment_id> <reply_text>
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

if [[ $# -ne 4 ]]; then
  echo "Usage: post_reply.sh <owner/repo> <pr_number> <comment_id> <reply_text>" >&2
  exit 1
fi

REPO="$1"
PR="$2"
COMMENT_ID="$3"
REPLY_TEXT="$4"

RESULT=$(gh api \
  --method POST \
  "repos/$REPO/pulls/$PR/comments/$COMMENT_ID/replies" \
  -f body="$REPLY_TEXT" \
  --jq '.id') || {
  echo "Error posting reply" >&2
  exit 1
}

echo "Reply posted — comment ID: $RESULT"
