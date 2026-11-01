---
name: gh-tasks
description: Always use this skill when the user asks about a project's task queue or backlog kept on GitHub — "where are we", "what's next", "what's outstanding", "what's left to do", "what am I blocked on", "what's in progress", "show me the board", "what did we close recently", "status of the queue", "read the task board", "show task 22", "what is issue 14 about" — or asks to change it: "add a task", "put this on the board", "note that for later", "set task 9 to in progress", "mark task 7 done", "close task 7 as not planned", "move this to the top", "make that one next". Use it to read a GitHub Project board whose items are issues, to find which board belongs to the current repository, to read one task in full with its history, and to add, update, close and reorder tasks. Do not use it to triage a repository's inbound issues from other people, and do not use it for pull-request review comments.
---

# GitHub task board

Reads a project's working queue — follow-ups, deferred decisions, the "what's
next" list — kept as GitHub issues on a GitHub Project.

**It reads, adds, updates, closes and reorders tasks.** What it deliberately
will not do is listed under Writing; when the user asks for one of those, say so
plainly rather than improvising with `gh issue` or `gh api`.

## Bundled scripts

Every GitHub call goes through these — never `gh api`, `gh project` or `gh issue`
directly:

- `gh_tasks_board.sh` — the whole board as JSON: its fields, its items in board
  order, the counts
- `gh_tasks_show.sh <issue_number>` — one task with its board fields and its
  comments
- `gh_tasks_add.sh --title "..."` — create a task: an issue in the destination
  repository, placed on the board, with its board fields set
- `gh_tasks_update.sh <issue_number>` — change one task: its board fields, a
  note appended as a comment, its parent
- `gh_tasks_close.sh <issue_number>` — close a task with a reason, posting a
  note first
- `gh_tasks_move.sh <issue_number>` — move a task within board order, to the
  top or after another task

**Invoke each by bare name**, never by a path. A path-qualified call prompts even
though the script is pre-approved, because the permission rules match the bare
form.

All six take `--owner <login> --number <N>` to name a board directly, which
skips discovery. The four writers take `--dry-run`, which resolves everything
and prints what it would send without sending it. `gh_tasks_board.sh` also takes `--state open|closed|all` (default
`open`), `--order board|closed`, `--all` to read every page, and `--limit`.
`gh_tasks_show.sh` takes `--repo` to skip the board lookup and `--comments N`.

`GH_TASKS_FIELD_PAGE` raises how many of a board's fields are read per item
(default 50, maximum 100). `GH_TASKS_LOCATE_PAGES` caps how many pages of a
board `gh_tasks_show.sh` reads while looking for an issue's repository
(default 10, maximum 100, 100 items per page). The whole board is read rather
than stopping at the first match, because whether two repositories carry the
same issue number is a property of the whole board; when the cap stops the read,
`boardReadComplete` is false.

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
`repo`, `visibility`, `repoResolution`, `boardReadComplete`, `author`,
`createdAt`, `closedAt`,
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

**`boardReadComplete` qualifies `repoResolution`.** It is `null` when `--repo`
named the repository, so no board was read. When it is `false` the board
continues past the items that were read, and neither `exact` nor `searched` is
settled: `exact` is the match among the items read, and another repository on
the board could hold an issue of the same number. Say so, or re-run with
`--repo` once you know which repository you mean.

Its `warnings` array follows the same rule as the board's: repeat it.

## Writing

Both writers print JSON saying what they did, under `applied` or, for a dry run,
`planned`.

**Draft first, show the user, then create.** A task's title and body are the
user's words rather than yours, so propose them and wait before
`gh_tasks_add.sh` runs. The same holds for a note. A field change the user asked
for in so many words needs no second confirmation — the instruction is the
approval, and gating every status flip makes the tool tedious enough to abandon.

**The body is never rewritten.** A task's body says what is true now and its
comments are its history, so a correction, a reversal or a change of mind is
`--note`. There is deliberately no way to replace a body.

**A new task lands at the end of board order**, which is the bottom of the
queue. Board order is the working order, so say where it landed rather than
implying it is next; `gh_tasks_move.sh` is what makes it next.

**Closing is the one write with no undo.** `gh_tasks_close.sh` posts the note
first and then closes, so the reason lands in the task's history rather than
only in its state. Propose the reason and the note and wait every time, because
reopening is not implemented: a task closed by mistake is the user's to fix by
hand. The reason is `completed`, `not-planned` or `duplicate`, and a duplicate
has to name what it duplicates with `--duplicate-of N`. An already-closed task
is refused rather than closed again.

Closing changes nothing on the board. A board that tracks state in a field as
well wants that field set with `gh_tasks_update.sh`, which the close does not
guess at.

**A move changes what is next**, so it is the user's call and not an
improvement to make unasked. `gh_tasks_move.sh` takes `--top` or `--after N`,
and both tasks must be on the board. It is the one writer with no
`--public-ok`: a position is board metadata, so nothing becomes world-readable
by being reordered. A declared visibility that disagrees with GitHub still
refuses at 78.

**A write into a public repository refuses with exit 78 unless `--public-ok` is
passed.** An issue is exactly as public as the repository it lives in, so that
flag is the one confirmation that something is about to become world-readable.
Never pass it to clear the error: ask the user, because the refusal usually
means the destination is wrong.

Exit 78 also covers a declared visibility that disagrees with the real one —
`~/.claude/gh-tasks.conf` says private where GitHub says public, or the reverse.
Only the user can settle that; report it and stop.

**Field and value names are matched against the board, never spelled into a
mutation.** A name the board does not have refuses and lists what it does have.
Matching is exact first and then case-insensitive, and a name matching two
fields refuses rather than picking one. Report the names the board came back
with — `--field "area=spec"` on a board whose field is `Area` is applied as
`Area`, and the output says so.

**A field the board derives from the issue cannot be set through the board** —
its title, labels, assignees or milestone. The refusal names where the value
actually lives. `--label` on `gh_tasks_add.sh` sets repository labels while
creating; changing them afterwards is not implemented.

**Creating validates everything before it creates anything**, so a misspelled
field value refuses while there is still no issue to delete. Fields are set
after the issue exists, and a failure there names the task that was created:
repeat that to the user, because the task is real and its fields are not what
was asked for. `gh_tasks_update.sh` reports the same way when it stops part way.

Not implemented, and worth saying plainly rather than working around: reopening
a closed task, clearing a parent, multi-select fields, changing a body, moving a
task to the bottom of the order, and adding an existing issue to the board.

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
- Repeat `warnings` from any of these scripts to the user
- Never pass `--public-ok` unless the user has said to write to a public
  repository; a refusal at exit 78 is for them to answer, not for you to clear
- Never rewrite a task's body; a correction is a note
- Always repeat a partial write: the task exists and its fields are not what was
  asked for
- Always propose a close and wait; it cannot be undone, and the reason is the
  user's to give
- Never reorder a board unasked; board order is the user's working order
- Say plainly what is not implemented — reopening, clearing a parent,
  multi-select fields, rewriting a body — rather than finding another way
