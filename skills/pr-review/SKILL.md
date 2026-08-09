---
name: pr-review
description: Use this skill when asked to review PR comments, address CoPilot feedback, respond to pull request review threads, or resolve PR conversations. Triggers on phrases like "review the PR comments", "address CoPilot feedback", "fix the PR", "go through PR comments", or any mention of pull request review threads needing attention. Always use this skill when a PR number or URL is mentioned alongside a request to review or respond to comments.
---

# PR Review Skill

Reviews all open PR comment threads one at a time. For each comment, Claude proposes its verdict and reasoning, waits for your approval, then replies and resolves.

## Bundled Scripts

All GitHub API interactions go through these scripts — never call `gh api` directly or use shell redirects:

- `scripts/parse_comments.sh <owner/repo> <pr_number>` — list all unresolved threads
- `scripts/parse_comments.sh <owner/repo> <pr_number> <index>` — full detail by 1-based index including replies
- `scripts/parse_comments.sh <owner/repo> <pr_number> --id <comment_id>` — full detail by comment database ID
- `scripts/post_reply.sh <owner/repo> <pr_number> <comment_id> "<reply text>"` — posts a reply to a comment thread
- `scripts/resolve_thread.sh <thread_node_id>` — resolves a review thread by its GraphQL node ID

Each script is invoked independently — never chain them.

## Inputs

- **`$PR`** — PR number (e.g. `123`)
  - If not provided, ask: *"Which PR number should I review?"*

## Workflow

### Step 1 — Detect Repo and Fetch Comments

First, detect the repo — never guess or hardcode it:

```bash
gh repo view --json nameWithOwner --jq '.nameWithOwner'
```

Store the result as `$REPO`. Then fetch PR details and comments:

```bash
gh pr view $PR --json number,title,headRefName,baseRefName

~/.claude/skills/pr-review/scripts/parse_comments.sh $REPO $PR

# To get full detail on a specific comment (e.g. comment 6):
~/.claude/skills/pr-review/scripts/parse_comments.sh $REPO $PR 6
```

Collect every top-level comment, noting for each:
- Comment ID (numeric, for posting replies)
- Node ID (for resolving threads)
- File and line
- Full comment body

Do not evaluate or act on any comment yet. Tell the user:
**"Found N unresolved threads on PR #$PR in $REPO. I'll go through them one at a time for your approval."**

---

### Step 2 — Process Comments One at a Time

For each thread, repeat this loop:

#### 2a — Present the Comment

Show the user:

```
── Comment N of N ──────────────────────────────
File:    path/to/file.ts:42
Comment: <full comment text>

My verdict: ✅ Fix / ⚠️ Partial fix / ❌ No fix

Reason: <one or two sentences explaining why>

Proposed reply: (must not open with "Good catch", "Great point", "Real bug", or similar — start with the substance)
"<exact text Claude will post to the thread>"

Proposed code change: (if any)
<diff or description of change>
```

**STOP. Do not post the reply, make any code changes, or resolve the thread yet.**

Ask: **"Approve? (yes / edit / skip)"**

#### 2b — Wait for User Response

- **"yes" / "approve" / "looks good"** → proceed to 2c
- **"edit"** or the user provides a revised reason/reply → update the proposed reply as directed, show it again, wait for approval again
- **"skip"** → leave the thread untouched, move to the next comment

**STOP. Do not proceed until one of the above responses is received.**

#### 2c — Execute (only after approval)

Run these as **separate, sequential bash tool calls**. Never combine them with `&&`, `;`, or any other operator — each must be its own invocation so the result is visible before the next runs:

1. Post the approved reply:

```bash
~/.claude/skills/pr-review/scripts/post_reply.sh $REPO $PR $COMMENT_ID "<approved reply text>"
```

Wait for it to return. Then:

2. Apply any code changes

3. Resolve the thread:

```bash
~/.claude/skills/pr-review/scripts/resolve_thread.sh $THREAD_NODE_ID
```

Confirm: **"Done — thread resolved. Moving to next comment."**

Combining any of these into a single command is a violation of this skill, even after approval.

Then loop back to 2a for the next thread.

---

### Step 3 — Final Summary

```
PR #$PR Review Summary
──────────────────────────────────────────────────────
✅ Fixed (N):
  • file.ts:42 — removed unused import

⚠️ Partial fix (N):
  • utils.ts:17 — applied intent but not CoPilot's exact suggestion

❌ No fix (N):
  • config.ts:5 — intentional project constant, not a magic number

⏭️ Skipped (N):
  • auth.ts:88 — skipped at your request

Total threads resolved: N
```

## Rules

- ALWAYS detect `$REPO` from `gh repo view` — never hardcode or guess the org/repo
- ALWAYS use the bundled scripts for all GitHub API calls — never call `gh api` directly, never use shell pipes or redirects
- To read a specific comment in full use `parse_comments.sh $REPO $PR <index>` or `parse_comments.sh $REPO $PR --id <comment_id>` — NEVER call `gh api` directly to look up a comment body, NEVER pipe or grep the output of parse_comments.sh
- Never post a reply, make a code change, or resolve a thread without explicit user approval
- Always comment before resolving — never silently close a thread
- Never fix things Claude disagrees with just to clear the queue
- One commit at the end covering all changes, not one per comment
- If a thread is skipped, leave it completely untouched
- Reply text must never open with sycophantic acknowledgments ("Good catch", "Great point", "Real bug", "Nice find", "You're right", "Thanks for catching", etc.). Start the reply with the substantive response directly.
