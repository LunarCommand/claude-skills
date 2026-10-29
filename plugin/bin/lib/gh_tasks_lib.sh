# shellcheck shell=bash
# Shared helpers for the gh_tasks_* scripts: dependency preflight, board
# discovery, the GraphQL documents, and the field-value decoding both readers
# share.
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
#
# Nothing here parses JSON with a regex. Every value the scripts need arrives on
# its own tagged line from gh's own jq engine, because a board title or field
# name is free text from GitHub: a field named `Est [days]` against a
# bracket-terminated pattern truncated a JSON array mid-string and the script
# reported success.

# A value whose type has no fragment here serialises as {} with a null field
# name, which the item filter counts rather than drops -- the gap has to be
# visible, because SKILL.md tells the model an absent field means no value.
# PullRequest and Reviewer values are deliberately not decoded: they describe
# pull-request items rather than tasks, and the count reports them.
GH_TASKS_FIELD_VALUES='
                __typename
                ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { name } } }
                ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { name } } }
                ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { name } } }
                ... on ProjectV2ItemFieldSingleSelectValue { name field { ... on ProjectV2FieldCommon { name } } }
                ... on ProjectV2ItemFieldIterationValue { title startDate duration field { ... on ProjectV2FieldCommon { name } } }
                ... on ProjectV2ItemFieldMilestoneValue { milestone { title } field { ... on ProjectV2FieldCommon { name } } }
                ... on ProjectV2ItemFieldRepositoryValue { repository { nameWithOwner } field { ... on ProjectV2FieldCommon { name } } }
                ... on ProjectV2ItemFieldMultiSelectValue { options { name } field { ... on ProjectV2FieldCommon { name } } }
                ... on ProjectV2ItemFieldLabelValue { labels(first: 20) { totalCount nodes { name } } field { ... on ProjectV2FieldCommon { name } } }
                ... on ProjectV2ItemFieldUserValue { users(first: 20) { totalCount nodes { login } } field { ... on ProjectV2FieldCommon { name } } }'

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
              nodes {__FIELDVALUES__
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
                labels(first: 20) { totalCount nodes { name } }
                assignees(first: 10) { totalCount nodes { login } }
                parent { number }
                subIssues(first: 20) { totalCount nodes { number } }
              }
            }
          }
        }
      }
    }
  }
}'

