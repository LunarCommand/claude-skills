---
name: gh-tasks
description: Always use this skill when the user asks about a project's task queue or backlog kept on GitHub — "where are we", "what's next", "what's outstanding", "what's left to do", "what am I blocked on", "what's in progress", "show me the board", "what did we close recently", "status of the queue", "read the task board", "show task 22", "what is issue 14 about". Use it to read a GitHub Project board whose items are issues, to find which board belongs to the current repository, and to read one task in full with its history. Do not use it to triage a repository's inbound issues from other people, and do not use it for pull-request review comments.
---

# GitHub task board

Reads a project's working queue — follow-ups, deferred decisions, the "what's
next" list — kept as GitHub issues on a GitHub Project.

**This version reads. It does not write.** No add, update, close or reorder yet.
When the user asks for one, say so plainly and offer to do it by hand; do not
improvise with `gh issue` or `gh api`.

## Bundled scripts

Every GitHub call goes through these — never `gh api`, `gh project` or `gh issue`
directly:

- `gh_tasks_board.sh` — the whole board as JSON: its fields, its items in board
  order, the counts
- `gh_tasks_show.sh <issue_number>` — one task with its board fields and its
  comments

**Invoke each by bare name**, never by a path. A path-qualified call prompts even
though the script is pre-approved, because the permission rules match the bare
form.

Both take `--owner <login> --number <N>` to name a board directly, which skips
discovery. `gh_tasks_board.sh` also takes `--state open|closed|all` (default
`open`), `--order board|closed`, `--all` to read every page, and `--limit`.
`gh_tasks_show.sh` takes `--repo` to skip the board lookup and `--comments N`.

`GH_TASKS_FIELD_PAGE` raises how many of a board's fields are read per item
(default 50, maximum 100).

Run each on its own — never chain them.

## The model

- **Each task is an issue.** The title is its one-line claim, the body the
  working note.
- **The board is the index**, and its fields are the columns.
- **History lives in comments.** A change of mind, a correction, a ruling
  reversed: each is a comment. The body says only what is true now, so a
  question about *why* something changed is answered from comments.

## Reading the board

`gh_tasks_board.sh` prints one JSON object:

- **`items`** — the tasks, in board order.
- **`counts`** — `onBoard`, `openSeen`, `closedSeen`, `nonIssueSeen`,
  `returned`, `unread`, `pagesRead`, `allPagesRead`.
- **`schema`** — the board's actual fields and their types.
- **`warnings`** — plain sentences for the user.
- **`board`**, **`discovery`**, **`stateFilter`**, **`order`** — what was read
  and how.

Five rules govern what you may say from it.

**1. `items` is in board order, and that order is the answer to "what's next".**
It is the board's own manual position, what a drag sets. It is not a field and
cannot be sorted on. Do not re-sort it. The one exception is `--state closed`,
which orders by when each task closed, and `order` always says which you have.

**2. When `allPagesRead` is false, quote `counts.unread`.** That is the number
of items you did not see. Do not compute it yourself — **`onBoard - returned` is
not it**, because `onBoard` counts every item in every state while `returned` is
what survived `stateFilter`. Either quote `unread` or re-run with `--all`.
Never describe a partial read as the state of the queue.

**3. A field absent from an item's `fields` means unset only when
`fieldsUndecoded` is 0.** That key counts field values whose type these scripts
do not decode. When it is above zero, a field missing from that item may still
have a value, and you must not report it as empty, unset or zero. `schema` lists
what the board has; `fields` lists what was read.

**4. `truncated` names each connection that was capped.** An item listing
`"truncated": ["subIssues"]` has more sub-issues than are in its array, so
counting the array gives a wrong number. Say "at least N" or re-read the item
with `gh_tasks_show.sh`.

**5. Repeat `warnings` to the user.** Do not filter them out or summarise them
away. They are the only channel that reports a board that changed mid-read, a
visibility mismatch, or fields that went unread.

## Reading one task

`gh_tasks_show.sh` prints one JSON object: `issue`, `title`, `state`, `url`,
`repo`, `visibility`, `repoResolution`, `author`, `createdAt`, `closedAt`,
`warnings`, `labels`, `assignees`, `parent`, `subIssues` as
`{total, read, nodes}`, `body`, `comments` as `{total, read, nodes}`, and
`boards` — one entry per Project carrying the issue, each with its own `fields`
and `fieldsUndecoded`.

**Comments are read to a limit, 50 by default and 100 at most.** So:

- **When `comments.read` is less than `comments.total`, say how many went
  unread.**
- **Do not answer a "why did this change" question from a capped read.** Re-run
  with a higher `--comments` first. The unread comments are the likeliest place
  a reversal lives, and that is the whole reason to read comments at all.

`repoResolution` says how the issue's repository was found: `explicit` from
`--repo`, `exact` from a board item, or `searched`. A `searched` result was
located by looking in the repositories the board names and was accepted only
because the board appears among the issue's own projects — mention that it was
not among the board items read.

Its `warnings` array follows the same rule as the board's: repeat it.

## Answering "where are we"

This is the operation that matters, and it wants prose, not a table. The
motivating complaint was losing track during a long stretch of similar work, so
orient the user:

- how many items are open, and how many are in progress
- what is blocked, and on what — the board may carry a field for it, or the
  reason may be in an item's comments
- the next few items in board order, by title, not by number alone
- anything closed recently, which needs `--state closed`

Two or three short paragraphs. Name specific items. A count on its own does not
tell anyone where they are.

## Visibility

**An item is exactly as public as the repository its issue lives in.** The
board's own privacy hides the board, nothing more. A private board may hold
items from public repos, each governed by its own repo.

Never tell the user a private board makes a public item private. If `warnings`
reports a mismatch between the declared visibility and what the board holds,
pass it on — it means either the configuration or a repository changed. That
check only covers the items actually read, and says so when it could not see the
whole board.

## Setup, which nothing can do for the user

Three things are the user's to do, and each failure below is unfinished setup
rather than a broken skill. Say so once and continue.

- **The `project` token scope.** Without it the scripts exit 77 and print
  `gh auth refresh -s project`. Ordinary `gh` auth does not include it.
- **Finding the board.** A board linked to the repository is found with no
  configuration at all. Where the board and the code repos sit under different
  owners GitHub refuses to link them, so the board is named in
  `~/.claude/gh-tasks.conf` instead — one whitespace-separated row per
  repository. `install/user/gh-tasks.conf` is the template. A row takes
  precedence over a link, and `discovery.source` says which was used.
- **The permission rules**, which live in the toolkit's `install/user/settings.json`
  template. A plugin cannot ship a permissions layer, so the user merges them in.
  If every call prompts, that is why.

Two failures are environment, not defects: `Missing required command: gh`
(exit 127) means the GitHub CLI is absent or unauthenticated — tell the user to
install it and run `gh auth login`; and `command not found` on one of these
scripts means the plugin's `bin/` is not on `PATH`, so the plugin is disabled or
the session predates the install. Neither is a reason to edit a script.

## Rules

- Never call `gh api`, `gh project` or `gh issue` directly — the scripts are the
  only route, and a failing script gets fixed rather than worked around
- Never report a partial read as the whole queue; quote `counts.unread`
- Never re-sort `items`; board order is the working order
- Never claim a field is unset on an item whose `fieldsUndecoded` is above zero
- Never count a `truncated` array as complete
- Never answer "why did this change" from a capped comment read
- Repeat `warnings` from either script to the user
- Say plainly that writes are not implemented yet rather than finding another way
