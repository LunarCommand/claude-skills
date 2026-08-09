#!/usr/bin/env bash
# Fetches and parses unresolved GitHub PR review threads.
# Usage:
#   parse_comments.sh <owner/repo> <pr_number>              # list all unresolved
#   parse_comments.sh <owner/repo> <pr_number> <index>      # full detail by 1-based index
#   parse_comments.sh <owner/repo> <pr_number> --id <id>    # full detail by comment database ID
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: parse_comments.sh <owner/repo> <pr_number> [<index> | --id <id>]" >&2
  exit 1
fi

REPO="$1"
PR="$2"
OWNER="${REPO%%/*}"
NAME="${REPO#*/}"

QUERY='{
  repository(owner: "'"$OWNER"'", name: "'"$NAME"'") {
    pullRequest(number: '"$PR"') {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          comments(first: 10) {
            nodes {
              id
              databaseId
              path
              line
              originalLine
              body
              author { login }
            }
          }
        }
      }
    }
  }
}'

# --- Mode: --id <database_id> ---
if [[ "${3:-}" == "--id" ]]; then
  if [[ $# -lt 4 ]]; then
    echo "Error: --id requires a value, e.g. --id 123456789" >&2
    exit 1
  fi
  TARGET_ID="$4"
  gh api graphql -f query="$QUERY" --jq '
    .data.repository.pullRequest.reviewThreads.nodes as $all |
    [$all[] | select(.isResolved == false)] as $unresolved |
    (
      $unresolved | to_entries[] |
      select(.value.comments.nodes | any(.databaseId == '"$TARGET_ID"'))
    ) // (
      $all[] | select(.isResolved == true) |
      select(.comments.nodes | any(.databaseId == '"$TARGET_ID"')) |
      {"key": "?", "value": .} | . + {"resolved_note": true}
    ) |
    (if .resolved_note then "Note: this thread is already resolved\n" else "" end) +
    "[\(if .key == "?" then "?" else (.key + 1 | tostring) end)] Thread Node ID: \(.value.id)\n" +
    "     Comment ID:     \(.value.comments.nodes[0].databaseId)\n" +
    "     File:           \(.value.comments.nodes[0].path):\(.value.comments.nodes[0].line // .value.comments.nodes[0].originalLine // "?")\n" +
    "     Author:         \(.value.comments.nodes[0].author.login)\n" +
    "     Body:\n\(.value.comments.nodes[0].body)" +
    (if (.value.comments.nodes | length) > 1 then
      "\n\n     Replies (\(.value.comments.nodes | length - 1)):\n" +
      ([.value.comments.nodes[1:][] |
        "       [\(.author.login)]: \(.body)"] | join("\n"))
    else "" end) +
    "\n"
  '
  exit 0
fi

# --- Mode: single index ---
if [[ $# -eq 3 ]]; then
  INDEX="$3"
  if ! [[ "$INDEX" =~ ^[0-9]+$ ]]; then
    echo "Error: unrecognised argument '$INDEX'" >&2
    exit 1
  fi
  gh api graphql -f query="$QUERY" --jq '
    [.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] |
    if ('"$INDEX"' < 1) or ('"$INDEX"' > length) then
      "Error: index '"$INDEX"' out of range (1-\(length))" | halt_error(1)
    else . end |
    .['"$INDEX"' - 1] |
    "['"$INDEX"'] Thread Node ID: \(.id)\n" +
    "     Comment ID:     \(.comments.nodes[0].databaseId)\n" +
    "     File:           \(.comments.nodes[0].path):\(.comments.nodes[0].line // .comments.nodes[0].originalLine // "?")\n" +
    "     Author:         \(.comments.nodes[0].author.login)\n" +
    "     Body:\n\(.comments.nodes[0].body)" +
    (if (.comments.nodes | length) > 1 then
      "\n\n     Replies (\(.comments.nodes | length - 1)):\n" +
      ([.comments.nodes[1:][] |
        "       [\(.author.login)]: \(.body)"] | join("\n"))
    else "" end) +
    "\n"
  '
  exit 0
fi

# --- Mode: list all unresolved ---
gh api graphql -f query="$QUERY" --jq '
  .data.repository.pullRequest.reviewThreads.nodes as $all |
  [$all[] | select(.isResolved == false)] as $unresolved |
  "Total threads: \($all | length), Unresolved: \($unresolved | length)\n\n" +
  ([$unresolved | to_entries[] |
    "[\(.key + 1)] Thread Node ID: \(.value.id)\n" +
    "     Comment ID:     \(.value.comments.nodes[0].databaseId)\n" +
    "     File:           \(.value.comments.nodes[0].path):\(.value.comments.nodes[0].line // .value.comments.nodes[0].originalLine // "?")\n" +
    "     Author:         \(.value.comments.nodes[0].author.login)\n" +
    "     Body:           \(.value.comments.nodes[0].body | gsub("\n"; " ") | .[:300])\n"
  ] | join("\n"))
'
