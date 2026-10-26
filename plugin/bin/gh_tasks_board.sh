#!/usr/bin/env bash
# Reads a project's task board and prints it as JSON for the model to narrate.
# Usage: gh_tasks_board.sh [--state open|closed|all] [--order board|closed]
#                          [--all] [--limit N] [--repo owner/name]
#                          [--owner login --number N]
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: gh_tasks_board.sh [options]

Prints the task board for the current repository as a single JSON object: the
board's own fields, its items in board order, and the counts.

Options:
  --state open|closed|all   which items to return (default: open)
  --order board|closed      board order, or most-recently-closed first
                            (default: closed with --state closed, else board)
  --all                     fetch every page (default: the first page only,
                            with the remainder reported as a count)
  --limit N                 items per page, 1-100 (default: 100)
  --repo owner/name         act as if run in this repository
  --owner login             board owner, skipping discovery
  --number N                board number, skipping discovery
  -h, --help                this text

The board is found by linkage -- a board linked to the repository needs no local
configuration. Where the board and the code repos sit under different owners
GitHub forbids linking them, so a keyed file names it instead; see
install/user/gh-tasks.conf.

Order is the board's own manual position, as dragged. It is not a field and
cannot be sorted on, so the item sequence IS the order. A view with an explicit
sort does not show it.
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

STATE=open
ORDER=""
FETCH_ALL=0
LIMIT=100
REPO=""
LOGIN=""
NUMBER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    (--state)  STATE="${2:-}"; shift 2 ;;
    (--order)  ORDER="${2:-}"; shift 2 ;;
    (--all)    FETCH_ALL=1; shift ;;
    (--limit)  LIMIT="${2:-}"; shift 2 ;;
    (--repo)   REPO="${2:-}"; shift 2 ;;
    (--owner)  LOGIN="${2:-}"; shift 2 ;;
    (--number) NUMBER="${2:-}"; shift 2 ;;
    (*) echo "Error: unrecognised argument '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

case "$STATE" in
  (open|closed|all) ;;
  (*) echo "Error: --state must be open, closed or all, got: $STATE" >&2; exit 1 ;;
esac

# Asking for closed items is asking what was finished lately, and board order
# answers a different question. Asking for open ones is asking what is next,
# which board order answers exactly.
if [[ -z "$ORDER" ]]; then
  case "$STATE" in (closed) ORDER=closed ;; (*) ORDER=board ;; esac
fi
case "$ORDER" in
  (board|closed) ;;
  (*) echo "Error: --order must be board or closed, got: $ORDER" >&2; exit 1 ;;
esac
# Date order over a mixed set is two orderings concatenated -- closed by date,
# then open with no date at all -- which one `order` value cannot describe. The
# model is told the head of the list is what comes next, so a list headed by
# finished work is the one shape worth refusing outright.
if [[ "$ORDER" == "closed" && "$STATE" != "closed" ]]; then
  echo "Error: --order closed needs --state closed." >&2
  echo "  Over open or mixed items it would put finished work at the head of the list," >&2
  echo "  where board order means what to do next." >&2
  exit 1
fi
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [[ "$LIMIT" -lt 1 ]] || [[ "$LIMIT" -gt 100 ]]; then
  echo "Error: --limit must be 1-100, got: $LIMIT" >&2
  exit 1
fi
if { [[ -n "$LOGIN" ]] && [[ -z "$NUMBER" ]]; } || { [[ -z "$LOGIN" ]] && [[ -n "$NUMBER" ]]; }; then
  echo "Error: --owner and --number go together." >&2
  exit 1
fi

FIELD_PAGE="$(gh_tasks_field_page)" || exit $?
BOARD_QUERY="$(gh_tasks_expand "$GH_TASKS_BOARD_QUERY")" || exit $?
ITEM_JQ="$(gh_tasks_expand "$GH_TASKS_ITEM_JQ")" || exit $?

DECLARED=unspecified
SOURCE=explicit
if [[ -z "$LOGIN" ]]; then
  [[ -n "$REPO" ]] || REPO="$(gh_tasks_detect_repo)"
  if ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "Error: repo must be <owner>/<name>, got: $REPO" >&2
    exit 1
  fi
  # The assignment, not a `read`, must be the command whose status is checked:
  # gh_tasks_discover exits non-zero from inside a command substitution, which
  # ends only the subshell, and a `read` in front of it would discard that.
  DISCOVERED="$(gh_tasks_discover "$REPO")" || exit $?
  IFS=$'\t' read -r LOGIN NUMBER DECLARED SOURCE <<<"$DISCOVERED"
