# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is the **source of truth for a personal collection of Claude Code
configuration** — skills, slash commands, methodology docs, and config
templates. It is not an application — there is no build, no test runner, no lint,
no package manifest. The "artifacts" are Markdown definitions, bundled bash
scripts, and plain-JS workflow files.

Today the repo holds skills (each a directory under `plugin/skills/`), methodology docs
(under `docs/`), and config templates. Other Claude Code config kept here in
future — slash commands (Markdown files under a `commands/` dir), agents, hooks —
goes into the same plugin.

Git remote: `github.com:LunarCommand/claude-skills`.

## The one thing to understand first: this repo is one plugin

This repository publishes a single Claude Code plugin named `lunar`, and
**`plugin/` is the plugin** — its entire contents and nothing else. Skills under
`plugin/skills/` load from it, scripts under `plugin/bin/` reach the Bash tool's
`PATH` through it, and `plugin/.claude-plugin/plugin.json` is its manifest.
Skills are invoked as `/lunar:<name>`.

Everything outside `plugin/` is repository material a user never receives: the
methodology docs, the checks, the templates they merge by hand, this file. That
split is deliberate and it is enforced — see the payload check below.

There is exactly one install route: the marketplace. Two ways to point at it —

- **From GitHub** — `/plugin marketplace add LunarCommand/claude-skills`, then
  `/plugin install lunar@lunar-skills`. Claude Code copies the plugin into a
  versioned cache under `~/.claude/plugins/cache/`, so an update means a new tag.
- **From a local clone** (how this repo is developed) — add a marketplace with a
  `directory` source pointing at the checkout:

  ```json
  { "source": "directory", "path": "/path/to/claude-skills" }
  ```

  Claude Code loads the checkout in place: `plugin/bin/` goes on `PATH` and the
  skills resolve to the working tree, so an edit is live after `/reload-plugins`
  — and immediately for a script, since `PATH` points at the real file. Verify
  which copy is loaded by running `adversarial_review_path.sh`, which answers for
  whichever copy contains it.

  `/plugin install` *also* writes an inert snapshot under
  `~/.claude/plugins/cache/`, pinned to the commit you installed from. Nothing
  loads from it, but it exists — which is the real reason
  `adversarial_review_path.sh` resolves from its own `BASH_SOURCE[0]` instead of
  globbing: two copies are on disk on every machine and only one of them runs.

No `SKILL.md` may reference its scripts by path — not a repo path, not a
`~/.claude/...` path, and **not `${CLAUDE_PLUGIN_ROOT}`**, which is rejected with
`Error: Contains expansion` rather than expanded. Scripts are referenced by bare
name, which is also the form the permission rules approve.

## Repository layout

Each top-level directory has one role:

- `plugin/` — **the plugin, and the whole of what a user receives.** Nothing else
  in the repository reaches them. Its contents:
  - `.claude-plugin/plugin.json` — the manifest. Its `version` gates updates for
    anyone installed from GitHub, so bump it in the same change that touches
    anything under `plugin/`; `validate.sh` fails otherwise. See
    `docs/RELEASING.md`.
  - `skills/` — one directory per skill (`adversarial-review/`,
    `feature-planning/`, `hyperdx/`, `langfuse/`, `mutation-test/`,
    `pr-review/`). Each is a `SKILL.md` plus, for `adversarial-review`, its
    `*.workflow.js` engines. Skills carry no manifest and no `bin/` of their own —
    both live at the plugin root. `validate.sh` rejects either reappearing.
  - `bin/` — every bundled script, for all skills together. Claude Code adds this
    one directory to the Bash tool's `PATH`. Basenames must therefore be unique
    across the whole toolkit, which the `pr_review_` and `mutation_test_`
    prefixes exist to guarantee.
  - `LICENSE` — the plugin is redistributed on its own, so it carries its own
    terms. `validate.sh` asserts it is byte-identical to the root copy.

  **Nothing untracked may sit inside `plugin/`.** A local `directory` marketplace
  install is a filesystem copy of the plugin root: it skips `.git` and respects
  neither `.gitignore` nor `.git/info/exclude`. A scratch directory in there is
  copied into the plugin cache verbatim, which is how a local `_tasks/` and a
  gitignored `.claude/` once shipped. `validate.sh` compares `plugin/` against
  `git ls-files` and fails on any difference.

  That check walks the **repository**, deliberately. A cache-side version of it
  would be tempting — the installed tree is what a user actually has — but the
  versioned cache directory carries a `.in_use` entry that is not ours: an empty
  directory Claude Code creates at install as a runtime lease marker. Diffing
  `ls -A` of the cache against `git ls-files` reports it as an unexpected file,
  and the obvious next move is to "fix" a leak that was never there. Verified on
  macOS: the installed tree is otherwise byte-identical to
  `git ls-tree -r --name-only <ref> -- plugin`, empty diff in both directions.
