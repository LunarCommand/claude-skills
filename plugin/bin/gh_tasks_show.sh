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
reversed. They are read to a limit, so the output reports how many exist beside
how many were read, and warns when the two differ -- the body states only what
is true now, so an unread comment can be the whole answer.

Without --repo the board is consulted to find which repository holds the issue.
An issue reached that way is accepted only once the board it was sought on turns
up among the issue's own projects, so a same-numbered issue in an unrelated
repository is never returned as the task.
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
trap 'gh_tasks_cleanup' EXIT
trap 'gh_tasks_cleanup; exit 130' INT
trap 'gh_tasks_cleanup; exit 143' TERM

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
if [[ -n "$REPO" ]] && ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "Error: repo must be <owner>/<name>, got: $REPO" >&2
  exit 1
fi

CURRENT=""
RESOLUTION=explicit
BOARD_MORE=false
CANDIDATES=""

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
  EXACT="$(printf '%s\n' "$LOCATED" | awk -F'\t' '$1 == "EXACT" {print $2}')"
  CANDIDATES="$(printf '%s\n' "$LOCATED" | awk -F'\t' '$1 == "CANDIDATE" {print $2}')"
  BOARD_MORE="$(printf '%s\n' "$LOCATED" | awk -F'\t' '$1 == "MORE" {print $2; exit}')"
  EXACT_N="$(printf '%s' "$EXACT" | grep -c . || true)"

  if [[ "$EXACT_N" -gt 1 ]]; then
    echo "Error: the board carries issue #$ISSUE in more than one repository:" >&2
    printf '%s\n' "$EXACT" | sed 's/^/        /' >&2
    echo "  Name the one you mean: gh_tasks_show.sh $ISSUE --repo <owner>/<name>" >&2
    exit 1
  fi
  if [[ "$EXACT_N" -eq 1 ]]; then
    REPO="$EXACT"
    RESOLUTION=exact
  else
    # The issue is not among the board items read, so every repository the board
    # names is a place it could live. A candidate is accepted only if the issue
    # it holds turns out to be on this board, checked below.
    RESOLUTION=searched
    if [[ -z "$CANDIDATES" ]]; then
      echo "Error: no issues were found among the first 100 items of board $NUMBER under $LOGIN," >&2
      echo "  so there is no repository to look in for #$ISSUE." >&2
      echo "  Name it directly: gh_tasks_show.sh $ISSUE --repo <owner>/<name>" >&2
      exit 1
    fi
    # The repository the session is in is the likeliest holder, so it is tried
    # first; order otherwise follows board order.
    if [[ -n "$CURRENT" ]] && printf '%s\n' "$CANDIDATES" | grep -qxF "$CURRENT"; then
      CANDIDATES="$CURRENT
$(printf '%s\n' "$CANDIDATES" | grep -vxF "$CURRENT" || true)"
    fi
  fi
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
      labels(first: 20) { totalCount nodes { name } }
      assignees(first: 10) { totalCount nodes { login } }
      parent { number title state }
      subIssues(first: 20) { totalCount nodes { number title state } }
      comments(first: $comments) {
        totalCount
        nodes { author { login } createdAt body }
      }
      projectItems(first: 10) {
        totalCount
        nodes {
          project {
            number
            title
            url
            owner { ... on Organization { login } ... on User { login } }
          }
          fieldValues(first: __FIELDPAGE__) {
            totalCount
            nodes {__FIELDVALUES__
            }
          }
        }
      }
    }
  }
}'

