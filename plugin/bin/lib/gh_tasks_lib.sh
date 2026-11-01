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
# "A repo that has an issue numbered N" is not the same claim as "the repo
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
# "CANDIDATE<TAB>owner/name" line per distinct repository among the items read,
# and one "MORE<TAB>true|false" line saying whether the board continues past
# them.
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

# ---------------------------------------------------------------------------
# The write path
# ---------------------------------------------------------------------------
#
# Writes name their repository instead of searching the board for it, which is
# the one place the write path is deliberately less willing than the read path.
# A located repository is a fair answer to "show me task 22" and an unfair
# target for a mutation: two repositories on one board can both hold an issue
# numbered 22, and the write cannot be taken back.

# Every ID a write needs arrives in one call: the board's ID, each field's ID
# with the IDs of the values it can take, the repository's ID and real
# visibility, and -- for an existing task -- the issue's ID with its item ID on
# this board. Resolving twice would mean two snapshots, and a field renamed
# between them leaves a mutation carrying an ID that the name no longer means.
#
# The board is never paged to find the item. An issue carries its own
# projectItems, so the item ID comes from the issue for the cost of a selection
# rather than a walk over every item on the board.
#
# @include keeps one document for both shapes rather than two that drift. The
# issue selection is skipped on a create, where no issue exists to name.
# shellcheck disable=SC2034  # read by the gh_tasks_* scripts that source this
GH_TASKS_RESOLVE_QUERY='query($login: String!, $num: Int!, $owner: String!, $name: String!, $issue: Int!, $withIssue: Boolean!) {
  repositoryOwner(login: $login) {
    ... on ProjectV2Owner {
      projectV2(number: $num) {
        id
        number
        title
        url
        fields(first: __FIELDPAGE__) {
          totalCount
          nodes {
            ... on ProjectV2FieldCommon { id name dataType }
            ... on ProjectV2SingleSelectField { options { id name } }
            ... on ProjectV2IterationField {
              configuration { iterations { id title } }
            }
          }
        }
      }
    }
  }
  repository(owner: $owner, name: $name) {
    id
    nameWithOwner
    visibility
    hasIssuesEnabled
    labels(first: 100) { totalCount nodes { id name } }
    issue(number: $issue) @include(if: $withIssue) {
      id
      number
      title
      state
      url
      parent { number }
      projectItems(first: 20) {
        totalCount
        nodes { id project { id number } }
      }
    }
  }
}'