- `.claude-plugin/marketplace.json` — **the marketplace catalog**
  (`lunar-skills`), one entry pointing at `"source": "./plugin"`. It sits at the
  repository root because that is where a marketplace is looked up, and outside
  `plugin/` because a user has no use for the catalog.
- `docs/` — **methodology and process docs**. `docs/ai-review/` covers how to get
  high-value review out of AI (the reasoning behind the `adversarial-review`
  skill). `docs/RELEASING.md` is authoritative on how a change actually reaches
  users — read it before proposing a tag.
- `CHANGELOG.md` — one section per release of the `lunar` plugin. Keep the
  `Unreleased` section current as work lands.
- `install/user/` — **templates the user merges into `~/.claude/`**, once, for
  every project: `settings.json` (the permissions allowlist that pre-approves the
  bundled scripts) and `CLAUDE.md` (the recommended global user-level CLAUDE.md —
  the plan→implement→test→handoff workflow the skills and settings are tuned to).
  User scope, not project scope: the plugin installs once per machine, so its
  permissions belong at the same scope, and a per-project copy would mean
  re-approving the same toolkit in every repository.
- `install/project/.agent.env` — the one genuinely per-project template.
  Endpoints and API keys differ per repo.
- `scripts/validate.sh` — **the checks** (see Testing / validation below). One
  script, called by both CI and the optional pre-commit hook so they can't drift.
- `.github/workflows/validate.yml` — runs `scripts/validate.sh` on push and PR.
- `.githooks/pre-commit` — opt-in local hook (`git config core.hooksPath
  .githooks`) running the fast subset.
- `LICENSE`, `README.md` — MIT license and the public-facing overview.

Nothing under `install/` is installed by anything. Plugins cannot ship a
permissions layer or an auto-loading CLAUDE.md, so merging by hand is the only
route there is — see the bundled-script invariant below.

## Skill anatomy

A skill is a directory under `plugin/skills/` containing:

- `SKILL.md` — YAML frontmatter (`name`, `description`) followed by instructions.
  `name` must match the directory name. **The `description` is load-bearing**:
  it is the trigger text that decides when the skill auto-activates, so it
  enumerates trigger phrases exhaustively and is written in an imperative
  "Always use this skill when..." style. Match that style when editing.
- optionally `*.workflow.js` — a multi-agent engine the skill escalates to.
  These are handed to the Workflow tool as a `scriptPath` — a file to read, not
  a command to run — so they belong beside the `SKILL.md`, not in `bin/`.
  Resolving them is still a `bin/` job: `adversarial_review_path.sh` prints the
  absolute path of a bundled file within whichever copy of the plugin is loaded,
  from its own `BASH_SOURCE[0]`. Prose ("this skill's base directory") was tried
  and does not work — with two copies on disk, the model globs and can pick the
  stale one.

A skill carries no `.claude-plugin/` and no `bin/` of its own. Both live at
`plugin/`, and `validate.sh` rejects either reappearing here: a nested manifest
would make the skill a second plugin claiming its own name, and a nested `bin/`
would never reach `PATH`.

Adding a skill is one step — create `plugin/skills/<name>/SKILL.md`. There is
nothing to register; the plugin ships whatever is under `plugin/skills/`, and
`validate.sh` fails
on a `SKILL.md` anywhere else, since only that path loads.

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
  `resolve_thread`. `bin/` is appended to the *end* of `PATH`, after `/usr/bin`
  and everything else, so a collision is not a coin toss: a same-named executable
  anywhere earlier wins outright and the plugin's copy is never reached, while
  the permission rule keeps approving the call. A generic basename therefore
  fails silently and looks like the skill misbehaving. `scripts/validate.sh`
  fails on any `*.sh` named in the docs that no longer ships, which is how a
  rename turns into a failing check rather than stale prose.
