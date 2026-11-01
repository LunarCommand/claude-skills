#!/usr/bin/env bash
# Changes one task: its board fields, a note appended as a comment, its parent.
# Usage: gh_tasks_update.sh <issue_number> [--field "Name=Value"]...
#                           [--clear "Name"]... [--note "text"] [--parent N]
#                           [--repo owner/name] [--owner login --number N]
#                           [--dry-run] [--public-ok]
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: gh_tasks_update.sh <issue_number> [options]

Changes one task and prints what it changed as JSON. Field values and the
parent are set; a note is appended as a comment, never replacing the body.

Options:
  --field "Name=Value"   set a board field, repeatable
  --clear "Name"         unset a board field, repeatable
  --note "text"          append a comment
  --parent N             make issue N this task's parent
  --repo owner/name      the repository holding the task (default: the current
                         one), which is also the repository the board is found
                         for
  --owner login          board owner, skipping discovery
  --number N             board number, skipping discovery
  --dry-run              resolve and print what would be sent, writing nothing
  --public-ok            permit writing to a PUBLIC repository
  -h, --help             this text

Field and value names are matched against the board's own field list, exactly
first and then ignoring case, and a name matching more than one field is
refused rather than guessed. Nothing is written for a name the board does not
have.

A field the board derives from the issue -- its title, labels, assignees or
milestone -- is not stored on the board and is refused with the place it does
live. Multi-select fields are not written yet.

The body is never rewritten. A task's body says what is true now and its
comments are its history, so a correction is a comment.
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
PARENT=""
DRY=0
PUBLIC_OK=0
SETS=()
CLEARS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    (--field)     SETS+=("${2:-}"); shift 2 ;;
    (--clear)     CLEARS+=("${2:-}"); shift 2 ;;
    (--note)      NOTE="${2:-}"; shift 2 ;;
    (--parent)    PARENT="${2:-}"; shift 2 ;;
    (--repo)      REPO="${2:-}"; shift 2 ;;
    (--owner)     LOGIN="${2:-}"; shift 2 ;;
    (--number)    NUMBER="${2:-}"; shift 2 ;;
    (--dry-run)   DRY=1; shift ;;
    (--public-ok) PUBLIC_OK=1; shift ;;
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
if [[ -n "$PARENT" ]] && ! [[ "$PARENT" =~ ^[0-9]+$ ]]; then
  echo "Error: --parent must be an issue number, got: $PARENT" >&2
  exit 1
fi
if [[ -n "$PARENT" && "$PARENT" == "$ISSUE" ]]; then
  echo "Error: a task cannot be its own parent." >&2
  exit 1
fi
if { [[ -n "$LOGIN" ]] && [[ -z "$NUMBER" ]]; } || { [[ -z "$LOGIN" ]] && [[ -n "$NUMBER" ]]; }; then
  echo "Error: --owner and --number go together." >&2
  exit 1
