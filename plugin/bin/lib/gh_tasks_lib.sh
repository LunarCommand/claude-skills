# shellcheck shell=bash
# Shared helpers for the gh_tasks_* scripts: dependency preflight, board
# discovery, and the one board-read query both readers use.
#
# Sourced by explicit path because bin/lib/ is not a PATH entry -- see
# require_cmd.sh for why the helpers live there rather than in bin/.
#
# Reads go through GraphQL rather than `gh project`, for three reasons measured
# against a live board: one query returns the board's field list, its items in
# board order, and each item's repo visibility together; `fieldValues` is a list
# keyed by field name, where `gh project item-list --format json` omits an unset
# field's key entirely; and `pageInfo` makes truncation explicit, where
# item-list silently returns 30 of 33 while reporting totalCount 33.

# The project owner may be a user or an organization. `repositoryOwner` returns
# the RepositoryOwner interface and ProjectV2Owner carries projectV2(number:),
# so one inline fragment covers both and no caller has to know which it has.
# shellcheck disable=SC2034  # read by the gh_tasks_* scripts that source this
GH_TASKS_BOARD_QUERY='query($login: String!, $num: Int!, $first: Int!, $after: String) {
  repositoryOwner(login: $login) {
    ... on ProjectV2Owner {
      projectV2(number: $num) {
        number
        title
        url
        fields(first: __FIELDPAGE__) {
          totalCount
          nodes { ... on ProjectV2FieldCommon { name dataType } }
        }
        items(first: $first, after: $after) {
          totalCount
          pageInfo { hasNextPage endCursor }
          nodes {
            fieldValues(first: __FIELDPAGE__) {
              totalCount
              nodes {
                ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { name } } }
                ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { name } } }
                ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { name } } }
                ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } }
              }
            }
            content {
              ... on Issue {
                number
                title
                state
                url
                closedAt
                updatedAt
                repository { nameWithOwner visibility }
                labels(first: 20) { nodes { name } }
                assignees(first: 10) { nodes { login } }
                parent { number }
                subIssues(first: 20) { nodes { number } }
              }
            }
          }
        }
      }
    }
  }
}'

