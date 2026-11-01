#!/usr/bin/env bash
# Moves one task in the board's own order: to the top, or after another task.
# Usage: gh_tasks_move.sh <issue_number> (--top | --after N)
#                         [--repo owner/name] [--owner login --number N]
#                         [--dry-run]
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: gh_tasks_move.sh <issue_number> (--top | --after N) [options]

Moves one task within the board's manual order and prints what it did as JSON.
That order is what a drag sets and what the board reads as the working queue, so
moving a task to the top is how a task becomes the next one.

Options:
  --top                  put the task first in board order
  --after N              put it directly after task N, which must be on the
                         same board
  --repo owner/name      the repository holding the task (default: the current
                         one), which is also the repository the board is found
                         for
  --owner login          board owner, skipping discovery
  --number N             board number, skipping discovery
  --dry-run              resolve and print what would be sent, writing nothing
  -h, --help             this text

One of --top and --after is required: there is no default position, because a
move with no destination would be a reorder nobody asked for.

A position belongs to one board. Both tasks must be on the board being moved
within, and a task that is not on it is refused rather than added to it.

There is no --public-ok here, and no refusal for a public repository. A position
is board metadata: moving a task publishes nothing and makes nothing
world-readable, so the flag that answers that question does not apply. A
declared visibility that disagrees with GitHub still refuses, because that
means the configuration is wrong about which board this is.
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
AFTER=""
TOP=0
DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    (--top)     TOP=1; shift ;;
    (--after)   AFTER="${2:-}"; shift 2 ;;
    (--repo)    REPO="${2:-}"; shift 2 ;;
    (--owner)   LOGIN="${2:-}"; shift 2 ;;
    (--number)  NUMBER="${2:-}"; shift 2 ;;
    (--dry-run) DRY=1; shift ;;
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
if [[ "$TOP" -eq 1 && -n "$AFTER" ]]; then
  echo "Error: --top and --after name two different positions; give one." >&2
  exit 1
fi
if [[ "$TOP" -eq 0 && -z "$AFTER" ]]; then
  echo "Error: no destination. Give --top or --after N." >&2
  exit 1
fi
if [[ -n "$AFTER" ]] && ! [[ "$AFTER" =~ ^[0-9]+$ ]]; then
  echo "Error: --after must be an issue number, got: $AFTER" >&2
  exit 1
fi
if [[ -n "$AFTER" && "$AFTER" == "$ISSUE" ]]; then
  echo "Error: a task cannot be placed after itself." >&2
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

resolve_or_exit() {
  local issue="$1" status=0 out
  out="$(gh_tasks_resolve "$LOGIN" "$NUMBER" "$REPO" "$issue")" || status=$?
  if [[ "$status" -ne 0 ]]; then
    if [[ "$status" -eq 44 ]]; then
      case "$(gh_tasks_resolve_blame "$LOGIN" "$NUMBER" "$REPO")" in
        (repo)  echo "  There is no repository $REPO, or no access to it." >&2 ;;
        (board) gh_tasks_board_origin "$SOURCE" "$LOGIN" "$NUMBER" "$REPO" ;;
        (issue) echo "  $REPO has no issue #$issue." >&2 ;;
      esac
    fi
    exit "$status"
  fi
  printf '%s' "$out"
}

RESOLVED="$(resolve_or_exit "$ISSUE")" || exit $?

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

# Only the mismatch arm applies: a move publishes nothing, so there is nothing
# for --public-ok to confirm, and the flag does not exist here.
gh_tasks_visibility_guard "$DECLARED" "$VIS" "$REPO" 1

if [[ -z "$ITEM_ID" ]]; then
  echo "Error: issue #$ISSUE is not on board $NUMBER under $LOGIN, so it has no" >&2
  echo "  position in its order. Add it to the board first." >&2
  exit 1
fi

WARNINGS=""
add_warning() {
  [[ -n "$WARNINGS" ]] && WARNINGS="$WARNINGS,"
  WARNINGS="$WARNINGS$(gh_tasks_json_string "$1")"
}

[[ "$STATE" == "CLOSED" ]] && add_warning "issue #$ISSUE is closed, so its position is only visible in a view that shows closed tasks"

AFTER_ITEM=""
if [[ -n "$AFTER" ]]; then
  A_RESOLVED="$(resolve_or_exit "$AFTER")" || exit $?
  A_ISSUE_ID="$(gh_tasks_resolved "$A_RESOLVED" ISSUEID)"
  if [[ -z "$A_ISSUE_ID" ]]; then
    echo "Error: $REPO has no issue #$AFTER to place this after." >&2
    exit 44
  fi
  AFTER_ITEM="$(gh_tasks_resolved "$A_RESOLVED" ITEM)"
  if [[ -z "$AFTER_ITEM" ]]; then
    echo "Error: issue #$AFTER is not on board $NUMBER under $LOGIN, so there is" >&2
    echo "  no position after it. Name a task that is on the board." >&2
    exit 1
  fi
fi

APPLIED=""
if [[ "$DRY" -eq 0 ]]; then
  AFTER_ARGS=()
  # An absent afterId is the top of the order, which is why --top sends no
  # position at all rather than a first item to follow.
  [[ -n "$AFTER_ITEM" ]] && AFTER_ARGS=(-f after="$AFTER_ITEM")
  STATUS=0
  OUT="$(gh_tasks_api -f p="$PROJECT_ID" -f i="$ITEM_ID" \
    ${AFTER_ARGS[@]+"${AFTER_ARGS[@]}"} \
    -f query='mutation($p: ID!, $i: ID!, $after: ID = null) {
      updateProjectV2ItemPosition(input: {projectId: $p, itemId: $i, afterId: $after}) {
        items(first: 1) { nodes { id } }
      }
    }' --jq '.data.updateProjectV2ItemPosition.items.nodes[0].id // ""')" || STATUS=$?
  if [[ "$STATUS" -ne 0 ]]; then
    exit "$STATUS"
  fi
  if [[ -z "$OUT" ]]; then
    echo "Error: the move returned no board items, so whether it took is unknown." >&2
    echo "  Read the board with gh_tasks_board.sh before moving it again." >&2
    exit 1
  fi
fi
if [[ -n "$AFTER" ]]; then
  APPLIED="{\"after\": $AFTER}"
else
  APPLIED='{"position": "top"}'
fi

printf '{\n'
printf '  "action": "move",\n'
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
printf '  "onBoard": true,\n'
printf '  "%s": [%s],\n' "$([[ "$DRY" -eq 1 ]] && echo planned || echo applied)" "$APPLIED"
printf '  "warnings": [%s]\n' "$WARNINGS"
printf '}\n'