- **The settings template covers this repo's skills and nothing else**, which is
  what makes it safe at user scope — where it ships, since that is where the
  plugin installs. It was once a personal project config carrying
  `defaultMode: auto`, `Write`, `Edit`, `Agent`, `Bash(make:*)` and tooling
  unrelated to these skills, which at user scope applied to every repo the user
  opened, including untrusted ones the review skills exist to inspect. That is
  the failure the minimality prevents, and user scope is what makes the
  minimality load-bearing rather than tidy. Every entry should trace to a command
  a shipped skill actually runs; anything broader belongs in the user's own
  settings, not in a template they merge.
- **Nothing can install those rules for the user, and the docs must not imply
  otherwise.** `plugin.json` has no `permissions` field, plugins cannot ship a
  settings layer or an auto-loading CLAUDE.md, and a plugin-shipped `PreToolUse`
  hook that pre-approved its own scripts would be the plugin granting itself the
  consent the permission prompt exists to collect. Merging by hand is the only
  route there is, so every place that mentions the rules says so.

### `.agent.env` config convention

`hdx_query.sh` and `langfuse_query.sh` auto-load `.agent.env` from the **current
project root** (`$(pwd)/.agent.env`). It holds per-project config/secrets and
accepts both `KEY: VALUE` and `KEY=VALUE` lines. `install/project/.agent.env` is
the template. Scripts validate required keys and tell the user what's missing
rather than guessing.

The same rule covers **binaries**: every script that shells out preflights its
dependencies with `require_cmd` and exits 127 naming what to install. This is
load-bearing, not politeness — every SKILL.md tells the agent that a failing
script must be *fixed, not worked around*, so a bare `jq: command not found`
sends it editing working code instead of reporting a missing package. Keep the
preflight when adding a script.

`require_cmd` is currently defined once per script. That duplication was forced
while each skill was its own plugin and could not reference a file outside its
own directory; with one `plugin/bin/` it is no longer forced, and a shared helper
sourced from there is the open follow-up.

## The scripts

Each script is self-documenting via a header comment and `--help`/usage output.
That is a checked property, not a convention: `validate.sh` runs every script
with `--help` and `-h` and requires usage output and exit 0, **and** requires the
flag to be answered before the dependency preflight. A reader without `gh`
installed is the one most likely to be asking what a script needs, so exiting 127
at them answers a different question than the one asked. Add a script and it
inherits the requirement.

Common invocations, run from a consuming project — bare name, no path, because
the plugin's `bin/` is on the Bash tool's `PATH`:

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
(`plugin/bin/hdx_query.sh`) — the source tree is not on `PATH` unless a `directory`
marketplace source has this checkout loaded as the plugin.

`hdx_query.sh` and `langfuse_query.sh` are large (400 / 700 lines) and carry real
routing logic — the Langfuse script in particular abstracts over two API
generations (legacy ≤ v3 REST vs. v4, where traces/sessions are *derived* from
observations and reads need explicit `fields` groups). Read the script header and
`plugin/skills/langfuse/SKILL.md` before touching that routing. The pr-review scripts are thin
`gh api` wrappers and are invoked one at a time — never chained.

## Workflow JS files (`*.workflow.js`)

`plugin/skills/adversarial-review/` contains two, run by the **Workflow tool** (not
node). Hard constraints, stated in their headers and enforced by the runtime:

- Plain JS only — **no TypeScript, no filesystem, no `Date.now()` /
  `Math.random()` / `new Date()`** (they break resume).
- Must open with a pure-literal `export const meta = {...}` block whose `phases`
  match the `phase()` calls in the body.
- They orchestrate many parallel subagents (review lenses → merge → refute-verify
  → severity-rank). `args` carries `scope`/`context`/`invariants`; several fields
  (`isolate`, `reviewRef`) exist to handle git-worktree isolation safely.
- Both engines take `isolate`/`reviewRef`/`baseRef`. Without `isolate`,
  `spec-accept-review.workflow.js` reviews **uncommitted** work in the real tree —
  the highest-risk configuration, since a worktree can only hold committed work —
  and its read-only mandate is then the only guard. Its risk framing is
  conditional on `ISOLATE`; keep it that way when editing, and never let the
  isolated branch claim protections a submodule working tree does not have.
