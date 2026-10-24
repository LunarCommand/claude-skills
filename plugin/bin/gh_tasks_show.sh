#!/usr/bin/env bash
# Reads one task in full and prints it as JSON for the model to narrate.
# Usage: gh_tasks_show.sh <issue_number> [--repo owner/name]
#                         [--owner login --number N] [--comments N]
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: gh_tasks_show.sh <issue_number> [options]

Prints one task in full as a single JSON object: the issue, its board field
values, its parent and sub-issues, and its comments.

Options:
  --repo owner/name    the repository holding the issue, skipping the board
                       lookup that would otherwise find it
  --owner login        board owner, skipping discovery
  --number N           board number, skipping discovery
  --comments N         how many comments to read, 1-100 (default: 50)
  -h, --help           this text

Comments are the task's history: a change of mind, a correction, a ruling
reversed. They are read in full rather than counted, because the body states
only what is true now.
USAGE
}

# --help is answered before the dependency preflight below: what the script does
# and what it needs are exactly what a reader without the tool installed is
# asking for, so exiting 127 at them is the one moment help is least useful.
# The leading `(` on the pattern is for bash 3.2, which macOS still ships.
for arg in "$@"; do
  case "$arg" in (-h|--help) usage; exit 0 ;; esac
done

_lib="$(dirname "${BASH_SOURCE[0]}")/lib/gh_tasks_lib.sh"
if [[ -r "$_lib" ]]; then
  # shellcheck source=lib/gh_tasks_lib.sh
  . "$_lib"
else
  echo "Missing required file: $_lib" >&2
  echo "  This plugin install is incomplete; reinstall lunar." >&2
  exit 127
fi
gh_tasks_preflight

ISSUE=""
REPO=""
LOGIN=""
NUMBER=""
COMMENTS=50

while [[ $# -gt 0 ]]; do
  case "$1" in
    (--repo)     REPO="${2:-}"; shift 2 ;;
    (--owner)    LOGIN="${2:-}"; shift 2 ;;
    (--number)   NUMBER="${2:-}"; shift 2 ;;
    (--comments) COMMENTS="${2:-}"; shift 2 ;;
    (-*) echo "Error: unrecognised argument '$1'" >&2; usage >&2; exit 1 ;;
    (*)
      if [[ -n "$ISSUE" ]]; then
        echo "Error: more than one issue number given: $ISSUE and $1" >&2
        exit 1
      fi
      ISSUE="$1"; shift ;;
  esac
done

if [[ -z "$ISSUE" ]]; then
  usage >&2
  exit 1
fi
if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "Error: issue number must be numeric, got: $ISSUE" >&2
  exit 1
fi
if ! [[ "$COMMENTS" =~ ^[0-9]+$ ]] || [[ "$COMMENTS" -lt 1 ]] || [[ "$COMMENTS" -gt 100 ]]; then
  echo "Error: --comments must be 1-100, got: $COMMENTS" >&2
  exit 1
fi
if { [[ -n "$LOGIN" ]] && [[ -z "$NUMBER" ]]; } || { [[ -z "$LOGIN" ]] && [[ -n "$NUMBER" ]]; }; then
  echo "Error: --owner and --number go together." >&2
  exit 1
fi

# --repo skips the board entirely, which is the fast path and the only one that
# works for an issue the board does not carry.
if [[ -z "$REPO" ]]; then
  if [[ -z "$LOGIN" ]]; then
    CURRENT="$(gh_tasks_detect_repo)"
    # See gh_tasks_board.sh: the assignment has to carry the status, because a
    # `read` in front of the substitution would swallow a non-zero exit.
    DISCOVERED="$(gh_tasks_discover "$CURRENT")" || exit $?
    IFS=$'\t' read -r LOGIN NUMBER _DECLARED _SOURCE <<<"$DISCOVERED"
  fi
  if ! [[ "$NUMBER" =~ ^[0-9]+$ ]]; then
    echo "Error: board number must be numeric, got: $NUMBER" >&2
    exit 1
  fi
  LOCATED="$(gh_tasks_locate_issue "$LOGIN" "$NUMBER" "$ISSUE")" || exit $?
  REPO="$(printf '%s\n' "$LOCATED" | awk -F'\t' '$1 == "EXACT" {print $2; exit}')"
  # No exact hit only means the issue is not on the board's first page. The
  # repositories that page named are still where it would live, so they are
  # tried in turn rather than making the caller supply what the board knows.
  CANDIDATES="$(printf '%s\n' "$LOCATED" | awk -F'\t' '$1 == "CANDIDATE" {print $2}')"
  if [[ -z "$REPO" && -z "$CANDIDATES" ]]; then
    echo "Error: board $NUMBER under $LOGIN holds no issues, so #$ISSUE cannot be located." >&2
    echo "  Name its repository directly: gh_tasks_show.sh $ISSUE --repo <owner>/<name>" >&2
    exit 1
  fi
fi

if [[ -n "$REPO" ]] && ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "Error: repo must be <owner>/<name>, got: $REPO" >&2
  exit 1
fi

QUERY='query($owner: String!, $name: String!, $issue: Int!, $comments: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $issue) {
      number
      title
      state
      url
      body
      createdAt
      closedAt
      author { login }
      repository { nameWithOwner visibility }
      labels(first: 20) { nodes { name } }
      assignees(first: 10) { nodes { login } }
      parent { number title state }
      subIssues(first: 20) { nodes { number title state } }
      comments(first: $comments) {
        totalCount
        nodes { author { login } createdAt body }
      }
      projectItems(first: 10) {
        nodes {
          project { number title url }
          fieldValues(first: __FIELDPAGE__) {
            totalCount
            nodes {
              ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { name } } }
              ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { name } } }
              ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { name } } }
              ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } }
            }
          }
        }
      }
    }
  }
}'

