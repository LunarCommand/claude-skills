# Claude Skills Toolkit

A complete, working [Claude Code](https://claude.com/claude-code) setup for
building AI agents locally — with the observability, planning discipline, and
review depth you'd usually only have in production.

The approach is **prod-local**: run the same observability stack on your machine
that you'd run in production, so debugging an agent means querying real traces
and logs instead of adding print statements. Around that sit a plan-first
workflow with explicit human gates, and a review pass that reasons about the
whole system rather than just the diff.

It's a system, not a pile of prompts — the skills, the workflow they assume, and
the settings that let them run cleanly are built to fit together. Install it in
one command and you get the whole setup; take any single piece on its own if
that's all you want.

## What's inside

Three layers, meant to be used together.

### 1. Skills

`/`-invokable tools Claude Code loads on demand, grouped by the three concerns
above.

**Observability** — the prod-local half: real traces and logs from a stack you
run yourself.

- **hyperdx** — query logs and traces with Lucene syntax, against HyperDX cloud
  or a local instance in Docker.
- **langfuse** — inspect LLM traces, observations, sessions, scores, and
  prompts, self-hosted or cloud. Detects the server's API generation and adapts
  to either the legacy v1 REST API or the v4 read API.

**Planning** — decide before you build.

- **feature-planning** — a plan-before-code workflow with two human approval
  gates, driven from a requirements file or a description in chat.

**Review** — catch what a diff-scoped bot structurally can't.

- **adversarial-review** — multi-lens review that *generates* findings:
  independent lenses hunt for what breaks, each finding is verified by
  refutation before it surfaces, and survivors are ranked by severity.
- **pr-review** — the other half of that loop: triage existing GitHub review
  threads one at a time, proposing a verdict for each before replying and
  resolving.

### 2. The recommended user CLAUDE.md

`user-claude-md/CLAUDE.md` — the plan → implement → test → hand-off loop the
skills assume, with explicit gates where you review before anything is committed
or pushed. It also carries the house style the skills are tuned to: commit
message, branch naming, PR summary, release and code comment conventions. Adopt
it as your global `~/.claude/CLAUDE.md`, or lift the parts you want.

### 3. Per-project settings

`project-files/` — an `.agent.env` template the skill scripts read for
configuration, and a `.claude/settings.json` permission allowlist that
pre-approves those scripts while still gating the git operations the workflow
says to confirm first.

## Prerequisites

Claude Code, plus whatever the skills you actually install shell out to:

| Skill | Needs |
| --- | --- |
| **hyperdx** | `jq`, plus `curl` for cloud mode or `docker` for local mode |
| **langfuse** | `curl`, `python3` |
| **pr-review** | `gh`, authenticated via `gh auth login` (no `jq` — gh has its own) |
| **adversarial-review** | nothing beyond Claude Code |
| **feature-planning** | nothing beyond Claude Code |

Each script checks its own dependencies first and names what's missing, rather
than failing partway through a query.

## Install

Three routes ship the same skills. **Pick one — they are alternatives, not
complements.** Each puts a skill directory carrying the same plugin name where
Claude Code looks for plugins, so using two gives you two copies competing for
one name: one silently does not load, and which one wins is not something you
control.

### Plugin marketplace (per-skill, versioned)

```
/plugin marketplace add LunarCommand/claude-skills
/plugin install hyperdx@lunar-skills
```

Each skill is its own plugin, so you install only what you want:
`hyperdx`, `langfuse`, `feature-planning`, `adversarial-review`, `pr-review`.
Updates arrive through `/plugin marketplace update lunar-skills`. Plugin skills
are namespaced, so the explicit invocation is `/hyperdx:hyperdx`.

Like the clone route, this one installs skills and nothing else — see
[Per-project setup](#per-project-setup) below, and copy
[`user-claude-md/CLAUDE.md`](user-claude-md/CLAUDE.md) by hand if you want it.

### Clone and install (all skills at once)

```bash
git clone https://github.com/LunarCommand/claude-skills.git
cd claude-skills
./install.sh
```

`install.sh` copies the skills into `~/.claude/skills/<name>/` (backing up any
existing copy first). Skills are the only thing it installs: the recommended
user CLAUDE.md is written alongside as `~/.claude/CLAUDE.md.recommended` for you
to review and merge, never as your live `CLAUDE.md`, and the per-project setup
steps are printed rather than applied. Skills installed this way are not
namespaced — the explicit invocation is `/hyperdx`.

### Copy a skill by hand

To take one skill without cloning the marketplace or running the installer, copy
its directory into `~/.claude/skills/<name>/` yourself:

```bash
cp -R claude-skills/skills/hyperdx/. ~/.claude/skills/hyperdx/
chmod +x ~/.claude/skills/hyperdx/bin/*.sh
```

**The trailing `.` is load-bearing.** `.claude-plugin/` is a hidden directory, so
a `cp -R .../hyperdx/* ...` glob skips it without saying so. Missing that
manifest, Claude Code treats the directory as an inert folder rather than a
skills-directory plugin: `bin/` never joins the Bash tool's `PATH`, every
bare-name call fails with `command not found`, and the permission rules below
cannot match anything you would actually type. `install.sh` uses the same
trailing-dot form for exactly this reason.

Restart Claude Code after copying, then confirm the manifest arrived:

```bash
ls -A ~/.claude/skills/hyperdx/     # want: .claude-plugin  SKILL.md  bin
```

`which hdx_query.sh` is not a useful test. Claude Code puts `bin/` on its own
Bash tool's `PATH`, not on your login shell's, so `which` finds nothing on every
route — including the ones that work. And a bare call that fails with
`Permission denied` rather than `command not found` means the manifest is fine
and the executable bit was lost in the copy, which the `chmod` above restores.

### Per-project setup

Each project that uses the **hyperdx** or **langfuse** skills needs an
`.agent.env` in its root. If you cloned the repo, copy the template:

```bash
cp path/to/claude-skills/project-files/.agent.env <your-project>/.agent.env
```

If you installed via the marketplace you have no clone, so fetch it directly —
or just create the file by hand, since it is only these keys:

```bash
curl -o <your-project>/.agent.env \
  https://raw.githubusercontent.com/LunarCommand/claude-skills/main/project-files/.agent.env
```

```
# hyperdx
HYPERDX_MODE: local            # or: cloud
OTEL_SERVICE_NAME: your-service-name
HYPERDX_LOCAL_API_KEY: your-personal-api-key
HYPERDX_CONTAINER: hdx-local

# langfuse
LANGFUSE_BASE_URL: http://localhost:3000
LANGFUSE_PUBLIC_KEY: pk-lf-...
LANGFUSE_SECRET_KEY: sk-lf-...
```

### Running the scripts without a prompt each time

The skill scripts are on the Bash tool's `PATH`, so the permission rules approve
them by bare name. Without a rule, every script call prompts — which reads as the
skill being broken when it is only unapproved.

That `PATH` entry comes from the skill's `.claude-plugin/plugin.json`. If bare
names fail with `command not found`, the manifest is missing rather than the
rules being wrong — see [Copy a skill by hand](#copy-a-skill-by-hand).

[`project-files/.claude/settings.json`](project-files/.claude/settings.json) is
the whole set, and nothing beyond it. Copy it to `<project>/.claude/settings.json`,
or merge it into `~/.claude/settings.json` if you would rather approve the
toolkit once for every repository — it is narrow enough for either scope, which
is the point of keeping it minimal:

- **the six bundled scripts**, by bare name
- **`gh repo view` / `gh pr view`** — pr-review reads the repo and PR in Step 1
- **read-only git** — `status`, `diff`, `log`, `show`, `ls-files`,
  `submodule status`: what adversarial-review reads to scope a review
- **`mkdir`, `tar czf`, `diff`** — the safety snapshot adversarial-review takes
  before reviewing a dirty tree, and the compare that proves the tree survived.
  `tar czf` rather than `tar`, so the rule covers writing an archive and not
  unpacking one

The `ask` list is the other half, and is deliberate rather than leftover. It
covers the operations the recommended workflow says to confirm — `git add`,
`git commit`, `git push`, `gh pr create` — and the destructive git commands
adversarial-review's own instructions forbid: `checkout`, `reset`, `restore`,
`stash`, `clean`. Those are prose in the skill and a prompt here, which is the
difference between an instruction an agent should follow and one it cannot
quietly skip. `git submodule foreach` is there too — the snapshot genuinely runs
it, but it takes an arbitrary command string, so it asks rather than being waved
through.

Nothing else is in the file. No `defaultMode`, no tool-level grants like `Write`
or `Edit`, no rules for tooling this repo does not ship — those are yours to
decide, and a toolkit has no business asserting them on your behalf.

A rule approves the command **name**, matching whatever `PATH` resolves it to
rather than a specific file — which is why the shipped names are distinctive
enough not to collide with anything you are likely to already have.

## How a skill works

A skill is a directory containing a `SKILL.md` (YAML frontmatter +
instructions), a `.claude-plugin/plugin.json` manifest, and any bundled
executables under `bin/`. Claude auto-invokes a skill based on its
`description`, or you can call it explicitly by name.

All external access — HyperDX, Langfuse, GitHub — goes through the bundled
scripts, never raw `curl` or `gh api`. That is deliberate: the scripts read
`.agent.env` and route to the right API.

Those scripts live in `bin/`, which Claude Code puts on the Bash tool's `PATH`
while the skill is active. So they are invoked by bare name — `hdx_query.sh
--query ...`, not a path — which is why the allowlist can approve them as
`Bash(hdx_query.sh:*)`. That rule is stable: it holds for both install routes
and does not break when a plugin updates to a new version directory.

## License

MIT — see [LICENSE](LICENSE).
