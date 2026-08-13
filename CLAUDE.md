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
effect once installed, by either of two routes:

- **Clone and copy** — `install.sh` copies each skill into
  `~/.claude/skills/<name>/` (or a project's `.claude/skills/<name>/`). Because
  each skill dir carries a `.claude-plugin/plugin.json`, Claude Code loads it as
  a *skills-directory plugin* (`<name>@skills-dir`), discovered in place.
- **Plugin marketplace** — `/plugin marketplace add LunarCommand/claude-skills`
  then `/plugin install <name>@lunar-skills`. Claude Code copies the plugin into
  a versioned cache under `~/.claude/plugins/cache/`.

No `SKILL.md` may reference its scripts by path — not a repo path, not
`~/.claude/skills/...`, and **not `${CLAUDE_PLUGIN_ROOT}`**, which resolves on
the marketplace route but passes through literally on the skills-dir route (the
Bash call is then rejected with `Error: Contains expansion`). Scripts live in
`bin/`, which Claude Code puts on the Bash tool's `PATH`, and are referenced by
bare name. That is the only spelling that works on both routes.

So the workflow is: edit here → re-copy to the skills dir → the change is live.

When asked to "update the X skill," clarify whether that means editing the source
here, the deployed copy under `~/.claude/skills/`, or both. They drift
independently.

## Repository layout

Each top-level directory has one role:

- `.claude-plugin/marketplace.json` — **the marketplace catalog** (`lunar-skills`),
  listing each skill as its own plugin with `"source": "./skills/<name>"`. Adding
  a skill means adding an entry here too; `scripts/validate.sh` fails if one is
  missing.
- `skills/` — **the installable skills**, one directory per skill
  (`adversarial-review/`, `feature-planning/`, `hyperdx/`, `langfuse/`,
  `pr-review/`). Each is a `SKILL.md` + `.claude-plugin/plugin.json` + (usually)
  a `bin/` dir or a `*.workflow.js` engine. Each directory *is* the plugin root,
  which is why the manifest sits inside it rather than under a separate
  `plugins/` tree. `install.sh` copies each into `~/.claude/skills/`.
- `docs/` — **methodology and process docs**, not installed. `docs/ai-review/`
  covers how to get high-value review out of AI (the reasoning behind the
  `adversarial-review` skill). `docs/RELEASING.md` is authoritative on how a
  change actually reaches users — read it before proposing a tag.
- `CHANGELOG.md` — grouped **by plugin**, not by repo, since each ships its own
  version. Keep the `Unreleased` section current as work lands.
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
- `.claude-plugin/plugin.json` — the plugin manifest. `name` must match the
  directory name (and the SKILL.md frontmatter `name`). `version` gates updates:
  users are only offered a new version when this string changes, so **bump it in
  the same change that touches the skill**, including prose-only SKILL.md edits —
  the Markdown is the artifact. `scripts/validate.sh` fails when a skill changed
  since the last `v*` tag without a bump. See `docs/RELEASING.md`.
- `bin/` — bash CLIs that do the actual external work. Claude Code adds this to
  the Bash tool's `PATH`, so the files must stay executable and are invoked by
  bare name. Do not reintroduce a `scripts/` dir; it is not on `PATH`.
- optionally `*.workflow.js` — a multi-agent engine the skill escalates to.
  These are handed to the Workflow tool as a `scriptPath` — a file to read, not
  a command to run — so they do **not** belong in `bin/` and are not on `PATH`.
  Resolving them is still a `bin/` job, though: `adversarial_review_path.sh`
  prints the absolute path of a bundled file within whichever copy of the skill
  is loaded. Prose ("this skill's base directory") was tried and does not work —
  with two copies of a skill on disk, the model globs and can pick the stale one.

### The bundled-script invariant

Across every skill, the strongest recurring rule is: **all external access goes
through the bundled script — never raw `curl`, `gh api`, direct REST calls, or
manual env exports.** Skills repeat this because the alternatives trigger
permission prompts and bypass the config/routing logic. When a script fails, the
instruction is to *fix the script*, not work around it. Preserve this framing in
any skill edits.

Its corollary is the **bare-name rule**: scripts are invoked as `hdx_query.sh
...`, never by any path. The permission allowlist approves exactly that form
(`Bash(hdx_query.sh:*)`), so a path-qualified or env-prefixed invocation prompts
even though the script is pre-approved.

Two consequences, both load-bearing when adding a script:

- **A rule approves a NAME, not a file.** It is a text match on the command
  string, and the name resolves through `PATH`, which the user controls and the
  plugin does not. So shipped basenames must be distinctive enough that nothing
  else plausibly owns them — this is why the pr-review scripts carry a
  `pr_review_` prefix rather than bare names like `post_reply` or
  `resolve_thread`. `scripts/validate.sh` fails on a basename shipped by two
  skills, since bare-name invocation can only ever reach one of them — and on any
  `*.sh` named in the docs that no longer ships, which is how a rename turns into
  a failing check rather than stale prose.
- **Never tell a user to put the whole settings template at user scope.** It is a
  project config carrying `defaultMode: auto`, `Write`, `Edit`, `Agent` and more;
  globally that applies to every repo they open, including untrusted ones the
  review skills exist to inspect. `README.md` lists the six script rules
  separately for exactly this reason.

### `.agent.env` config convention

`hdx_query.sh` and `langfuse_query.sh` auto-load `.agent.env` from the **current
project root** (`$(pwd)/.agent.env`). It holds per-project config/secrets and
accepts both `KEY: VALUE` and `KEY=VALUE` lines. `project-files/.agent.env` is
the template. Scripts validate required keys and tell the user what's missing
rather than guessing.

The same rule covers **binaries**: every script that shells out preflights its
dependencies with `require_cmd` and exits 127 naming what to install. This is
load-bearing, not politeness — every SKILL.md tells the agent that a failing
script must be *fixed, not worked around*, so a bare `jq: command not found`
sends it editing working code instead of reporting a missing package. Keep the
preflight when adding a script, and keep it duplicated per plugin: plugins
cannot reference files outside their own directory, so there is no shared helper
to factor it into.

## The scripts

Each script is self-documenting via a header comment and `--help`/usage output.
Common invocations, run from a consuming project — bare name, no path, because
`bin/` is on the Bash tool's `PATH`:

```bash
# HyperDX logs/traces (cloud REST or local ClickHouse-in-Docker)
hdx_query.sh --query "level:err"
hdx_query.sh --local --table traces --query "SpanName:call_model"

# Langfuse (auto-detects legacy v1 vs v4 API from /api/public/health)
langfuse_query.sh apigen        # → legacy | v4

# GitHub PR review threads (the pr_review_ prefix is deliberate — see the
# bare-name rule above: a permission rule approves a NAME, so a generic one
# could be satisfied by an unrelated executable earlier on PATH)
pr_review_parse_comments.sh <owner/repo> <pr>          # list unresolved
pr_review_parse_comments.sh <owner/repo> <pr> <index>  # detail by index
pr_review_post_reply.sh <owner/repo> <pr> <comment_id> "<text>"
pr_review_resolve_thread.sh <thread_node_id>
```

To run one *in this repo* while developing it, use its real path
(`skills/hyperdx/bin/hdx_query.sh`) — the source tree is not on `PATH`.

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
- Both are reachable from `SKILL.md` Step 3b, which picks between them by target
  (code vs spec/RFC). Adding a third engine means adding it there too. An engine
  no step routes to still runs when a user names it directly — which is how
  `spec-accept-review.workflow.js` was used for a long time — but it is invisible
  to anyone who installs the skill fresh and only reads `SKILL.md`.

## Testing / validation

There is no unit-test suite — the artifacts are Markdown contracts and bash
scripts. What exists instead is `scripts/validate.sh`, which enforces the
mechanical invariants: shell/JS syntax, the Workflow-tool constraints above,
SKILL.md frontmatter (`name` matching its directory, `description` present),
plugin and marketplace manifests (valid JSON, names agreeing with directories,
every skill listed, plus `claude plugin validate` when the CLI is on hand),
config-template JSON validity, that the settings allowlist and the shipped
`bin/` scripts name each other exactly, GNU-only shell idioms in shipped scripts
(this workstation and CI are both Linux, so a `find -printf` passes here and
fails on a user's Mac — running the code cannot catch it), repo hygiene (no
macOS cruft, personal paths, or
credential-shaped strings — this repo is public), and an end-to-end `install.sh`
run into a temp `CLAUDE_HOME`.

```bash
scripts/validate.sh            # everything — what CI runs
scripts/validate.sh --quick    # skips the install integration test
```

shellcheck blocks at `warning` severity and the scripts are clean at that level,
so keep them there. `SHELLCHECK_SEVERITY=error` exists to stage a noisy new
script without turning CI red; it is not the normal setting.

A **missing** shellcheck is a failure, not a warning — a machine that isn't
linting should not report a clean run, which is how unlinted shell once got past
the pre-commit hook and was first seen by CI. Install it
(`sudo apt-get install -y shellcheck`, matching what CI does) or set
`SHELLCHECK_OPTIONAL=1` to skip it on purpose.

Beyond that, validate behavior by **running the affected script against a real
instance** (or a workflow via the Workflow tool) and checking output — CI cannot
do this, since it has no credentials. For scripts, also confirm the usage/error
paths still fire with missing args or missing `.agent.env` keys.
