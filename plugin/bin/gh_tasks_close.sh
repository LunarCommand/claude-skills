#!/usr/bin/env bash
# Closes one task: a note first, then the close itself with a reason.
# Usage: gh_tasks_close.sh <issue_number> [--reason completed|not-planned|duplicate]
#                          [--duplicate-of N] [--note "text"]
#                          [--repo owner/name] [--owner login --number N]
#                          [--dry-run] [--public-ok]
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: gh_tasks_close.sh <issue_number> [options]

Closes one task and prints what it did as JSON. A note is posted before the
close, so the reason sits in the task's history and not only in its state.

Options:
  --reason <reason>      completed (default), not-planned or duplicate
  --duplicate-of N       the task this one duplicates; implies, and is required
                         by, --reason duplicate
  --note "text"          append a comment, posted before the close
  --repo owner/name      the repository holding the task (default: the current
                         one), which is also the repository the board is found
                         for
  --owner login          board owner, skipping discovery
  --number N             board number, skipping discovery
  --dry-run              resolve and print what would be sent, writing nothing
  --public-ok            permit writing to a PUBLIC repository
  -h, --help             this text

Closing is the one operation here with no undo: reopening is not implemented,
so a task closed by mistake has to be reopened by hand. Run --dry-run first if
the issue number came from anywhere but the user.

An already-closed task is refused rather than closed again, which would rewrite
the reason someone else had already settled on.

The task's board fields are left alone. A board that tracks state in a field as
well wants that field set with gh_tasks_update.sh, which this does not guess at.
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
NOTE=""
REASON=""
DUP=""
DRY=0
PUBLIC_OK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    (--reason)       REASON="${2:-}"; shift 2 ;;
    (--duplicate-of) DUP="${2:-}"; shift 2 ;;
    (--note)         NOTE="${2:-}"; shift 2 ;;
    (--repo)         REPO="${2:-}"; shift 2 ;;
    (--owner)        LOGIN="${2:-}"; shift 2 ;;
    (--number)       NUMBER="${2:-}"; shift 2 ;;
    (--dry-run)      DRY=1; shift ;;
    (--public-ok)    PUBLIC_OK=1; shift ;;
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

# --duplicate-of carries the reason, so naming both is only ever a contradiction
# to refuse, and a duplicate with nothing to point at loses the one fact that
# makes the reason worth recording.
[[ -n "$DUP" && -z "$REASON" ]] && REASON=duplicate
[[ -n "$REASON" ]] || REASON=completed
if [[ -n "$DUP" && "$REASON" != "duplicate" ]]; then
  echo "Error: --duplicate-of goes with --reason duplicate, not $REASON." >&2
  exit 1
fi
if [[ "$REASON" == "duplicate" && -z "$DUP" ]]; then
  echo "Error: --reason duplicate needs the task it duplicates: --duplicate-of N" >&2
  exit 1
fi
case "$REASON" in
  (completed)   STATE_REASON=COMPLETED ;;
  (not-planned) STATE_REASON=NOT_PLANNED ;;
  (duplicate)   STATE_REASON=DUPLICATE ;;
  (*)
    echo "Error: --reason must be completed, not-planned or duplicate, got: $REASON" >&2
    exit 1 ;;
esac
if [[ -n "$DUP" ]] && ! [[ "$DUP" =~ ^[0-9]+$ ]]; then
  echo "Error: --duplicate-of must be an issue number, got: $DUP" >&2
  exit 1
fi
if [[ -n "$DUP" && "$DUP" == "$ISSUE" ]]; then
  echo "Error: a task cannot duplicate itself." >&2
  exit 1
fi
if { [[ -n "$LOGIN" ]] && [[ -z "$NUMBER" ]]; } || { [[ -z "$LOGIN" ]] && [[ -n "$NUMBER" ]]; }; then
  echo "Error: --owner and --number go together." >&2
  exit 1
fi

[[ -n "$REPO" ]] || REPO="$(gh_tasks_detect_repo)"
if ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "Error: repo must be <owner>/<name>, got: $REPO" >&2
  exit 1
fi