# RESOLUTION is one of a fixed set of literals checked above, so interpolating
# it into the filter cannot introduce a program fragment.
SHOW_JQ='
    .data.repository.issue as $i |
    if $i == null then "null" else
    ([
      (if (($i.comments.nodes | length) < $i.comments.totalCount)
        then "read \(($i.comments.nodes | length)) of \($i.comments.totalCount) comments; re-run with a higher --comments before answering why something changed"
        else empty end),
      (if (($i.labels.totalCount // 0) > 20) then "more than 20 labels; only 20 were read" else empty end),
      (if (($i.assignees.totalCount // 0) > 10) then "more than 10 assignees; only 10 were read" else empty end),
      (if (($i.subIssues.totalCount // 0) > 20) then "\($i.subIssues.totalCount) sub-issues; only 20 were read" else empty end),
      (if (($i.projectItems.totalCount // 0) > 10) then "on more than 10 boards; only 10 were read" else empty end),
      (if ([($i.projectItems.nodes // [])[] | select((.fieldValues.totalCount // 0) > __FIELDPAGE__)] | length) > 0
        then "a board has more fields than were read; raise GH_TASKS_FIELD_PAGE" else empty end),
      (if ([($i.projectItems.nodes // [])[] | (.fieldValues.nodes // [])[] | select(.field.name == null)] | length) > 0
        then "this issue carries field values of a type these scripts do not decode; a field missing from a fields object may still have a value" else empty end),
      (if "__RESOLUTION__" == "searched"
        then "this issue was not among the board items read; it was found by searching the repositories the board names, and accepted because the board appears among its own projects"
        else empty end)
    ]) as $warnings |
    {
      issue:      $i.number,
      title:      $i.title,
      state:      $i.state,
      url:        $i.url,
      repo:       $i.repository.nameWithOwner,
      visibility: $i.repository.visibility,
      repoResolution: "__RESOLUTION__",
      author:     ($i.author.login // null),
      createdAt:  $i.createdAt,
      closedAt:   $i.closedAt,
      warnings:   $warnings,
      labels:     [($i.labels.nodes // [])[].name],
      assignees:  [($i.assignees.nodes // [])[].login],
      parent:     (if $i.parent == null then null else {number: $i.parent.number, title: $i.parent.title, state: $i.parent.state} end),
      subIssues:  {total: ($i.subIssues.totalCount // 0), read: (($i.subIssues.nodes // []) | length),
                   nodes: [($i.subIssues.nodes // [])[] | {number, title, state}]},
      body:       $i.body,
      comments: {
        total:    $i.comments.totalCount,
        read:     ($i.comments.nodes | length),
        nodes:    [$i.comments.nodes[] | {author: (.author.login // null), createdAt, body}]
      },
      boards: [($i.projectItems.nodes // [])[] | {
        owner:  (.project.owner.login // null),
        number: .project.number,
        title:  .project.title,
        url:    .project.url,
        fieldsUndecoded: ([(.fieldValues.nodes // [])[] | select(.field.name == null)] | length),
        fields: ([(.fieldValues.nodes // [])[]
                  | select(.field.name != null)
                  | {(.field.name): (
                      if   .text       != null then .text
                      elif .number     != null then .number
                      elif .date       != null then .date
                      elif .name       != null then .name
                      elif .title      != null then .title
                      elif .milestone  != null then .milestone.title
                      elif .repository != null then .repository.nameWithOwner
                      elif .options    != null then [.options[].name]
                      elif .labels     != null then [(.labels.nodes // [])[].name]
                      elif .users      != null then [(.users.nodes // [])[].login]
                      else null end)}]
                 | add // {})
      }]
    } | tojson end'

QUERY="$(gh_tasks_expand "$QUERY")" || exit $?
SHOW_JQ="$(gh_tasks_expand "$SHOW_JQ")" || exit $?
SHOW_JQ="${SHOW_JQ//__RESOLUTION__/$RESOLUTION}"

fetch_issue() {
  gh_tasks_api \
    -F owner="${1%%/*}" -F name="${1#*/}" -F issue="$ISSUE" -F comments="$COMMENTS" \
    -f query="$QUERY" --jq "$SHOW_JQ"
}

# A candidate holds the task only if the board it was sought on is one of the
# issue's own projects. Without that check, a repository that merely has an
# issue with the same number answers as the task: right number, wrong subject.
on_searched_board() {
  printf '%s' "$1" | grep -q "\"owner\":\"$LOGIN\",\"number\":$NUMBER,"
}

OUT=""
TRIED=""
REJECTED=""
for candidate in ${REPO:-$CANDIDATES}; do
  if ! [[ "$candidate" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "Error: implausible repository from the board: $candidate" >&2
    exit 1
  fi
  TRIED="$TRIED $candidate"

  # A missing scope, a permission denial and a rate limit are not "this
  # repository lacks the issue". gh_tasks_api's own exit for the scope case ends
  # only this substitution, so the status is captured and re-raised; anything
  # else non-zero is fatal rather than silently tried elsewhere.
  # gh's own message for a candidate that simply lacks the issue is noise the
  # caller's final error says better, so it is buffered and emitted only when
  # the failure turns out to be something the user must act on.
  status=0
  ERRBUF="$(mktemp "${TMPDIR:-/tmp}/gh-tasks-show.XXXXXX")" || {
    echo "Error: cannot create a temporary file." >&2
    exit 1
  }
  RESULT="$(fetch_issue "$candidate" 2>"$ERRBUF")" || status=$?
  if [[ "$status" -ne 0 && "$status" -ne 44 ]]; then
    cat "$ERRBUF" >&2
  fi
  rm -f "$ERRBUF"
  if [[ "$status" -eq 77 ]]; then
    exit 77
  fi
  if [[ "$status" -ne 0 && "$status" -ne 44 ]]; then
    echo "Error: could not read $candidate while looking for #$ISSUE (gh exited $status)." >&2
    echo "  This is not the same as the issue being absent; the message above says why." >&2
    exit "$status"
  fi
  if [[ "$status" -eq 44 || "$RESULT" == "null" ]]; then
    continue
  fi
  if [[ "$RESOLUTION" == "searched" ]] && ! on_searched_board "$RESULT"; then
    REJECTED="$REJECTED $candidate"
    continue
  fi
  OUT="$RESULT"
  break
done

if [[ -z "$OUT" ]]; then
  TRIED="${TRIED# }"
  echo "Error: no issue #$ISSUE belonging to this board was found in:" >&2
  printf '        %s\n' $TRIED >&2
  if [[ -n "$REJECTED" ]]; then
    REJECTED="${REJECTED# }"
    echo "  These hold an issue #$ISSUE that is not on the board, so it is not this task:" >&2
    printf '        %s\n' $REJECTED >&2
  fi
  if [[ "$BOARD_MORE" == "true" ]]; then
    echo "  The board continues past the 100 items that were read, so it may hold #$ISSUE" >&2
    echo "  in a repository not named above." >&2
  fi
  echo "  Name its repository directly: gh_tasks_show.sh $ISSUE --repo <owner>/<name>" >&2
  exit 1
fi

printf '%s\n' "$OUT"
