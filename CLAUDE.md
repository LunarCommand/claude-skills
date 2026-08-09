# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is the **source of truth for a personal collection of Claude Code
configuration** — skills, slash commands, methodology docs, and config
templates. It is not an application — there is no build, no test runner, no lint,
no package manifest. The "artifacts" are Markdown definitions, bundled bash
scripts, and plain-JS workflow files.

Today the repo holds skills (each a directory under `skills/`), methodology docs
(under `docs/`), and config templates. Other
Claude Code config kept here in future — slash commands (Markdown files under a
`commands/` dir), agents, hooks — follows the same source→deployed model below:
authored here, copied into `~/.claude/` (or a project's `.claude/`) to take
effect.

Git remote: `github.com:LunarCommand/claude-skills`.

## The one thing to understand first: source vs. deployed

**Editing a file here does not change any running skill.** Skills only take
effect once copied into a skills directory:

- Global (every repo): `~/.claude/skills/<name>/`
- Project-scoped (one repo): `<project>/.claude/skills/<name>/`

Every `SKILL.md` references its own scripts by the **deployed** path
(`~/.claude/skills/<name>/scripts/...`), never by a path inside this repo. So the
workflow is: edit here → re-copy to the skills dir → the change is live.
`install.sh` at the repo root does that copy for every skill under `skills/` (and
installs the example user CLAUDE.md).

When asked to "update the X skill," clarify whether that means editing the source
here, the deployed copy under `~/.claude/skills/`, or both. They drift
independently.

## Repository layout

Each top-level directory has one role:

- `skills/` — **the installable skills**, one directory per skill
  (`adversarial-review/`, `feature-planning/`, `hyperdx/`, `langfuse/`,
  `pr-review/`). Each is a `SKILL.md` + (usually) a `scripts/` dir or a
  `*.workflow.js` engine. `install.sh` copies each into `~/.claude/skills/`.
- `docs/` — **methodology docs**, not installed. `docs/ai-review/` covers how to
  get high-value review out of AI (the reasoning behind the `adversarial-review`
  skill).
- `project-files/` — **templates to copy into a consuming project**: `.agent.env`
  (secrets/config the scripts read) and `.claude/settings.json` (a permissions
  allowlist that pre-approves the skill scripts).
- `user-claude-md/CLAUDE.md` — the recommended global user-level CLAUDE.md (the
  plan→implement→test→handoff workflow) the skills and settings are tuned to.
  Shipped as the example `install.sh` installs; reference, not active in-repo.
- `scripts/validate.sh` — **the checks** (see Testing / validation below). One
  script, called by both CI and the optional pre-commit hook so they can't drift.
- `.github/workflows/validate.yml` — runs `scripts/validate.sh` on push and PR.
- `.githooks/pre-commit` — opt-in local hook (`git config core.hooksPath
  .githooks`) running the fast subset.
- `install.sh`, `LICENSE`, `README.md` — the installer, MIT license, and the
  public-facing overview of the toolkit.

## Skill anatomy

A skill is a directory containing:

- `SKILL.md` — YAML frontmatter (`name`, `description`) followed by instructions.
  **The `description` is load-bearing**: it is the trigger text that decides when
  the skill auto-activates, so it enumerates trigger phrases exhaustively and is
  written in an imperative "Always use this skill when..." style. Match that style
  when editing.
- `scripts/` — bash CLIs that do the actual external work.
- optionally `*.workflow.js` — a multi-agent engine the skill escalates to.

### The bundled-script invariant

Across every skill, the strongest recurring rule is: **all external access goes
through the bundled script — never raw `curl`, `gh api`, direct REST calls, or
manual env exports.** Skills repeat this because the alternatives trigger
permission prompts and bypass the config/routing logic. When a script fails, the
instruction is to *fix the script*, not work around it. Preserve this framing in
any skill edits.

### `.agent.env` config convention

`hdx_query.sh` and `langfuse_query.sh` auto-load `.agent.env` from the **current
project root** (`$(pwd)/.agent.env`). It holds per-project config/secrets and
accepts both `KEY: VALUE` and `KEY=VALUE` lines. `project-files/.agent.env` is
the template. Scripts validate required keys and tell the user what's missing
rather than guessing.

## The scripts

Each script is self-documenting via a header comment and `--help`/usage output.
Common invocations (run from a consuming project, using deployed paths):

```bash
# HyperDX logs/traces (cloud REST or local ClickHouse-in-Docker)
~/.claude/skills/hyperdx/scripts/hdx_query.sh --query "level:err"
~/.claude/skills/hyperdx/scripts/hdx_query.sh --local --table traces --query "SpanName:call_model"

# Langfuse (auto-detects legacy v1 vs v4 API from /api/public/health)
~/.claude/skills/langfuse/scripts/langfuse_query.sh apigen        # → legacy | v4

# GitHub PR review threads
~/.claude/skills/pr-review/scripts/parse_comments.sh <owner/repo> <pr>          # list unresolved
~/.claude/skills/pr-review/scripts/parse_comments.sh <owner/repo> <pr> <index>  # detail by index
~/.claude/skills/pr-review/scripts/post_reply.sh <owner/repo> <pr> <comment_id> "<text>"
~/.claude/skills/pr-review/scripts/resolve_thread.sh <thread_node_id>
```

`hdx_query.sh` and `langfuse_query.sh` are large (400 / 700 lines) and carry real
routing logic — the Langfuse script in particular abstracts over two API
generations (legacy ≤ v3 REST vs. v4, where traces/sessions are *derived* from
observations and reads need explicit `fields` groups). Read the script header and
`skills/langfuse/SKILL.md` before touching that routing. The pr-review scripts are thin
`gh api` wrappers and are invoked one at a time — never chained.

## Workflow JS files (`*.workflow.js`)

`skills/adversarial-review/` contains two, run by the **Workflow tool** (not
node). Hard constraints, stated in their headers and enforced by the runtime:

- Plain JS only — **no TypeScript, no filesystem, no `Date.now()` /
  `Math.random()` / `new Date()`** (they break resume).
- Must open with a pure-literal `export const meta = {...}` block whose `phases`
  match the `phase()` calls in the body.
- They orchestrate many parallel subagents (review lenses → merge → refute-verify
  → severity-rank). `args` carries `scope`/`context`/`invariants`; several fields
  (`isolate`, `reviewRef`) exist to handle git-worktree isolation safely.
- `spec-accept-review.workflow.js` reviews **uncommitted** work in the real tree
  with no worktree isolation possible — its header flags this as the
  highest-risk configuration and mandates read-only agent behavior (no
  `git checkout`/`git stash`). Respect that when editing.

## Testing / validation

There is no unit-test suite — the artifacts are Markdown contracts and bash
scripts. What exists instead is `scripts/validate.sh`, which enforces the
mechanical invariants: shell/JS syntax, the Workflow-tool constraints above,
SKILL.md frontmatter (`name` matching its directory, `description` present),
config-template JSON validity, that every skill named in the settings allowlist
actually exists, repo hygiene (no macOS cruft, personal paths, or
credential-shaped strings — this repo is public), and an end-to-end `install.sh`
run into a temp `CLAUDE_HOME`.

```bash
scripts/validate.sh            # everything — what CI runs
scripts/validate.sh --quick    # skips the install integration test
SHELLCHECK_SEVERITY=warning scripts/validate.sh   # tighten the shellcheck ratchet
```

shellcheck is a **ratchet**: only `error` severity blocks, so the linter can't
turn CI red over pre-existing style. Lower-severity findings still print. Raise
the floor once they're triaged.

Beyond that, validate behavior by **running the affected script against a real
instance** (or a workflow via the Workflow tool) and checking output — CI cannot
do this, since it has no credentials. For scripts, also confirm the usage/error
paths still fire with missing args or missing `.agent.env` keys.
