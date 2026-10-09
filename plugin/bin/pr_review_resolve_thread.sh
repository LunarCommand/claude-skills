#!/usr/bin/env bash
# Resolves a GitHub PR review thread via GraphQL.
# Usage: pr_review_resolve_thread.sh <thread_node_id>
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: pr_review_resolve_thread.sh <thread_node_id>

Marks one pull-request review thread as resolved.

The node ID is the GraphQL id reported by pr_review_parse_comments.sh, not the
numeric comment id — they are different identifiers and only the node id works
here.
USAGE
}

# --help is answered before the dependency preflight below: what the script does
# and what it needs are exactly what a reader without the tool installed is
# asking for, so exiting 127 at them is the one moment help is least useful.
# The leading `(` on the pattern is for bash 3.2, which macOS still ships.
for arg in "$@"; do
  case "$arg" in (-h|--help) usage; exit 0 ;; esac
done

# Shared dependency preflight: require_cmd lives in lib/ beside this script,
# sourced by explicit path because bin/lib/ is not a PATH entry. A bare name
# WOULD resolve if the helper sat in bin/ itself; see
# plugin/bin/lib/require_cmd.sh for why it does not.
_require_cmd_lib="$(dirname "${BASH_SOURCE[0]}")/lib/require_cmd.sh"
if [[ -r "$_require_cmd_lib" ]]; then
  # shellcheck source=lib/require_cmd.sh
  . "$_require_cmd_lib"
else
  echo "Missing required file: $_require_cmd_lib" >&2
  echo "  This plugin install is incomplete; reinstall lunar." >&2
  exit 127
fi

# gh only — the `--jq` below is gh's own embedded gojq engine, so the standalone
# jq binary is NOT required. Do not add `require_cmd jq` here: it refuses hosts
# where every code path would have worked.
require_cmd gh "Install the GitHub CLI and authenticate: https://cli.github.com then run 'gh auth login'."

if [[ $# -ne 1 ]]; then
  usage >&2
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
