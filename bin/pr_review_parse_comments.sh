#!/usr/bin/env bash
# Fetches and parses unresolved GitHub PR review threads.
# Usage:
#   pr_review_parse_comments.sh <owner/repo> <pr_number>            # list all unresolved
#   pr_review_parse_comments.sh <owner/repo> <pr_number> <index>    # full detail by 1-based index
#   pr_review_parse_comments.sh <owner/repo> <pr_number> --id <id>  # full detail by comment database ID
set -euo pipefail

# Dependency preflight. Without it a missing binary surfaces mid-pipeline as
# `gh: command not found`, which reads as a bug in this script. The skill
# instructs the agent to fix a failing script rather than work around it, so an
# unclear failure sends it editing working code instead of naming the problem.
#
# gh only — the `--jq` filters below are gh's own embedded gojq engine, so the
# standalone jq binary is NOT required. Do not add `require_cmd jq` here: it
# refuses hosts where every code path would have worked.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "Missing required command: $1" >&2
  echo "  $2" >&2
  exit 127
}
require_cmd gh "Install the GitHub CLI and authenticate: https://cli.github.com then run 'gh auth login'."

if [[ $# -lt 2 ]]; then
  echo "Usage: pr_review_parse_comments.sh <owner/repo> <pr_number> [<index> | --id <id>]" >&2
  exit 1
fi

REPO="$1"
PR="$2"

if ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "Error: repo must be <owner>/<name>, got: $REPO" >&2
  exit 1
fi
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
  echo "Error: pr_number must be numeric, got: $PR" >&2
  exit 1
fi

OWNER="${REPO%%/*}"
NAME="${REPO#*/}"

# owner/name/number travel as typed GraphQL variables rather than being spliced
# into the document. Interpolation here let a crafted repo name close the string
# and append attacker-chosen selections, run with the user's gh token.
QUERY='query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
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

# -F assigns typed variables ($number arrives as an Int); -f would send strings.
gh_query() {
  gh api graphql \
    -F owner="$OWNER" \
    -F name="$NAME" \
    -F number="$PR" \
    -f query="$QUERY" \
    --jq "$1"
}

# --- Mode: --id <database_id> ---
if [[ "${3:-}" == "--id" ]]; then
  if [[ $# -lt 4 ]]; then
    echo "Error: --id requires a value, e.g. --id 123456789" >&2
    exit 1
  fi
  TARGET_ID="$4"
  # Numeric-only: this value is interpolated into the filter program below.
  if ! [[ "$TARGET_ID" =~ ^[0-9]+$ ]]; then
    echo "Error: --id must be numeric, got: $TARGET_ID" >&2
    exit 1
  fi
  gh_query '
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
  gh_query '
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
gh_query '
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