# One item's field values, normalised to an object keyed by field name. Every
# read of a field must go through this: a field with no value for an item is
# absent from the list, so a caller indexing a name directly gets null for most
# of a board rather than an error that would have shown the bug.
# shellcheck disable=SC2034  # read by the gh_tasks_* scripts that source this
GH_TASKS_ITEM_JQ='
  {
    issue:      (.content.number // null),
    title:      (.content.title // null),
    state:      (.content.state // null),
    closedAt:   (.content.closedAt // null),
    updatedAt:  (.content.updatedAt // null),
    url:        (.content.url // null),
    repo:       (.content.repository.nameWithOwner // null),
    visibility: (.content.repository.visibility // null),
    labels:     [(.content.labels.nodes // [])[].name],
    assignees:  [(.content.assignees.nodes // [])[].login],
    parent:     (.content.parent.number // null),
    subIssues:  [(.content.subIssues.nodes // [])[].number],
    fields:     ([(.fieldValues.nodes // [])[]
                  | select(.field.name != null)
                  | {(.field.name): (.text // .number // .date // .name)}]
                 | add // {}),
    fieldsTruncated: ((.fieldValues.totalCount // 0) > __FIELDPAGE__)
  }'

# How many of a board's fields to read per item. Below GraphQL's 100 cap by
# default so an ordinary board costs less, and raisable because a board wider
# than the page silently showed partial field values before.
gh_tasks_field_page() {
  local n="${GH_TASKS_FIELD_PAGE:-50}"
  if ! [[ "$n" =~ ^[0-9]+$ ]] || [[ "$n" -lt 1 ]] || [[ "$n" -gt 100 ]]; then
    echo "Error: GH_TASKS_FIELD_PAGE must be 1-100, got: $n" >&2
    exit 1
  fi
  printf '%s' "$n"
}

# The query documents carry __FIELDPAGE__ rather than a literal, because the
# page size has to appear in the selection AND in the truncation test, and the
# two disagreeing is exactly the bug the test exists to report.
gh_tasks_expand() {
  local doc="$1" page
  page="$(gh_tasks_field_page)" || exit $?
  printf '%s' "${doc//__FIELDPAGE__/$page}"
}

gh_tasks_preflight() {
  local lib
  lib="$(dirname "${BASH_SOURCE[0]}")/require_cmd.sh"
  if [[ -r "$lib" ]]; then
    # shellcheck source=require_cmd.sh
    . "$lib"
  else
    echo "Missing required file: $lib" >&2
    echo "  This plugin install is incomplete; reinstall lunar." >&2
    exit 127
  fi
  # gh only: the --jq filters are gh's own embedded gojq engine, so the
  # standalone jq binary is NOT required. Adding `require_cmd jq` here would
  # refuse hosts where every code path would have worked.
  require_cmd gh "Install the GitHub CLI and authenticate: https://cli.github.com then run 'gh auth login'."
}

# Boards need a token scope ordinary `gh` use does not. The scope is not read
# from `gh auth status`: that is human-facing text whose shape is not a
# contract. The API's own refusal is the authority, so a call is attempted and
# its error interpreted.
gh_tasks_api() {
  local err status=0
  err="$(mktemp)"
  # The status is captured on the command itself, not after an `if`: a failed
  # `if cmd; then ...; fi` has its own exit status of 0, so reading $? below it
  # reported success for every failure and handed the caller GitHub's error
  # body as though it were data.
  gh api graphql "$@" 2>"$err" || status=$?
  if [[ "$status" -eq 0 ]]; then
    rm -f "$err"
    return 0
  fi
  if grep -qi 'read:project\|missing required scopes' "$err"; then
    echo "Missing the 'project' token scope, which boards require." >&2
    echo "  Run: gh auth refresh -s project" >&2
    rm -f "$err"
    exit 77
  fi
  cat "$err" >&2
  rm -f "$err"
  return $status
}

gh_tasks_detect_repo() {
  gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || {
    echo "Error: not in a GitHub repository, or gh cannot reach it." >&2
    echo "  Run this from a checkout whose remote is on GitHub." >&2
    exit 1
  }
}

gh_tasks_config_path() {
  echo "${GH_TASKS_CONFIG:-$HOME/.claude/gh-tasks.conf}"
}

# Whitespace-separated lines, the shape .agent.env established: a plain keyed
# file needs no JSON parser, and the only one available here would be a new
# hard dependency on jq for a path that exists solely as a fallback.
#
#   <owner/repo>  <board owner>  <board number>  [declared visibility]
#
# Prints "login<TAB>number<TAB>visibility" for a matching remote, nothing if the
# file has no row for it.
gh_tasks_config_lookup() {
  local repo="$1" path line key login num vis
  path="$(gh_tasks_config_path)"
  [[ -r "$path" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in (\#*|'') continue ;; esac
    # shellcheck disable=SC2086
    set -- $line
    key="${1:-}"; login="${2:-}"; num="${3:-}"; vis="${4:-unspecified}"
    [[ "$key" == "$repo" ]] || continue
    if [[ -z "$login" || -z "$num" ]]; then
      echo "Error: malformed row for $repo in $path" >&2
      echo "  Expected: <owner/repo> <board owner> <board number> [private|public]" >&2
      exit 1
    fi
    printf '%s\t%s\t%s\n' "$login" "$num" "$vis"
    return 0
  done < "$path"
}

# Linkage first: a board linked to this repo is discoverable with no local
# state, which is the point of keeping the queue off any one machine. The keyed
# file covers the case linkage cannot express -- a board links only to repos
# under the same owner, so a workspace whose board and code repos sit in
# different orgs has no linkage to read.
#
# Prints "login<TAB>number<TAB>visibility<TAB>source".
gh_tasks_discover() {
  local repo="$1" owner name linked count cfg
  owner="${repo%%/*}"
  name="${repo#*/}"

  linked="$(gh_tasks_api \
    -F owner="$owner" -F name="$name" \
    -f query='query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        projectsV2(first: 20) {
          nodes { number closed owner { ... on ProjectV2Owner { __typename } ... on Organization { login } ... on User { login } } }
        }
      }
    }' \
    --jq '[.data.repository.projectsV2.nodes[] | select(.closed == false)] | .[] | "\(.owner.login)\t\(.number)"')" || exit $?

  count="$(printf '%s' "$linked" | grep -c . || true)"
  if [[ "$count" -eq 1 ]]; then
    printf '%s\tunspecified\tlinkage\n' "$linked"
    return 0
  fi
  if [[ "$count" -gt 1 ]]; then
    echo "Error: $repo is linked to $count open boards, so which one holds its tasks is ambiguous:" >&2
    printf '%s\n' "$linked" | sed 's/^/        /' >&2
    echo "  Name the one to use in $(gh_tasks_config_path):" >&2
    echo "      $repo  <board owner>  <board number>  private" >&2
    exit 1
  fi

  cfg="$(gh_tasks_config_lookup "$repo")" || exit $?
  if [[ -n "$cfg" ]]; then
    printf '%s\tconfig\n' "$cfg"
    return 0
  fi

  echo "Error: no task board found for $repo." >&2
  echo "  Link one:   gh project link <number> --owner <owner> --repo $repo" >&2
  echo "  Or name it: $(gh_tasks_config_path)" >&2
  echo "      $repo  <board owner>  <board number>  private" >&2
  exit 1
}

# Locating an issue's repository is the one thing a single-item read cannot do
# from the issue alone: the caller has a number, and which repo holds it is a
# property of the workspace.
#
# One page, not the whole board. Every item in a workspace normally lives in one
# repository, so the first page names it; paginating until the issue itself
# turned up was a second full read of the board to learn something its first
# item already said. A board holding items from several repositories still
# works, because the distinct repositories seen are reported as candidates and
# the caller tries each.
GH_TASKS_LOCATE_QUERY='query($login: String!, $num: Int!, $first: Int!) {
  repositoryOwner(login: $login) {
    ... on ProjectV2Owner {
      projectV2(number: $num) {
        items(first: $first) {
          pageInfo { hasNextPage }
          nodes { content { ... on Issue { number repository { nameWithOwner } } } }
        }
      }
    }
  }
}'

# Prints "EXACT<TAB>owner/name" when the first page carries issue $3, and a
# "CANDIDATE<TAB>owner/name" line per distinct repository either way.
gh_tasks_locate_issue() {
  local login="$1" number="$2" issue="$3" page
  page="$(gh_tasks_api \
    -F login="$login" -F num="$number" -F first=100 \
    -f query="$GH_TASKS_LOCATE_QUERY" \
    --jq '
      (.data.repositoryOwner.projectV2.items.nodes // []) as $n |
      ($n[] | select(.content.number != null)
            | "SEEN\t\(.content.number)\t\(.content.repository.nameWithOwner)")')" || exit $?

  printf '%s\n' "$page" | awk -F'\t' -v n="$issue" '
    $1 == "SEEN" && $2 == n && !exact { print "EXACT\t" $3; exact = 1 }
    $1 == "SEEN" && !seen[$3]++       { cand[++c] = $3 }
    END { for (i = 1; i <= c; i++) print "CANDIDATE\t" cand[i] }'
}
