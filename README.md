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

Two routes ship the same skills. **Pick one — they are alternatives, not
complements.** Both put a skill directory carrying the same plugin name where
Claude Code looks for plugins, so installing both gives you two copies competing
for one name: one silently does not load, and which one wins is not something you
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

**To approve just the skill scripts**, add these six rules. They are safe at user
scope (`~/.claude/settings.json`), which is the right choice for the marketplace
route since there is no per-project setup step:

```json
{
  "permissions": {
    "allow": [
      "Bash(adversarial_review_path.sh:*)",
      "Bash(hdx_query.sh:*)",
      "Bash(langfuse_query.sh:*)",
      "Bash(pr_review_parse_comments.sh:*)",
      "Bash(pr_review_post_reply.sh:*)",
      "Bash(pr_review_resolve_thread.sh:*)"
    ]
  }
}
```

> **Do not copy the whole `permissions` block from
> `project-files/.claude/settings.json` into your user settings.** That template
> is a *project* configuration: alongside the script rules it sets
> `defaultMode: auto` and grants `Write`, `Edit`, `Agent`, `WebFetch`,
> `Bash(find:*)`, `Bash(make:*)` and more. At user scope those apply in every
> repository you open — including untrusted ones the review skills exist to
> inspect. Use it whole only in a project you trust, as
> `<project>/.claude/settings.json`, where it also gates the git operations the
> recommended workflow says to confirm first.

A rule approves the command **name**, matching whatever `PATH` resolves it to
rather than a specific file — which is why the shipped names are distinctive
enough not to collide with anything you are likely to already have. Prefer
project scope if that trade is one you would rather not make globally.

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