- The two engines duplicate four refutation mandates verbatim, because the
  Workflow runtime gives a script no imports and no filesystem. `scripts/validate.sh`
  asserts they stay byte-identical: the pair drifted twice before the check
  existed, each time shipping docs that apologised for the difference. Change a
  mandate in one engine and you must change it in the other.
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
the plugin and marketplace manifests (valid JSON, the marketplace entry's name
agreeing with the manifest it points at, every `SKILL.md` inside the plugin root
where it can actually load, plus `claude plugin validate` when the CLI is on
hand),
config-template JSON validity, that the settings allowlist and the shipped
`plugin/bin/` scripts name each other exactly, that `plugin/` holds only tracked
files so a local install cannot copy scratch directories to users, that every
script answers `--help` with usage before preflighting its dependencies,
non-portable shell idioms in every shell
artifact — GNU-only tool flags and bash 4 syntax alike, since macOS is stuck on
bash 3.2 (this workstation is Linux, so a `find -printf` or a `mapfile` passes
locally; CI runs the suite on macOS too, under the stock bash forced onto `PATH`,
which is what catches these for real), the **plugin version bump** (a change
under `plugin/` since the last `v<number>` tag must carry a higher
`version`, or everyone who installed from GitHub is stranded — see
`docs/RELEASING.md`), and repo hygiene (no macOS cruft, personal paths, or
credential-shaped strings — this repo is public).

**Every check here is syntactic.** shellcheck, the portability scan, the manifest
and allowlist agreement, `bash -n` — they test spelling, not meaning, and none of
them can tell you whether a script does what it claims. `tr '/' '_'` is valid
shell and passes all of them; it is also not injective, which is how a bundled
runner came to restore one file's contents over another and print "all files
restored" with exit 0.

So a green suite is not evidence of correctness. For anything that **writes to
the user's tree**, read its backup-and-restore path by hand before adopting it —
that was twenty lines here — and run `adversarial-review` on external code when
it arrives, not after building on it. Reviewing late meant three fixes got built
on a broken foundation, and two of those fixes were themselves blockers.

```bash
scripts/validate.sh            # everything — what CI runs
scripts/validate.sh --quick    # syntactic checks only — see below
```

`--quick` skips the mutation-test acceptance suite, ~22s of the ~29s full run.
That matters more than it sounds: the suite is the *only* check here that runs an
artifact and asserts on behaviour, so `--quick` leaves nothing but syntax. The
pre-commit hook uses it, so a clean commit hook is not evidence the scripts
work. CI runs the full suite.

Three environment variables loosen it, each a deliberate bypass rather than a
normal setting: `SHELLCHECK_SEVERITY=error`, `SHELLCHECK_OPTIONAL=1`, and
`SKIP_VERSION_CHECK=1`. The version check needs tags, so CI checks out with
`fetch-depth: 0`; without that it would pass vacuously.

One bash 3.2 hazard is worth knowing because nothing local catches it: **a
`case` statement inside a `$( )` command substitution needs a leading `(` on
every pattern**. bash 3.2 finds the end of a substitution by scanning for the
matching paren, so an unparenthesised `pat)` closes it early and the script dies
at the `;;`. Write `case $f in (*.sh) ... ;; esac`. `bash -n` on a modern bash
accepts the unparenthesised form, shellcheck says nothing, and the portability
scan is a regex over idioms rather than a parser — so the CI macOS job is the
only thing that sees it, and it sees it as a syntax error in a file that is
fine everywhere else.

shellcheck blocks at `warning` severity and the scripts are clean at that level,
so keep them there. `SHELLCHECK_SEVERITY=error` exists to stage a noisy new
script without turning CI red; it is not the normal setting.

**Which shellcheck ran is part of the result.** CI pins **0.10.0** on both
runners, installed from the upstream static binary. It used to be `apt` on Linux
and `brew` on macOS, which silently meant 0.9.0 on two of the three lint runs
(local included, since 0.9.0 is the newest this distro's apt offers) and 0.10.x
on one — so SC2327/SC2328, which catch a redirection that writes an error
message into the file it is meant to be restoring, fired on the macOS job and
nowhere else, after the commit had landed. `validate.sh` now prints the version
beside every `shellcheck` line and warns when it is below what CI pins. If that
warning appears, the local run is a subset of CI's: install the pinned binary to
`~/.local/bin` rather than trusting a green local run.

A **missing** shellcheck is a failure, not a warning — a machine that isn't
linting should not report a clean run, which is how unlinted shell once got past
the pre-commit hook and was first seen by CI. Install it
(`sudo apt-get install -y shellcheck`, matching what CI does) or set
`SHELLCHECK_OPTIONAL=1` to skip it on purpose.

Beyond that, validate behavior by **running the affected script against a real
instance** (or a workflow via the Workflow tool) and checking output — CI cannot
do this, since it has no credentials. For scripts, also confirm the usage/error
paths still fire with missing args or missing `.agent.env` keys.
