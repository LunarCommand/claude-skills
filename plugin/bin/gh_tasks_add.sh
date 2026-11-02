#!/usr/bin/env bash
# Creates a task: an issue in the destination repository, on the board, with its
# board fields set.
# Usage: gh_tasks_add.sh --title "..." [--body "..."] [--field "Name=Value"]...
#                        [--label name]... [--parent N] [--repo owner/name]
#                        [--owner login --number N] [--dry-run] [--public-ok]
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: gh_tasks_add.sh --title "..." [options]

Creates one task and prints it as JSON: an issue in the destination repository,
placed on the board, with its board fields set.

Options:
  --title "..."          the task's one-line claim (required)
  --body "..."           the working note
  --field "Name=Value"   set a board field, repeatable
  --label name           add a repository label, repeatable
  --parent N             make issue N this task's parent
  --repo owner/name      where the issue is created (default: the current
                         repository), which is also the repository the board is
                         found for
  --owner login          board owner, skipping discovery
  --number N             board number, skipping discovery
  --dry-run              resolve and print what would be sent, writing nothing
  --public-ok            permit creating in a PUBLIC repository
  -h, --help             this text

Every field name, field value and label is resolved against the board and the
repository BEFORE the issue is created, so a misspelled one refuses while there
is still nothing to clean up.

The issue is created on the board in one call, so there is no window in which it
exists off the board. Its board fields are set afterwards, and a failure there
reports the task that was already created.

New tasks land at the end of the board's order.
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

TITLE=""
BODY=""
REPO=""
LOGIN=""
NUMBER=""
PARENT=""
DRY=0
PUBLIC_OK=0
SETS=()
LABELS=()

# Read by gh_tasks_need_value: a flag written where a value belongs is refused
# rather than consumed as that value.
GH_TASKS_FLAGS="--title --body --field --label --parent --repo --owner --number --dry-run --public-ok"

