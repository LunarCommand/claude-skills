#!/usr/bin/env bash
# Posts a reply to a GitHub PR review comment thread.
# Usage: post_reply.sh <owner/repo> <pr_number> <comment_id> <reply_text>
set -euo pipefail

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