# Free text goes LAST on every tagged line. A board's field names and option
# names come from whoever made the board, so a name holding a tab shifts no
# column that is read by position.
GH_TASKS_RESOLVE_JQ='
  (.data.repositoryOwner.projectV2) as $p |
  (.data.repository) as $r |
  "PROJECT\t\($p.id // "")",
  "BOARDNUM\t\($p.number // 0)",
  "FIELDSTOTAL\t\($p.fields.totalCount // 0)",
  "BOARDTITLE\t\($p.title | tojson)",
  "BOARDURL\t\($p.url | tojson)",
  (($p.fields.nodes // [])[] | select(.name != null) | . as $f |
    "FIELD\t\($f.dataType)\t\($f.id)\t\($f.name)",
    (($f.options // [])[] | "OPTION\t\($f.id)\t\(.id)\t\(.name)"),
    (($f.configuration.iterations // [])[] | "OPTION\t\($f.id)\t\(.id)\t\(.title)")),
  "REPOID\t\($r.id // "")",
  "REPOVIS\t\($r.visibility // "")",
  "REPOISSUES\t\($r.hasIssuesEnabled // false)",
  "LABELSTOTAL\t\($r.labels.totalCount // 0)",
  (($r.labels.nodes // [])[] | "LABEL\t\(.id)\t\(.name)"),
  (if $r.issue == null then empty else
    "ISSUEID\t\($r.issue.id)",
    "ISSUESTATE\t\($r.issue.state)",
    "ISSUEPARENT\t\($r.issue.parent.number // "")",
    "ITEMSTOTAL\t\($r.issue.projectItems.totalCount // 0)",
    "ISSUEURL\t\($r.issue.url | tojson)",
    "ISSUETITLE\t\($r.issue.title | tojson)",
    (($r.issue.projectItems.nodes // [])[]
      | select(.project.id == ($p.id // "")) | "ITEM\t\(.id)")
  end)'

# A GraphQL String! variable is passed with -f, never -F: -F parses what looks
# like a number or a boolean into one, so a login or a title of "123" would
# arrive as an Int and the query would be rejected on its type.
gh_tasks_resolve() {
  local login="$1" number="$2" repo="$3" issue="${4:-}" with=false doc
  local owner="${repo%%/*}" name="${repo#*/}"
  [[ -n "$issue" ]] && with=true
  doc="$(gh_tasks_expand "$GH_TASKS_RESOLVE_QUERY")" || exit $?
  gh_tasks_api \
    -f login="$login" -F num="$number" \
    -f owner="$owner" -f name="$name" \
    -F issue="${issue:-0}" -F withIssue="$with" \
    -f query="$doc" --jq "$GH_TASKS_RESOLVE_JQ"
}

gh_tasks_resolved() {
  printf '%s\n' "$1" | awk -F'\t' -v tag="$2" '
    $1 == tag { v = $2; for (i = 3; i <= NF; i++) v = v "\t" $i; print v; exit }'
}

# Names are matched against the board's own answer and mutations carry only the
# IDs it gave: an ID GitHub does not know is an error, where a misspelled name
# would be a write that quietly lands on nothing.
#
# Case folding is a fallback, not the match, and an ambiguous name refuses
# rather than picking -- a board may hold both `Status` and `status`, and
# neither is the obvious one.
#
# Prints "id<TAB>dataType<TAB>name", the name as the board spells it: a caller
# reporting back what the user typed would name a field the board does not have,
# and `area` matching `Area` is the whole point of folding the case.
gh_tasks_field_id() {
  local resolved="$1" want="$2" hit
  hit="$(printf '%s\n' "$resolved" | awk -F'\t' -v want="$want" '
    $1 == "FIELD" {
      name = $4; for (i = 5; i <= NF; i++) name = name "\t" $i
      if (name == want)                    { exact[++e] = $3 "\t" $2 "\t" name }
      else if (tolower(name) == tolower(want)) { fold[++f] = $3 "\t" $2 "\t" name }
    }
    END {
      if (e == 1) { print exact[1]; exit }
      if (e > 1)  { print "AMBIGUOUS"; exit }
      if (f == 1) { print fold[1]; exit }
      if (f > 1)  { print "AMBIGUOUS"; exit }
    }')"
  if [[ "$hit" == "AMBIGUOUS" ]]; then
    echo "Error: more than one field on this board is named '$want'." >&2
    echo "  Spell the one you mean exactly as the board does." >&2
    exit 1
  fi
  if [[ -z "$hit" ]]; then
    echo "Error: this board has no field named '$want'. It has:" >&2
    gh_tasks_field_list "$resolved" >&2
    exit 1
  fi
  printf '%s' "$hit"
}

gh_tasks_field_list() {
  printf '%s\n' "$1" | awk -F'\t' '
    $1 == "FIELD" {
      name = $4; for (i = 5; i <= NF; i++) name = name "\t" $i
      printf "      %s [%s]\n", name, $2
    }'
}

# Prints "id<TAB>name" for the named value of a select or iteration field, the
# name as the board spells it.
gh_tasks_option_id() {
  local resolved="$1" field="$2" want="$3" label="$4" hit
  hit="$(printf '%s\n' "$resolved" | awk -F'\t' -v fid="$field" -v want="$want" '
    $1 == "OPTION" && $2 == fid {
      name = $4; for (i = 5; i <= NF; i++) name = name "\t" $i
      if (name == want)                        { exact[++e] = $3 "\t" name }
      else if (tolower(name) == tolower(want)) { fold[++f] = $3 "\t" name }
    }
    END {
      if (e == 1) { print exact[1]; exit }
      if (e > 1)  { print "AMBIGUOUS"; exit }
      if (f == 1) { print fold[1]; exit }
      if (f > 1)  { print "AMBIGUOUS"; exit }
    }')"
  if [[ "$hit" == "AMBIGUOUS" ]]; then
    echo "Error: field '$label' has more than one value named '$want'." >&2
    exit 1
  fi
  if [[ -z "$hit" ]]; then
    echo "Error: field '$label' has no value named '$want'. It accepts:" >&2
    printf '%s\n' "$resolved" | awk -F'\t' -v fid="$field" '
      $1 == "OPTION" && $2 == fid {
        name = $4; for (i = 5; i <= NF; i++) name = name "\t" $i
        printf "      %s\n", name
      }' >&2
    exit 1
  fi
  printf '%s' "$hit"
}

# The page of labels the resolve read is searched first because it is what
# matches a name whose case differs from the repository's. GitHub's
# label(name:) is case-sensitive, so it can only answer for an exact spelling --
# but it is not bounded by that page, which is what a repository holding more
# labels than were read needs.
#
# The repository's own spelling is returned beside the id: matching ignoring
# case means the name asked for and the label applied can differ, and a report
# that echoes the request cannot show that.
gh_tasks_label_id() {
  local resolved="$1" want="$2" repo="$3" hit total read_n status=0
  hit="$(printf '%s\n' "$resolved" | awk -F'\t' -v want="$want" '
    $1 == "LABEL" {
      name = $3; for (i = 4; i <= NF; i++) name = name "\t" $i
      if (name == want)                        { exact = $2 "\t" name; exit }
      else if (tolower(name) == tolower(want)) { fold = $2 "\t" name }
    }
    END { if (exact != "") print exact; else if (fold != "") print fold }')"
  if [[ -z "$hit" ]]; then
    hit="$(gh_tasks_api -f owner="${repo%%/*}" -f name="${repo#*/}" -f label="$want" \
      -f query='query($owner: String!, $name: String!, $label: String!) {
        repository(owner: $owner, name: $name) { label(name: $label) { id name } }
      }' --jq '.data.repository.label | select(. != null) | "\(.id)\t\(.name)"')" || status=$?
    [[ "$status" -eq 0 ]] || exit "$status"
  fi
  if [[ -z "$hit" ]]; then
    total="$(gh_tasks_resolved "$resolved" LABELSTOTAL)"
    read_n="$(printf '%s\n' "$resolved" | awk -F'\t' '$1 == "LABEL" { n++ } END { print n + 0 }')"
    if [[ "${total:-0}" -gt "$read_n" ]]; then
      echo "Error: $repo has no label spelled exactly '$want'." >&2
      echo "  $read_n of its $total labels were read, and none of those matches" >&2
      echo "  ignoring case either. One beyond them is found only by its exact" >&2
      echo "  spelling, so check the case and name it as the repository has it." >&2
    else
      echo "Error: $want is not a label on this repository, among the $total read." >&2
      echo "  Create it first, or name one that exists." >&2
    fi
    exit 1
  fi
  printf '%s' "$hit"
}

# ProjectV2CustomFieldType -- GitHub's own enum of the field types a project
# defines, which is exactly the set `updateProjectV2ItemFieldValue` accepts. Every
# other dataType on a board is a view of the issue (its labels, its assignees,
# its milestone, its title), writable only on the issue itself.
gh_tasks_field_writable() {
  case "$2" in
    (TEXT|NUMBER|DATE|SINGLE_SELECT|MULTI_SELECT|ITERATION) return 0 ;;
  esac
  echo "Error: '$1' is a $2 field, which the board does not store." >&2
  case "$2" in
    (TITLE)     echo "  It shows the issue's title; change the issue." >&2 ;;
    (LABELS)    echo "  It shows the issue's labels; change them on the issue." >&2 ;;
    (ASSIGNEES) echo "  It shows the issue's assignees; change them on the issue." >&2 ;;
    (MILESTONE) echo "  It shows the issue's milestone; change it on the issue." >&2 ;;
    (*)         echo "  It is derived from the issue and cannot be set." >&2 ;;
  esac
  exit 1
}

# The guard is about publishing, not about configuration. A board found by
# linkage carries no declaration at all, which is the common case and the point
# of the design, so a write into a private repository proceeds and only a write
# that would be world-visible needs the caller to have said so out loud.
#
# A declaration, where one exists, is held to exactly. A workspace that says
# private over a repository that is not is a disagreement that only the person
# who wrote the row can settle, so these scripts refuse instead of choosing.
gh_tasks_visibility_guard() {
  local declared="$1" actual="$2" repo="$3" ok="$4"
  case "$declared" in
    (private|public)
      if [[ "$actual" != "$(printf '%s' "$declared" | tr '[:lower:]' '[:upper:]')" ]]; then
        echo "Refusing to write: $(gh_tasks_config_path) declares $declared for $repo," >&2
        echo "  but GitHub reports it $actual. Correct the row, or the repository." >&2
        exit 78
      fi
      ;;
  esac
  if [[ "$actual" == "PUBLIC" && "$ok" != "1" ]]; then
    echo "Refusing to write: $repo is PUBLIC, so this would be world-readable." >&2
    echo "  Pass --public-ok to write to it anyway." >&2
    exit 78
  fi
}

# Escapes a string for JSON output. Only the write path needs it: the readers
# echo back nothing but what the API gave them, already serialised by gh's own
# jq, while a write reports names and values that came from the command line.
#
# The control characters left after the named five have no JSON escape short of
# \u, and none of them belongs in a field name or a task title, so they are
# dropped rather than smuggled into output that then fails to parse.
gh_tasks_json_string() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  printf '"%s"' "$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
}

# One resolve asks for a repository, a board and an issue together, and one
# NOT_FOUND cannot say which of the three was missing -- while the three have
# different fixes: a wrong repository or issue number is the caller's to
# correct, a board that cannot be read is the configuration's.
#
# Each half is asked for on its own rather than the error message parsed. That
# costs up to two more queries, on a path that has already failed, and does not
# rest on the wording of a message that is not a contract.
#
# Prints "repo", "board" or "issue".
gh_tasks_resolve_blame() {
  local login="$1" number="$2" repo="$3" status=0
  gh_tasks_api -f owner="${repo%%/*}" -f name="${repo#*/}" \
    -f query='query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) { id }
    }' --jq '.data.repository.id' >/dev/null 2>&1 || status=$?
  if [[ "$status" -ne 0 ]]; then printf 'repo'; return 0; fi
  status=0
  gh_tasks_resolve "$login" "$number" "$repo" >/dev/null 2>&1 || status=$?
  if [[ "$status" -ne 0 ]]; then printf 'board'; else printf 'issue'; fi
}

# A field's value, validated and turned into whatever the mutation must carry:
# an option's ID for a select, the value itself for the rest.
#
# Set as globals rather than printed, because a TEXT value is arbitrary text. A
# value holding a tab or a newline cannot be read back out of one string, and
# both the ID the mutation carries and the spelling to report are needed.
#
# Resolving a value here rather than at the mutation is what lets a create
# validate every field before it makes anything: a misspelled option must not
# leave a task behind.
GH_TASKS_VALUE_ID=""
GH_TASKS_VALUE_SHOWN=""
gh_tasks_field_value() {
  local resolved="$1" fid="$2" kind="$3" name="$4" raw="$5" found
  GH_TASKS_VALUE_ID="$raw"
  GH_TASKS_VALUE_SHOWN="$raw"
  case "$kind" in
    (TEXT) ;;
    (NUMBER)
      if ! [[ "$raw" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        echo "Error: field '$name' takes a number; got: $raw" >&2
        exit 1
      fi ;;
    (DATE)
      if ! [[ "$raw" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "Error: field '$name' takes a date as YYYY-MM-DD; got: $raw" >&2
        exit 1
      fi ;;
    (SINGLE_SELECT|ITERATION)
      found="$(gh_tasks_option_id "$resolved" "$fid" "$raw" "$name")" || exit $?
      # shellcheck disable=SC2034  # both are read by the scripts that source this
      IFS=$'\t' read -r GH_TASKS_VALUE_ID GH_TASKS_VALUE_SHOWN <<<"$found" ;;
    (MULTI_SELECT)
      echo "Error: field '$name' takes more than one value, which these scripts do not write yet." >&2
      exit 1 ;;
    (*) gh_tasks_field_writable "$name" "$kind" ;;
  esac
}

# The field's type picks the document, so the mutation is never built around the
# value: it arrives as a typed variable, where interpolating it would hand
# whoever can name a board field a way to rewrite the mutation.
#
# A select's option ID is eight hex characters, so an ID of "12345678" is
# ordinary. Only the Float goes through -F: everything else is a String! or a
# Date!, and -F would send a numeric-looking one as a number and have the write
# rejected on its type.
gh_tasks_field_write() {
  local project="$1" item="$2" fid="$3" kind="$4" value="$5" doc var vopt=-f
  case "$kind" in
    (TEXT)          doc='value: {text: $v}';                 var='$v: String!' ;;
    (NUMBER)        doc='value: {number: $v}';               var='$v: Float!'; vopt=-F ;;
    (DATE)          doc='value: {date: $v}';                 var='$v: Date!' ;;
    (SINGLE_SELECT) doc='value: {singleSelectOptionId: $v}'; var='$v: String!' ;;
    (ITERATION)     doc='value: {iterationId: $v}';          var='$v: String!' ;;
    (*) echo "Error: a $kind field cannot be written." >&2; return 1 ;;
  esac
  gh_tasks_api -f p="$project" -f i="$item" -f f="$fid" "$vopt" v="$value" \
    -f query="mutation(\$p: ID!, \$i: ID!, \$f: ID!, $var) {
      updateProjectV2ItemFieldValue(input: {projectId: \$p, itemId: \$i, fieldId: \$f, $doc}) {
        projectV2Item { id }
      }
    }" --jq '.data.updateProjectV2ItemFieldValue.projectV2Item.id'
}