while [[ $# -gt 0 ]]; do
  case "$1" in
    (--title)     gh_tasks_need_value --title $# "${2:-}" "$GH_TASKS_FLAGS"; TITLE="$2"; shift 2 ;;
    (--body)      gh_tasks_need_value --body $# "${2:-}" "$GH_TASKS_FLAGS"; BODY="$2"; shift 2 ;;
    (--field)     gh_tasks_need_value --field $# "${2:-}" "$GH_TASKS_FLAGS"; SETS+=("$2"); shift 2 ;;
    (--label)     gh_tasks_need_value --label $# "${2:-}" "$GH_TASKS_FLAGS"; LABELS+=("$2"); shift 2 ;;
    (--parent)    gh_tasks_need_value --parent $# "${2:-}" "$GH_TASKS_FLAGS"; PARENT="$2"; shift 2 ;;
    (--repo)      gh_tasks_need_value --repo $# "${2:-}" "$GH_TASKS_FLAGS"; REPO="$2"; shift 2 ;;
    (--owner)     gh_tasks_need_value --owner $# "${2:-}" "$GH_TASKS_FLAGS"; LOGIN="$2"; shift 2 ;;
    (--number)    gh_tasks_need_value --number $# "${2:-}" "$GH_TASKS_FLAGS"; NUMBER="$2"; shift 2 ;;
    (--dry-run)   DRY=1; shift ;;
    (--public-ok) PUBLIC_OK=1; shift ;;
    (*) echo "Error: unrecognised argument '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

# A title of spaces is an issue nobody can find again, and GitHub takes it.
if [[ -z "${TITLE//[[:space:]]/}" ]]; then
  echo "Error: --title is required and cannot be blank." >&2
  exit 1
fi
if [[ "${#TITLE}" -gt 256 ]]; then
  echo "Error: --title is ${#TITLE} characters; GitHub's limit is 256." >&2
  exit 1
fi
if [[ -n "$PARENT" ]] && ! [[ "$PARENT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --parent must be an issue number with no leading zeros, got: $PARENT" >&2
  exit 1
fi
if { [[ -n "$LOGIN" ]] && [[ -z "$NUMBER" ]]; } || { [[ -z "$LOGIN" ]] && [[ -n "$NUMBER" ]]; }; then
  echo "Error: --owner and --number go together." >&2
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
if ! [[ "$NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: board number must be a number with no leading zeros, got: $NUMBER" >&2
  exit 1
fi
if ! [[ "$LOGIN" =~ ^[A-Za-z0-9-]{1,39}$ ]]; then
  echo "Error: board owner must be a GitHub login, got: $LOGIN" >&2
  exit 1
fi

RESOLVE_STATUS=0
RESOLVED="$(gh_tasks_resolve "$LOGIN" "$NUMBER" "$REPO")" || RESOLVE_STATUS=$?
if [[ "$RESOLVE_STATUS" -ne 0 ]]; then
  if [[ "$RESOLVE_STATUS" -eq 44 ]]; then
    case "$(gh_tasks_resolve_blame "$LOGIN" "$NUMBER" "$REPO")" in
      (repo) echo "  There is no repository $REPO, or no access to it." >&2 ;;
      (*)    gh_tasks_board_origin "$SOURCE" "$LOGIN" "$NUMBER" "$REPO" ;;
    esac
  fi
  exit "$RESOLVE_STATUS"
fi

PROJECT_ID="$(gh_tasks_resolved "$RESOLVED" PROJECT)"
[[ -n "$PROJECT_ID" ]] || { echo "Error: no board $NUMBER under $LOGIN, or no access to it." >&2; exit 1; }
REPO_ID="$(gh_tasks_resolved "$RESOLVED" REPOID)"
[[ -n "$REPO_ID" ]] || { echo "Error: cannot read $REPO." >&2; exit 1; }
VIS="$(gh_tasks_resolved "$RESOLVED" REPOVIS)"
ISSUES_ON="$(gh_tasks_resolved "$RESOLVED" REPOISSUES)"
B_TITLE="$(gh_tasks_resolved "$RESOLVED" BOARDTITLE)"
B_URL="$(gh_tasks_resolved "$RESOLVED" BOARDURL)"
FIELDS_TOTAL="$(gh_tasks_resolved "$RESOLVED" FIELDSTOTAL)"
FIELD_PAGE="$(gh_tasks_field_page)" || exit $?

gh_tasks_visibility_guard "$DECLARED" "$VIS" "$REPO" "$PUBLIC_OK"

if [[ "$ISSUES_ON" != "true" ]]; then
  echo "Error: $REPO has issues disabled, so a task cannot be created there." >&2
  echo "  Enable issues on it, or name another repository with --repo." >&2
  exit 1
fi

WARNINGS=""
add_warning() {
  [[ -n "$WARNINGS" ]] && WARNINGS="$WARNINGS,"
  WARNINGS="$WARNINGS$(gh_tasks_json_string "$1")"
}
[[ "$VIS" == "INTERNAL" ]] && add_warning "$REPO is INTERNAL, so this task is visible to everyone in the enterprise"
[[ "$FIELDS_TOTAL" -gt "$FIELD_PAGE" ]] \
  && add_warning "the board has $FIELDS_TOTAL fields; only the first $FIELD_PAGE were read, so a field beyond them cannot be named (raise GH_TASKS_FIELD_PAGE)"

# Everything is resolved before anything is created. A field name the board does
# not have, or a label the repository does not carry, then refuses while there
# is still no issue to delete.
P_FID=()
P_KIND=()
P_NAME=()
P_VID=()
P_SHOWN=()
for spec in ${SETS[@]+"${SETS[@]}"}; do
  NAME="${spec%%=*}"
  VALUE="${spec#*=}"
  FOUND="$(gh_tasks_field_id "$RESOLVED" "$NAME")" || exit $?
  IFS=$'\t' read -r FID KIND CANON <<<"$FOUND"
  gh_tasks_field_writable "$CANON" "$KIND"
  gh_tasks_field_value "$RESOLVED" "$FID" "$KIND" "$CANON" "$VALUE"
  P_FID+=("$FID")
  P_KIND+=("$KIND")
  P_NAME+=("$CANON")
  P_VID+=("$GH_TASKS_VALUE_ID")
  P_SHOWN+=("$GH_TASKS_VALUE_SHOWN")
done

L_ARGS=()
L_NAMES=""
for label in ${LABELS[@]+"${LABELS[@]}"}; do
  LFOUND="$(gh_tasks_label_id "$RESOLVED" "$label" "$REPO")" || exit $?
  IFS=$'\t' read -r LID LNAME <<<"$LFOUND"
  L_ARGS+=(-f "labels[]=$LID")
  [[ -n "$L_NAMES" ]] && L_NAMES="$L_NAMES,"
  L_NAMES="$L_NAMES$(gh_tasks_json_string "$LNAME")"
done

PARENT_ARGS=()
if [[ -n "$PARENT" ]]; then
  PSTATUS=0
  PARENT_ID="$(gh_tasks_api -f owner="${REPO%%/*}" -f name="${REPO#*/}" -F num="$PARENT" \
    -f query='query($owner: String!, $name: String!, $num: Int!) {
      repository(owner: $owner, name: $name) { issue(number: $num) { id } }
    }' --jq '.data.repository.issue.id // ""')" || PSTATUS=$?
  # gh has already named the number it could not resolve; this says which
  # lookup wanted it. Nothing has been created yet, so there is nothing to
  # report as partial.
  if [[ "$PSTATUS" -eq 44 ]]; then
    echo "  $REPO has no issue #$PARENT to make the parent." >&2
    exit 44
  fi
  [[ "$PSTATUS" -eq 0 ]] || exit "$PSTATUS"
  if [[ -z "$PARENT_ID" ]]; then
    echo "Error: $REPO has no issue #$PARENT to make the parent." >&2
    exit 44
  fi
  PARENT_ARGS=(-f "parent=$PARENT_ID")
fi

PLANNED=""
record() {
  [[ -n "$PLANNED" ]] && PLANNED="$PLANNED,"
  PLANNED="$PLANNED$1"
}
for ((i = 0; i < ${#P_FID[@]}; i++)); do
  record "{\"field\": $(gh_tasks_json_string "${P_NAME[$i]}"), \"value\": $(gh_tasks_json_string "${P_SHOWN[$i]}")}"
done

emit() {
  printf '{\n'
  printf '  "action": "add",\n'
  printf '  "dryRun": %s,\n' "$([[ "$DRY" -eq 1 ]] && echo true || echo false)"
  printf '  "board": {"owner": "%s", "number": %s, "title": %s, "url": %s},\n' \
    "$LOGIN" "$NUMBER" "${B_TITLE:-null}" "${B_URL:-null}"
  printf '  "discovery": {"source": "%s", "declaredVisibility": "%s"},\n' "$SOURCE" "$DECLARED"
  printf '  "repo": "%s",\n' "$REPO"
  printf '  "visibility": "%s",\n' "$VIS"
  printf '  "issue": %s,\n' "${1:-null}"
  printf '  "url": %s,\n' "${2:-null}"
  printf '  "title": %s,\n' "$(gh_tasks_json_string "$TITLE")"
  printf '  "onBoard": %s,\n' "${3:-null}"
  printf '  "parent": %s,\n' "${PARENT:-null}"
  printf '  "labels": [%s],\n' "$L_NAMES"
  printf '  "fields": [%s],\n' "$PLANNED"
  printf '  "warnings": [%s]\n' "$WARNINGS"
  printf '}\n'
}

if [[ "$DRY" -eq 1 ]]; then
  emit
  exit 0
fi

CREATE_STATUS=0
CREATED="$(gh_tasks_api \
  -f repo="$REPO_ID" -f title="$TITLE" -f body="$BODY" \
  -f "projects[]=$PROJECT_ID" \
  ${L_ARGS[@]+"${L_ARGS[@]}"} ${PARENT_ARGS[@]+"${PARENT_ARGS[@]}"} \
  -f query='mutation($repo: ID!, $title: String!, $body: String!, $projects: [ID!]!,
                     $labels: [ID!] = [], $parent: ID = null) {
    createIssue(input: {repositoryId: $repo, title: $title, body: $body,
                        projectV2Ids: $projects, labelIds: $labels,
                        parentIssueId: $parent}) {
      issue {
        id
        number
        url
      }
    }
  }' \
  --jq '(.data.createIssue.issue) as $i |
        "NUM\t\($i.number)",
        "URL\t\($i.url | tojson)",
        "IID\t\($i.id)"')" || CREATE_STATUS=$?
[[ "$CREATE_STATUS" -eq 0 ]] || exit "$CREATE_STATUS"

NEW_NUM="$(gh_tasks_resolved "$CREATED" NUM)"
NEW_URL="$(gh_tasks_resolved "$CREATED" URL)"
NEW_ID="$(gh_tasks_resolved "$CREATED" IID)"
if [[ -z "$NEW_NUM" ]]; then
  echo "Error: the issue may have been created but GitHub returned no number for it." >&2
  echo "  Check $REPO before running this again." >&2
  exit 1
fi

# The issue exists from here on, so nothing below may fail silently: every exit
# names it first.
report_created() {
  local bare="${NEW_URL%\"}"
  echo "Task #$NEW_NUM was created: ${bare#\"}" >&2
}

# projectV2Ids above does place the issue on the board, but the created issue's
# own projectItems come back empty in that same response, so the item ID has to
# be asked for separately. Adding an issue a board already holds answers with
# the item it already has -- but only once the placing has settled. In the window
# right after the create it can instead answer UNPROCESSABLE, "Content already
# exists in this project", carrying no data, so the item is read back rather than
# added again.
ITEM_ID=""
if [[ -n "$NEW_ID" ]]; then
  ITEM_STATUS=0
  ITEM_ID="$(gh_tasks_api -f project="$PROJECT_ID" -f content="$NEW_ID" \
    -f query='mutation($project: ID!, $content: ID!) {
      addProjectV2ItemById(input: {projectId: $project, contentId: $content}) {
        item { id }
      }
    }' --jq '.data.addProjectV2ItemById.item.id // empty')" || ITEM_STATUS=$?
  if [[ -z "$ITEM_ID" ]]; then
    ITEM_ID="$(gh_tasks_api -f content="$NEW_ID" \
      -f query='query($content: ID!) {
        node(id: $content) {
          ... on Issue {
            projectItems(first: 100) { nodes { id project { id } } }
          }
        }
      }' --jq "[.data.node.projectItems.nodes[]? | select(.project.id == \"$PROJECT_ID\") | .id][0] // empty")" || ITEM_STATUS=$?
    [[ -z "$ITEM_ID" ]] || ITEM_STATUS=0
  fi
fi

if [[ -z "$ITEM_ID" ]]; then
  if [[ "${#P_FID[@]}" -gt 0 ]]; then
    report_created
    echo "  Its item on board $NUMBER under $LOGIN could not be read, so its" >&2
    echo "  fields were not set. Set them with: gh_tasks_update.sh $NEW_NUM" >&2
    STATUS="${ITEM_STATUS:-1}"
    [[ "$STATUS" -ne 0 ]] || STATUS=1
    exit "$STATUS"
  fi
  add_warning "the new task's item on board $NUMBER under $LOGIN could not be read, so whether its fields can be set is unsettled"
fi

APPLIED=""
if [[ -n "$ITEM_ID" && "${#P_FID[@]}" -gt 0 ]]; then
  for ((i = 0; i < ${#P_FID[@]}; i++)); do
    STATUS=0
    OUT="$(gh_tasks_field_write "$PROJECT_ID" "$ITEM_ID" "${P_FID[$i]}" "${P_KIND[$i]}" "${P_VID[$i]}")" || STATUS=$?
    if [[ "$STATUS" -ne 0 ]] || [[ -z "$OUT" ]]; then
      report_created
      echo "  Setting '${P_NAME[$i]}' failed. Fields set before it: ${APPLIED:-none}." >&2
      [[ "$STATUS" -ne 0 ]] || STATUS=1
      exit "$STATUS"
    fi
    [[ -n "$APPLIED" ]] && APPLIED="$APPLIED, "
    APPLIED="$APPLIED${P_NAME[$i]}"
  done
fi

emit "$NEW_NUM" "${NEW_URL:-null}" "$([[ -n "$ITEM_ID" ]] && echo true || echo false)"
