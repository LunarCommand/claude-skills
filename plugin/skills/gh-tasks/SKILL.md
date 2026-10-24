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
- `gh_tasks_show.sh <issue_number>` — one task in full, with its board fields
  and every comment

**Invoke each by bare name**, never by a path. A path-qualified call prompts even
though the script is pre-approved, because the permission rules match the bare
form.

Both take `--owner <login> --number <N>` to name a board directly, which skips
discovery. `gh_tasks_board.sh` takes `--state open|closed|all` (default `open`),
`--order board|closed`, `--all` to read every page, and `--limit`.
`gh_tasks_show.sh` takes `--repo` to skip the board lookup and `--comments N`.

`GH_TASKS_FIELD_PAGE` raises how many of a board's fields are read per item
(default 50, maximum 100). Only a board with more fields than that needs it, and
the scripts say so in `warnings` when it happens rather than quietly showing
part of an item.

Run each on its own — never chain them.

## The model

- **Each task is an issue.** The title is its one-line claim, the body the
  working note.
- **The board is the index**, and its fields are the columns.
- **History lives in comments.** A change of mind, a correction, a ruling
  reversed: each is a comment. The body says only what is true now, so a
  question about *why* something changed is answered from comments, which is
  why `gh_tasks_show.sh` reads them in full.

## Reading the board

`gh_tasks_board.sh` prints one JSON object. Four parts of it decide what you can
honestly say:

- **`items` is in board order.** That order is the board's own manual position —
  what a drag sets. It is not a field, cannot be sorted on, and the sequence
  *is* the answer to "what's next". Do not re-sort it before reporting. The one
  exception is reported in `order`: asking for closed items orders them by when
  they closed, since board position says nothing about recency.
- **`counts`.** `onBoard` is every item on the board. `returned` is how many
  you received, which is smaller whenever `stateFilter` excluded some — a board
  of 33 with 3 closed returns 30 open, and nothing is missing. `allPagesRead`
  is the one that matters: **when it is false, items went unread, so say how
  many or re-run with `--all`.** Never describe a partial read as the state of
  the queue.
- **`schema`** lists the board's actual fields. Boards differ, and this skill
  works with whatever a board has.
- **`warnings`** are for the user. Repeat them rather than filtering them out.

**Never assume a field exists.** A field with no value for an item is absent
from that item's `fields` object, so most items on a real board carry only some
of them. Read what is there; do not report a missing field as empty or zero.

## Answering "where are we"

This is the operation that matters, and it wants prose, not a table. The
motivating complaint was losing track during a long stretch of similar work, so
orient the user:

- how many items are open, and how many are in progress
- what is blocked, and on what — the board may carry a field for it, or the
  reason may be in an item's comments
- the next few items in board order, by title, not by number alone
- anything closed recently, which needs `--state closed` — that comes back
  most-recently-closed first, not in board order, because "what did we finish"
  is a question about dates

Two or three short paragraphs. Name specific items. A count on its own does not
tell anyone where they are.

## Visibility

**An item is exactly as public as the repository its issue lives in.** The
board's own privacy hides the board, nothing more. A private board may hold
items from public repos, each governed by its own repo.

Never tell the user a private board makes a public item private. If
`warnings` reports a mismatch between the declared visibility and what the
board actually holds, pass it on — it means either the configuration or a
repository changed.

## Setup, which nothing can do for the user

Three things are the user's to do, and each failure below is unfinished setup
rather than a broken skill. Say so once and continue.

- **The `project` token scope.** Without it the scripts exit 77 and print
  `gh auth refresh -s project`. Ordinary `gh` auth does not include it.
- **Finding the board.** A board linked to the repository is found with no
  configuration at all. Where the board and the code repos sit under different
  owners GitHub refuses to link them, so the board is named in
  `~/.claude/gh-tasks.conf` instead — one whitespace-separated row per
  repository. `install/user/gh-tasks.conf` is the template.
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
- Never report a partial read as the whole queue
- Never re-sort `items`; board order is the working order
- Never claim a field's value for an item whose `fields` object does not carry it
- Repeat `warnings` to the user
- Say plainly that writes are not implemented yet rather than finding another way