SHOW_JQ='
    .data.repository.issue as $i |
    if $i == null then "null" else
    {
      issue:      $i.number,
      title:      $i.title,
      state:      $i.state,
      url:        $i.url,
      repo:       $i.repository.nameWithOwner,
      visibility: $i.repository.visibility,
      author:     ($i.author.login // null),
      createdAt:  $i.createdAt,
      closedAt:   $i.closedAt,
      labels:     [($i.labels.nodes // [])[].name],
      assignees:  [($i.assignees.nodes // [])[].login],
      parent:     (if $i.parent == null then null else {number: $i.parent.number, title: $i.parent.title, state: $i.parent.state} end),
      subIssues:  [($i.subIssues.nodes // [])[] | {number, title, state}],
      body:       $i.body,
      comments: {
        total:    $i.comments.totalCount,
        read:     ($i.comments.nodes | length),
        nodes:    [$i.comments.nodes[] | {author: (.author.login // null), createdAt, body}]
      },
      boards: [($i.projectItems.nodes // [])[] | {
        number: .project.number,
        title:  .project.title,
        url:    .project.url,
        fieldsTruncated: ((.fieldValues.totalCount // 0) > __FIELDPAGE__),
        fields: ([(.fieldValues.nodes // [])[]
                  | select(.field.name != null)
                  | {(.field.name): (.text // .number // .date // .name)}]
                 | add // {})
      }]
    } | tostring end'

QUERY="$(gh_tasks_expand "$QUERY")" || exit $?
SHOW_JQ="$(gh_tasks_expand "$SHOW_JQ")" || exit $?

fetch_issue() {
  gh_tasks_api \
    -F owner="${1%%/*}" -F name="${1#*/}" -F issue="$ISSUE" -F comments="$COMMENTS" \
    -f query="$QUERY" --jq "$SHOW_JQ"
}

OUT=""
TRIED=""
for candidate in ${REPO:-$CANDIDATES}; do
  if ! [[ "$candidate" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "Error: implausible repository from the board: $candidate" >&2
    exit 1
  fi
  TRIED="$TRIED $candidate"
  # A repository that denies access or does not exist is a different failure
  # from one that simply lacks the issue, and only the latter is worth trying
  # the next candidate for.
  if ! RESULT="$(fetch_issue "$candidate")"; then
    continue
  fi
  if [[ "$RESULT" != "null" ]]; then
    OUT="$RESULT"
    break
  fi
done

if [[ -z "$OUT" ]]; then
  echo "Error: no issue #$ISSUE in:${TRIED// /$'\n        '}" >&2
  echo "  Name its repository directly: gh_tasks_show.sh $ISSUE --repo <owner>/<name>" >&2
  exit 1
fi

printf '%s\n' "$OUT"