fi
if ! [[ "$NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: board number must be numeric, got: $NUMBER" >&2
  exit 1
fi

# Every value the shell needs arrives on its own tagged line. Nothing is matched
# out of serialised JSON: field names and board titles are free text from
# GitHub, and a bracket-terminated pattern over them truncated an array
# mid-string while the script reported success.
#
# The counts are taken BEFORE the state filter, so a summary can say how many
# items it is not showing rather than implying the board holds only what came
# back.
page_filter() {
  cat <<JQ
  (.data.repositoryOwner.projectV2) as \$p |
  (\$p.items.nodes // []) as \$n |
  "HNUM\t\(\$p.number)",
  "HTITLE\t\(\$p.title | tojson)",
  "HURL\t\(\$p.url | tojson)",
  "HSCHEMA\t\([\$p.fields.nodes[] | select(.name != null) | {name, dataType}] | tojson)",
  "HFIELDSTOTAL\t\(\$p.fields.totalCount)",
  "HTOTAL\t\(\$p.items.totalCount)",
  "HNEXT\t\(\$p.items.pageInfo.hasNextPage)",
  "HCURSOR\t\(if \$p.items.pageInfo.hasNextPage then \$p.items.pageInfo.endCursor else "" end)",
  "HOPEN\t\([\$n[] | select(.content.state == "OPEN")] | length)",
  "HCLOSED\t\([\$n[] | select(.content.state == "CLOSED")] | length)",
  "HNONISSUE\t\([\$n[] | select(.content.number == null)] | length)",
  "HPUBLIC\t\([\$n[] | select(.content.repository.visibility == "PUBLIC")] | length)",
  "HPRIVATE\t\([\$n[] | select(.content.repository.visibility == "PRIVATE")] | length)",
  (\$n[]
   | select(.content.number != null)
   | select(if "$STATE" == "all" then true
            elif "$STATE" == "open" then .content.state == "OPEN"
            else .content.state == "CLOSED" end)
   | "ITEM\t" + (.content.closedAt // "") + "\t" + ($ITEM_JQ | tojson))
JQ
}

ITEM_FILE="$(mktemp "${TMPDIR:-/tmp}/gh-tasks-items.XXXXXX")" || {
  echo "Error: cannot create a temporary file." >&2
  exit 1
}
# A signal handler that only cleans up and returns leaves the loop running on a
# deleted file: every item written before it is lost while the counts still
# claim them. These exit.
trap 'rm -f "$ITEM_FILE"; gh_tasks_cleanup' EXIT
trap 'rm -f "$ITEM_FILE"; gh_tasks_cleanup; exit 130' INT
trap 'rm -f "$ITEM_FILE"; gh_tasks_cleanup; exit 143' TERM

TOTAL=0
OPEN_N=0
CLOSED_N=0
NONISSUE=0
PUBLIC_N=0
PRIVATE_N=0
FIELDS_TOTAL=0
SCHEMA="[]"
B_NUMBER=""
B_TITLE=null
B_URL=null
HAS_NEXT=false
CURSOR=""
PAGES=0
RETURNED=0

while :; do
  set -- -F login="$LOGIN" -F num="$NUMBER" -F first="$LIMIT" -f query="$BOARD_QUERY"
  [[ -n "$CURSOR" ]] && set -- "$@" -F after="$CURSOR"
  PAGE="$(gh_tasks_api "$@" --jq "$(page_filter)")" || exit $?
  PAGES=$((PAGES + 1))
  CURSOR=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    value="${line#*	}"
    case "$line" in
      (HNUM*)         B_NUMBER="$value" ;;
      (HTITLE*)       B_TITLE="$value" ;;
      (HURL*)         B_URL="$value" ;;
      (HSCHEMA*)      SCHEMA="$value" ;;
      (HFIELDSTOTAL*) FIELDS_TOTAL="$value" ;;
      (HTOTAL*)       TOTAL="$value" ;;
      (HNEXT*)        HAS_NEXT="$value" ;;
      (HCURSOR*)      CURSOR="$value" ;;
      (HOPEN*)        OPEN_N=$((OPEN_N + value)) ;;
      (HCLOSED*)      CLOSED_N=$((CLOSED_N + value)) ;;
      (HNONISSUE*)    NONISSUE=$((NONISSUE + value)) ;;
      (HPUBLIC*)      PUBLIC_N=$((PUBLIC_N + value)) ;;
      (HPRIVATE*)     PRIVATE_N=$((PRIVATE_N + value)) ;;
      (ITEM*)
        printf '%s\n' "${line#ITEM	}" >> "$ITEM_FILE"
        RETURNED=$((RETURNED + 1))
        ;;
    esac
  done <<<"$PAGE"

  [[ "$FETCH_ALL" -eq 1 && "$HAS_NEXT" == "true" ]] || break
done

[[ -n "$B_NUMBER" ]] || { echo "Error: no board $NUMBER under $LOGIN, or no access to it." >&2; exit 1; }

if [[ "$ORDER" == "closed" ]]; then
  # -s keeps board order among items sharing a key. The key is an ISO-8601
  # timestamp, so a lexical sort is chronological.
  LC_ALL=C sort -s -r -t"$(printf '\t')" -k1,1 "$ITEM_FILE" -o "$ITEM_FILE"
fi
ITEMS="$(cut -f2- "$ITEM_FILE" | paste -sd, -)"

SEEN=$((OPEN_N + CLOSED_N + NONISSUE))
UNREAD=$((TOTAL - SEEN))
[[ "$UNREAD" -lt 0 ]] && UNREAD=0
COMPLETE=true
[[ "$HAS_NEXT" == "true" ]] && COMPLETE=false

WARNINGS=""
add_warning() {
  [[ -n "$WARNINGS" ]] && WARNINGS="$WARNINGS,"
  WARNINGS="$WARNINGS\"$1\""
}

# A visibility mismatch is reported, never corrected and never fatal: this
# script writes nothing, so the right move is to say so where the user will see
# it and let the write path refuse. The counts come from the API's own
# visibility field over every node on each page, before the state filter --
# grepping the serialised items missed a mismatch whenever the offending item
# was closed or on a later page.
if [[ "$DECLARED" != "unspecified" ]]; then
  case "$DECLARED" in
    (private) [[ "$PUBLIC_N" -gt 0 ]] \
      && add_warning "declared visibility is private but $PUBLIC_N item(s) read come from a PUBLIC repo" ;;
    (public)  [[ "$PRIVATE_N" -gt 0 ]] \
      && add_warning "declared visibility is public but $PRIVATE_N item(s) read come from a PRIVATE repo" ;;
  esac
  [[ "$COMPLETE" != "true" ]] \
    && add_warning "the visibility check covered only the $SEEN item(s) read, not the whole board"
fi

[[ "$FIELDS_TOTAL" -gt "$FIELD_PAGE" ]] \
  && add_warning "the board has $FIELDS_TOTAL fields; only the first $FIELD_PAGE were read (raise GH_TASKS_FIELD_PAGE)"
[[ "$NONISSUE" -gt 0 ]] && add_warning "$NONISSUE board item(s) are drafts or pull requests and were skipped"
[[ "$COMPLETE" != "true" ]] \
  && add_warning "$UNREAD item(s) went unread; re-run with --all to fetch every page"

# Cursor paging has no snapshot behind it, so an item moved or deleted between
# pages shifts the window and is skipped while hasNextPage still goes false.
# Every node falls into exactly one of the three buckets, so once every page is
# read their sum must equal the board's own total.
if [[ "$COMPLETE" == "true" && "$SEEN" -ne "$TOTAL" ]]; then
  add_warning "the board reports $TOTAL item(s) but $SEEN were seen; it changed while being read, so this is not a complete picture -- re-run"
  COMPLETE=false
fi

if printf '%s' "$ITEMS" | grep -q '"fieldsUndecoded":[1-9]'; then
  add_warning "some items carry field values of a type these scripts do not decode; a field missing from an item's fields object may still have a value"
fi
if printf '%s' "$ITEMS" | grep -q '"truncated":\["'; then
  add_warning "some items have more labels, assignees or sub-issues than were read; see each item's truncated list"
fi

printf '{\n'
printf '  "board": {"owner": "%s", "number": %s, "title": %s, "url": %s},\n' \
  "$LOGIN" "$B_NUMBER" "$B_TITLE" "$B_URL"
printf '  "discovery": {"source": "%s", "declaredVisibility": "%s"},\n' "$SOURCE" "$DECLARED"
printf '  "schema": %s,\n' "$SCHEMA"
printf '  "counts": {"onBoard": %s, "openSeen": %s, "closedSeen": %s, "nonIssueSeen": %s, "returned": %s, "unread": %s, "pagesRead": %s, "allPagesRead": %s},\n' \
  "$TOTAL" "$OPEN_N" "$CLOSED_N" "$NONISSUE" "$RETURNED" "$UNREAD" "$PAGES" "$COMPLETE"
printf '  "stateFilter": "%s",\n' "$STATE"
printf '  "order": "%s",\n' "$ORDER"
printf '  "warnings": [%s],\n' "$WARNINGS"
printf '  "items": [%s]\n' "$ITEMS"
printf '}\n'