DECLARED=unspecified
SOURCE=explicit
if [[ -z "$LOGIN" ]]; then
  # See gh_tasks_board.sh: the assignment has to carry the status, because a
  # `read` in front of the substitution would swallow a non-zero exit.
  DISCOVERED="$(gh_tasks_discover "$REPO")" || exit $?
  IFS=$'\t' read -r LOGIN NUMBER DECLARED SOURCE <<<"$DISCOVERED"
fi
if ! [[ "$NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: board number must be numeric, got: $NUMBER" >&2
  exit 1
fi
if ! [[ "$LOGIN" =~ ^[A-Za-z0-9-]{1,39}$ ]]; then
  echo "Error: board owner must be a GitHub login, got: $LOGIN" >&2
  exit 1
fi

RESOLVE_STATUS=0
RESOLVED="$(gh_tasks_resolve "$LOGIN" "$NUMBER" "$REPO" "$ISSUE")" || RESOLVE_STATUS=$?
if [[ "$RESOLVE_STATUS" -ne 0 ]]; then
  if [[ "$RESOLVE_STATUS" -eq 44 ]]; then
    case "$(gh_tasks_resolve_blame "$LOGIN" "$NUMBER" "$REPO")" in
      (repo)  echo "  There is no repository $REPO, or no access to it." >&2 ;;
      (board) gh_tasks_board_origin "$SOURCE" "$LOGIN" "$NUMBER" "$REPO" ;;
      (issue) echo "  $REPO has no issue #$ISSUE." >&2 ;;
    esac
  fi
  exit "$RESOLVE_STATUS"
fi

ISSUE_ID="$(gh_tasks_resolved "$RESOLVED" ISSUEID)"
if [[ -z "$ISSUE_ID" ]]; then
  echo "Error: $REPO has no issue #$ISSUE." >&2
  exit 44
fi
ITEM_ID="$(gh_tasks_resolved "$RESOLVED" ITEM)"
VIS="$(gh_tasks_resolved "$RESOLVED" REPOVIS)"
STATE="$(gh_tasks_resolved "$RESOLVED" ISSUESTATE)"
B_TITLE="$(gh_tasks_resolved "$RESOLVED" BOARDTITLE)"
B_URL="$(gh_tasks_resolved "$RESOLVED" BOARDURL)"
I_URL="$(gh_tasks_resolved "$RESOLVED" ISSUEURL)"
I_TITLE="$(gh_tasks_resolved "$RESOLVED" ISSUETITLE)"

gh_tasks_visibility_guard "$DECLARED" "$VIS" "$REPO" "$PUBLIC_OK"

if [[ "$STATE" == "CLOSED" ]]; then
  echo "Error: issue #$ISSUE is already closed, so nothing was changed." >&2
  echo "  Its reason is whatever it was closed with; this cannot rewrite it." >&2
  exit 1
fi

WARNINGS=""
add_warning() {
  [[ -n "$WARNINGS" ]] && WARNINGS="$WARNINGS,"
  WARNINGS="$WARNINGS$(gh_tasks_json_string "$1")"
}

[[ "$VIS" == "INTERNAL" ]] && add_warning "$REPO is INTERNAL, so this task is visible to everyone in the enterprise"
[[ -z "$ITEM_ID" ]] && add_warning "issue #$ISSUE is not on board $NUMBER under $LOGIN, so closing it changes no board item"

DUP_ID=""
if [[ -n "$DUP" ]]; then
  DSTATUS=0
  DUP_ID="$(gh_tasks_api -f owner="${REPO%%/*}" -f name="${REPO#*/}" -F num="$DUP" \
    -f query='query($owner: String!, $name: String!, $num: Int!) {
      repository(owner: $owner, name: $name) { issue(number: $num) { id } }
    }' --jq '.data.repository.issue.id // ""')" || DSTATUS=$?
  # gh has already named the number it could not resolve; this says which
  # lookup wanted it.
  if [[ "$DSTATUS" -eq 44 ]]; then
    echo "  $REPO has no issue #$DUP for this to duplicate." >&2
    exit 44
  fi
  [[ "$DSTATUS" -eq 0 ]] || exit "$DSTATUS"
  if [[ -z "$DUP_ID" ]]; then
    echo "Error: $REPO has no issue #$DUP for this to duplicate." >&2
    exit 44
  fi
fi

# A note that posted before a failed close has still changed the task, so what
# landed is reported rather than left for the user to find.
APPLIED=""
record() {
  [[ -n "$APPLIED" ]] && APPLIED="$APPLIED,"
  APPLIED="$APPLIED$1"
}
report_partial() {
  [[ -n "$APPLIED" ]] || return 0
  echo "Stopped part way. What was already applied to #$ISSUE:" >&2
  printf '      %s\n' "$APPLIED" >&2
}
MUT_OUT=""
mutate() {
  local status=0
  MUT_OUT="$(gh_tasks_api "$@")" || status=$?
  if [[ "$status" -ne 0 ]]; then
    report_partial
    exit "$status"
  fi
}

# The note goes first: a close is what a reader sees in the timeline, and a
# reason posted after it reads as a remark about an already-settled task.
if [[ -n "$NOTE" ]]; then
  if [[ "$DRY" -eq 1 ]]; then
    record "{\"comment\": $(gh_tasks_json_string "$NOTE")}"
  else
    mutate -f sub="$ISSUE_ID" -f body="$NOTE" \
      -f query='mutation($sub: ID!, $body: String!) {
        addComment(input: {subjectId: $sub, body: $body}) {
          commentEdge { node { url } }
        }
      }' --jq '.data.addComment.commentEdge.node.url | tojson'
    record "{\"comment\": $MUT_OUT}"
  fi