fi
if [[ ${#SETS[@]} -eq 0 && ${#CLEARS[@]} -eq 0 && -z "$NOTE" && -z "$PARENT" ]]; then
  echo "Error: nothing to change. Give --field, --clear, --note or --parent." >&2
  exit 1
fi
for spec in ${SETS[@]+"${SETS[@]}"}; do
  case "$spec" in
    (*=*) ;;
    (*) echo "Error: --field takes Name=Value, got: $spec" >&2; exit 1 ;;
  esac
done

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

PROJECT_ID="$(gh_tasks_resolved "$RESOLVED" PROJECT)"
[[ -n "$PROJECT_ID" ]] || { echo "Error: no board $NUMBER under $LOGIN, or no access to it." >&2; exit 1; }
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
FIELDS_TOTAL="$(gh_tasks_resolved "$RESOLVED" FIELDSTOTAL)"
FIELD_PAGE="$(gh_tasks_field_page)" || exit $?

gh_tasks_visibility_guard "$DECLARED" "$VIS" "$REPO" "$PUBLIC_OK"

WARNINGS=""
add_warning() {
  [[ -n "$WARNINGS" ]] && WARNINGS="$WARNINGS,"
  WARNINGS="$WARNINGS$(gh_tasks_json_string "$1")"
}

[[ "$STATE" == "CLOSED" ]] && add_warning "issue #$ISSUE is closed; the change was applied to a closed task"
[[ "$VIS" == "INTERNAL" ]] && add_warning "$REPO is INTERNAL, so this task is visible to everyone in the enterprise"
[[ "$FIELDS_TOTAL" -gt "$FIELD_PAGE" ]] \
  && add_warning "the board has $FIELDS_TOTAL fields; only the first $FIELD_PAGE were read, so a field beyond them cannot be named (raise GH_TASKS_FIELD_PAGE)"

if [[ -z "$ITEM_ID" ]] && { [[ ${#SETS[@]} -gt 0 ]] || [[ ${#CLEARS[@]} -gt 0 ]]; }; then
  echo "Error: issue #$ISSUE is not on board $NUMBER under $LOGIN, so it has no" >&2
  echo "  field values to set. Add it to the board first." >&2
  exit 1
fi
[[ -z "$ITEM_ID" ]] && add_warning "issue #$ISSUE is not on board $NUMBER under $LOGIN"

# A write that stops half way has still changed the queue, so what landed is
# reported before the failure rather than left for the user to discover.
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

set_field() {
  local fid="$1" kind="$2" name="$3" raw="$4"
  gh_tasks_field_value "$RESOLVED" "$fid" "$kind" "$name" "$raw"
  if [[ "$DRY" -eq 0 ]]; then
    mutate_field "$fid" "$kind" "$name"
  fi
  record "{\"field\": $(gh_tasks_json_string "$name"), \"value\": $(gh_tasks_json_string "$GH_TASKS_VALUE_SHOWN")}"
}

mutate_field() {
  local fid="$1" kind="$2" name="$3" status=0
  MUT_OUT="$(gh_tasks_field_write "$PROJECT_ID" "$ITEM_ID" "$fid" "$kind" "$GH_TASKS_VALUE_ID")" || status=$?
  if [[ "$status" -ne 0 ]]; then
    report_partial
    exit "$status"
  fi
  [[ -n "$MUT_OUT" ]] || { echo "Error: setting '$name' returned no item." >&2; report_partial; exit 1; }
}

for spec in ${SETS[@]+"${SETS[@]}"}; do
  NAME="${spec%%=*}"
  VALUE="${spec#*=}"
  FOUND="$(gh_tasks_field_id "$RESOLVED" "$NAME")" || exit $?
  IFS=$'\t' read -r FID KIND CANON <<<"$FOUND"
  gh_tasks_field_writable "$CANON" "$KIND"
  set_field "$FID" "$KIND" "$CANON" "$VALUE"
done

for name in ${CLEARS[@]+"${CLEARS[@]}"}; do
  FOUND="$(gh_tasks_field_id "$RESOLVED" "$name")" || exit $?
  IFS=$'\t' read -r FID KIND CANON <<<"$FOUND"
  gh_tasks_field_writable "$CANON" "$KIND"
  if [[ "$DRY" -eq 1 ]]; then
    record "{\"field\": $(gh_tasks_json_string "$CANON"), \"value\": null}"
    continue
  fi
  mutate -f p="$PROJECT_ID" -f i="$ITEM_ID" -f f="$FID" \
    -f query='mutation($p: ID!, $i: ID!, $f: ID!) {
      clearProjectV2ItemFieldValue(input: {projectId: $p, itemId: $i, fieldId: $f}) {
        projectV2Item { id }
      }
    }' --jq '.data.clearProjectV2ItemFieldValue.projectV2Item.id'
  record "{\"field\": $(gh_tasks_json_string "$CANON"), \"value\": null}"
done

if [[ -n "$PARENT" ]]; then
  PSTATUS=0
  PARENT_ID="$(gh_tasks_api -f owner="${REPO%%/*}" -f name="${REPO#*/}" -F num="$PARENT" \
    -f query='query($owner: String!, $name: String!, $num: Int!) {
      repository(owner: $owner, name: $name) { issue(number: $num) { id } }
    }' --jq '.data.repository.issue.id // ""')" || PSTATUS=$?
  # gh has already named the number it could not resolve; this says which
  # lookup wanted it.
  if [[ "$PSTATUS" -eq 44 ]]; then
    echo "  $REPO has no issue #$PARENT to make the parent." >&2
    report_partial
    exit 44
  fi
  if [[ "$PSTATUS" -ne 0 ]]; then
    report_partial
    exit "$PSTATUS"
  fi
  if [[ -z "$PARENT_ID" ]]; then
    echo "Error: $REPO has no issue #$PARENT to make the parent." >&2
    report_partial
    exit 44
  fi
  if [[ "$DRY" -eq 1 ]]; then
    record "{\"parent\": $PARENT}"
  else
    # replaceParent: an issue has one parent, and a task being given a new one
    # is being moved rather than gaining a second.
    mutate -f parent="$PARENT_ID" -f sub="$ISSUE_ID" \
      -f query='mutation($parent: ID!, $sub: ID!) {
        addSubIssue(input: {issueId: $parent, subIssueId: $sub, replaceParent: true}) {
          issue { number }
        }
      }' --jq '.data.addSubIssue.issue.number // ""'
    record "{\"parent\": $PARENT}"
  fi
fi

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

printf '{\n'
printf '  "action": "update",\n'
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
printf '  "%s": [%s],\n' "$([[ "$DRY" -eq 1 ]] && echo planned || echo applied)" "$APPLIED"
printf '  "warnings": [%s]\n' "$WARNINGS"
printf '}\n'