# One item, normalised. Every field read goes through this: a field with no
# value for an item is absent from the list, so a caller indexing a name
# directly would get null for most of a board rather than an error showing the
# bug.
#
# `truncated` names each connection that was capped, because a 20-element
# subIssues array is otherwise indistinguishable from an epic with 30 children,
# and the model is told never to report a partial read as the whole.
# shellcheck disable=SC2034  # read by the gh_tasks_* scripts that source this
GH_TASKS_ITEM_JQ='
  (.fieldValues.nodes // []) as $fv |
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
    fields:     ([$fv[]
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
                 | add // {}),
    fieldsUndecoded: ([$fv[] | select(.field.name == null)] | length),
    truncated:  ([
                  (if ((.content.labels.totalCount // 0) > 20) then "labels" else empty end),
                  (if ((.content.assignees.totalCount // 0) > 10) then "assignees" else empty end),
                  (if ((.content.subIssues.totalCount // 0) > 20) then "subIssues" else empty end),
                  (if ((.fieldValues.totalCount // 0) > __FIELDPAGE__) then "fields" else empty end)
                ])
  }'

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

# How many of a board's fields to read per item. Below GraphQL's 100 cap by
# default so an ordinary board costs less, and raisable because a board wider
# than the page would otherwise show partial field values.
gh_tasks_field_page() {
  local n="${GH_TASKS_FIELD_PAGE:-50}"
  if ! [[ "$n" =~ ^[0-9]+$ ]] || [[ "$n" -lt 1 ]] || [[ "$n" -gt 100 ]]; then
    echo "Error: GH_TASKS_FIELD_PAGE must be 1-100, got: $n" >&2
    exit 1
  fi
  printf '%s' "$n"
}

# The documents carry placeholders rather than literals, because the page size
# appears in a selection AND in the truncation test, and the two disagreeing is
# exactly the bug the test exists to report.
gh_tasks_expand() {
  local doc="$1" page
  page="$(gh_tasks_field_page)" || exit $?
  doc="${doc//__FIELDPAGE__/$page}"
  printf '%s' "${doc//__FIELDVALUES__/$GH_TASKS_FIELD_VALUES}"
}

# A per-call stderr file, removed by the caller's EXIT trap as well as here, so
# a signal arriving mid-call cannot leak it.
GH_TASKS_ERR=""
gh_tasks_cleanup() {
  [[ -n "$GH_TASKS_ERR" ]] && rm -f "$GH_TASKS_ERR"
  GH_TASKS_ERR=""
}

# Boards need a token scope ordinary `gh` use does not. The scope is not read
# from `gh auth status`: that is human-facing text whose shape is not a
# contract. The API's own refusal is the authority, so a call is attempted and
# its error interpreted.
#
# Two statuses carry meaning. Exit 77 is the scope refusal, which callers must
# propagate rather than treat as "no data" -- an `exit` here ends only the
# command substitution the caller wrapped this in. Return 44 is NOT_FOUND, which
# a caller searching several repositories may skip past; any other non-zero
# means the question could not be asked and must not be read as an answer.
gh_tasks_api() {
  local status=0
  GH_TASKS_ERR="$(mktemp "${TMPDIR:-/tmp}/gh-tasks-err.XXXXXX")" || {
    echo "Error: cannot create a temporary file." >&2
    exit 1
  }
  # The status is captured on the command itself: a failed `if cmd; then ...;
  # fi` has its own exit status of 0, so reading $? below one reported success
  # for every failure and handed the caller GitHub's error body as data.
  gh api graphql "$@" 2>"$GH_TASKS_ERR" || status=$?
  if [[ "$status" -eq 0 ]]; then
    gh_tasks_cleanup
    return 0
  fi
  # -E, not a BRE alternation: `\|` is a GNU extension that BSD grep reads as a
  # literal pipe, which would have made this refusal unreachable on macOS.
  if grep -qiE 'read:project|missing required scopes' "$GH_TASKS_ERR"; then
    echo "Missing the 'project' token scope, which boards require." >&2
    echo "  Run: gh auth refresh -s project" >&2
    gh_tasks_cleanup
    exit 77
  fi
  # GitHub answers a missing issue, a missing board and a repository the token
  # cannot see with the same NOT_FOUND, deliberately: an invisible private repo
  # must not be distinguishable from an absent one. Exit 44 separates that whole
  # class from a transport failure, a rate limit or a permission error, because
  # a caller searching several repositories must move on from "not here"
  # without treating "could not ask" the same way.
  if grep -q 'Could not resolve to a' "$GH_TASKS_ERR"; then
    cat "$GH_TASKS_ERR" >&2
    gh_tasks_cleanup
    return 44
  fi
  cat "$GH_TASKS_ERR" >&2
  gh_tasks_cleanup
  return "$status"
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
# file needs no JSON parser, and the only one available here would be a new hard
# dependency on jq for a path that exists solely as a fallback.
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

# The keyed file wins over linkage. A row states which board holds this repo's
# tasks and what visibility the workspace expects; linkage only infers the
# board, and cannot carry a declared visibility at all. Query linkage first and
# a row is discarded whenever a board happens to be linked, which nothing
# surfaces: the board that comes back is a real one.
#
# Linkage still covers the common case with no local state, which is the point
# of keeping the queue off any one machine. The file covers what linkage cannot
# express: a board links only to repos under the same owner, so a workspace
# whose board and code repos sit in different orgs has no linkage to read.
#
# Prints "login<TAB>number<TAB>visibility<TAB>source".
gh_tasks_discover() {
  local repo="$1" owner name page linked truncated count cfg

  cfg="$(gh_tasks_config_lookup "$repo")" || exit $?
  if [[ -n "$cfg" ]]; then
    printf '%s\tconfig\n' "$cfg"
    return 0
  fi

  owner="${repo%%/*}"
  name="${repo#*/}"

  page="$(gh_tasks_api \
    -F owner="$owner" -F name="$name" \
    -f query='query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        projectsV2(first: 100) {
          totalCount
          nodes { number closed owner { ... on Organization { login } ... on User { login } } }
        }
      }
    }' \
    --jq '(.data.repository.projectsV2) as $p |
          "TRUNCATED\t\((($p.totalCount // 0) > (($p.nodes // []) | length)))",
          (($p.nodes // [])[]
            | select(.closed == false)
            | select(.owner.login != null)
            | "BOARD\t\(.owner.login)\t\(.number)")')" || exit $?

  truncated="$(printf '%s\n' "$page" | awk -F'\t' '$1 == "TRUNCATED" { print $2; exit }')"
  linked="$(printf '%s\n' "$page" | awk -F'\t' '$1 == "BOARD" { print $2 "\t" $3 }')"
  count="$(printf '%s' "$linked" | grep -c . || true)"

  # No count taken from a truncated list is evidence. One open board among those
  # read may not be the only one, and none among them does not mean none exists,
  # so neither the linkage answer below nor the no-board error can be reached
  # from here.
  if [[ "$truncated" == "true" ]]; then
    echo "Error: $repo is linked to more boards than could be read, so linkage cannot" >&2
    echo "  settle which one holds its tasks. Open boards among those read: $count." >&2
    echo "  Name the one to use in $(gh_tasks_config_path):" >&2
    echo "      $repo  <board owner>  <board number>  private" >&2
    exit 1
  fi

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

  echo "Error: no task board found for $repo." >&2
  echo "  Link one:   gh project link <number> --owner <owner> --repo $repo" >&2
  echo "  Or name it: $(gh_tasks_config_path)" >&2
  echo "      $repo  <board owner>  <board number>  private" >&2
  exit 1
}

# A NOT_FOUND on the board says nothing about where its number came from, which
# is the one thing needed to fix it: GitHub answers a deleted board, a wrong
# number and a board the token cannot see with the same error.
gh_tasks_board_origin() {
  local source="$1" login="$2" number="$3" repo="${4:-}"
  case "$source" in
    (explicit)
      echo "  Board $number under $login was named by --owner and --number." >&2
      ;;
    (config)
      echo "  Board $number under $login came from a row in $(gh_tasks_config_path):" >&2
      echo "      $repo  $login  $number" >&2
      echo "  Correct that row, or remove it to fall back to the repository's link." >&2
      ;;
    (linkage)
      echo "  Board $number under $login was found through its link to $repo." >&2
      echo "  Re-link the repository, or name a board in $(gh_tasks_config_path)." >&2
      ;;
  esac
}

# Locating an issue's repository is the one thing a single-item read cannot do
# from the issue alone: the caller has a number, and which repo holds it is a
# property of the workspace.
#
# One page, not the whole board. Every item in a workspace normally lives in one
# repository, so the first page names it. `hasNextPage` is reported so a caller
# never states what the board contains on the strength of 100 items, and
# "a repo that has an issue numbered N" is not the same claim as "the repo
# holding board item N" -- only an EXACT line carries the second.
# shellcheck disable=SC2034  # read by gh_tasks_locate_issue below
GH_TASKS_LOCATE_QUERY='query($login: String!, $num: Int!, $first: Int!, $after: String) {
  repositoryOwner(login: $login) {
    ... on ProjectV2Owner {
      projectV2(number: $num) {
        items(first: $first, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes { content { ... on Issue { number repository { nameWithOwner } } } }
        }
      }
    }
  }
}'

gh_tasks_locate_pages() {
  local n="${GH_TASKS_LOCATE_PAGES:-10}"
  if ! [[ "$n" =~ ^[0-9]+$ ]] || [[ "$n" -lt 1 ]] || [[ "$n" -gt 100 ]]; then
    echo "Error: GH_TASKS_LOCATE_PAGES must be 1-100, got: $n" >&2
    exit 1
  fi
  printf '%s' "$n"
}

# Prints one "EXACT<TAB>owner/name" line per board item matching issue $3, a
# "CANDIDATE<TAB>owner/name" line per distinct repository on the page, and one
# "MORE<TAB>true|false" line saying whether the board continues past it.
gh_tasks_locate_issue() {
  local login="$1" number="$2" issue="$3" page seen="" cursor="" pages=0 cap more=false

  # Every page is read, not just the one holding the first match: whether the
  # board carries this number in more than one repository is a property of the
  # whole board, and a caller told "exact" from a partial read has no way to
  # know it was a guess. The cap bounds the cost of that on a large board and
  # is reported as an incomplete read when it stops the loop.
  cap="$(gh_tasks_locate_pages)" || exit $?
  while :; do
    set -- -F login="$login" -F num="$number" -F first=100 \
           -f query="$GH_TASKS_LOCATE_QUERY"
    [[ -n "$cursor" ]] && set -- "$@" -F after="$cursor"
    page="$(gh_tasks_api "$@" --jq '
      (.data.repositoryOwner.projectV2.items) as $i |
      "NEXT\t\($i.pageInfo.hasNextPage)",
      "CURSOR\t\($i.pageInfo.endCursor // "")",
      (($i.nodes // [])[] | select(.content.number != null)
            | "SEEN\t\(.content.number)\t\(.content.repository.nameWithOwner)")')" || exit $?
    pages=$((pages + 1))
    seen="$seen$(printf '%s\n' "$page" | awk -F'\t' '$1 == "SEEN"')"$'\n'
    if [[ "$(printf '%s\n' "$page" | awk -F'\t' '$1 == "NEXT" { print $2; exit }')" != "true" ]]; then
      break
    fi
    if [[ "$pages" -ge "$cap" ]]; then
      more=true
      break
    fi
    cursor="$(printf '%s\n' "$page" | awk -F'\t' '$1 == "CURSOR" { print $2; exit }')"
    if [[ -z "$cursor" ]]; then
      more=true
      break
    fi
  done

  printf '%s\n' "$seen" | awk -F'\t' -v n="$issue" -v more="$more" '
    $1 == "SEEN" && $2 == n && !exactseen[$3]++ { exact[++e] = $3 }
    $1 == "SEEN" && !seen[$3]++                 { cand[++c] = $3 }
    END {
      for (i = 1; i <= e; i++) print "EXACT\t" exact[i]
      for (i = 1; i <= c; i++) print "CANDIDATE\t" cand[i]
      print "MORE\t" more
    }'
}