fi

NEW_REASON=""
if [[ "$DRY" -eq 1 ]]; then
  record "{\"closed\": \"$STATE_REASON\"}"
else
  DUP_ARGS=()
  [[ -n "$DUP_ID" ]] && DUP_ARGS=(-f dup="$DUP_ID")
  mutate -f id="$ISSUE_ID" -f reason="$STATE_REASON" \
    ${DUP_ARGS[@]+"${DUP_ARGS[@]}"} \
    -f query='mutation($id: ID!, $reason: IssueClosedStateReason!, $dup: ID = null) {
      closeIssue(input: {issueId: $id, stateReason: $reason, duplicateIssueId: $dup}) {
        issue { state stateReason }
      }
    }' --jq '"\(.data.closeIssue.issue.state)\t\(.data.closeIssue.issue.stateReason)"'
  NEW_REASON="$(printf '%s' "$MUT_OUT" | awk -F'\t' '{ print $2; exit }')"
  STATE="$(printf '%s' "$MUT_OUT" | awk -F'\t' '{ print $1; exit }')"
  record "{\"closed\": \"${NEW_REASON:-$STATE_REASON}\"}"
  # GitHub answers with the reason it stored, so a reason that did not take is
  # visible here rather than only on the board days later.
  [[ -z "$NEW_REASON" || "$NEW_REASON" == "$STATE_REASON" ]] \
    || add_warning "asked to close as $STATE_REASON but GitHub recorded $NEW_REASON"
fi

printf '{\n'
printf '  "action": "close",\n'
printf '  "dryRun": %s,\n' "$([[ "$DRY" -eq 1 ]] && echo true || echo false)"
printf '  "board": {"owner": "%s", "number": %s, "title": %s, "url": %s},\n' \
  "$LOGIN" "$NUMBER" "${B_TITLE:-null}" "${B_URL:-null}"
printf '  "discovery": {"source": "%s", "declaredVisibility": "%s"},\n' "$SOURCE" "$DECLARED"
printf '  "repo": "%s",\n' "$REPO"
printf '  "visibility": "%s",\n' "$VIS"
printf '  "issue": %s,\n' "$ISSUE"
printf '  "title": %s,\n' "${I_TITLE:-null}"
printf '  "state": "%s",\n' "$STATE"
printf '  "url": %s,\n' "${I_URL:-null}"
printf '  "onBoard": %s,\n' "$([[ -n "$ITEM_ID" ]] && echo true || echo false)"
printf '  "reason": "%s",\n' "$STATE_REASON"
printf '  "duplicateOf": %s,\n' "${DUP:-null}"
printf '  "%s": [%s],\n' "$([[ "$DRY" -eq 1 ]] && echo planned || echo applied)" "$APPLIED"
printf '  "warnings": [%s]\n' "$WARNINGS"
printf '}\n'
