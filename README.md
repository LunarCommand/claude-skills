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

Three layers, meant to be used together:

1. **Skills** — `/`-invokable tools Claude Code loads on demand:
   - **hyperdx** — query logs and traces from HyperDX (Lucene syntax), against
     cloud or a local instance.
   - **langfuse** — query and inspect Langfuse traces, observations, sessions,
     scores, and prompts. Handles both the legacy v1 REST API and the v4 read
     API automatically.
   - **pr-review** — triage and resolve GitHub PR review threads one at a time,
     proposing a verdict for each before replying.
   - **feature-planning** — a two-gate, plan-before-code workflow for planning
     and building a new feature.
   - **adversarial-review** — multi-lens, adversarial pre-merge review that
     *generates* findings (independent lenses, then refutation), reported by
     severity.
2. **Recommended user CLAUDE.md** (`user-claude-md/CLAUDE.md`) — the
   plan → implement → test → hand-off workflow the skills and settings are
   tuned to. Adopt it as your global `~/.claude/CLAUDE.md`, or lift the parts
   you want.
3. **Per-project settings** (`project-files/`) — an `.agent.env` template the
   skill scripts read for configuration, and a `.claude/settings.json`
   permission allowlist that pre-approves those scripts and gates the git
   operations the workflow says to confirm first.

## Install

```bash
git clone https://github.com/LunarCommand/claude-skills.git
cd claude-skills
./install.sh
```

`install.sh` copies the skills into `~/.claude/skills/<name>/` (backing up any
existing copy first) and installs the recommended user CLAUDE.md. It never
overwrites an existing `~/.claude/CLAUDE.md` — if you already have one, it
writes the recommended version alongside as `CLAUDE.md.recommended` for you to
merge. It then prints the per-project setup steps.

### Per-project setup

Each project that uses the **hyperdx** or **langfuse** skills needs an
`.agent.env` in its root — copy the template and fill in the values:

```bash
cp path/to/claude-skills/project-files/.agent.env <your-project>/.agent.env
```

To adopt the permission allowlist (so the skill scripts run without a prompt
each time), merge `project-files/.claude/settings.json` into your project's
`.claude/settings.json`.

## How a skill works

A skill is a directory under `~/.claude/skills/<name>/` containing a `SKILL.md`
(YAML frontmatter + instructions) and any bundled `scripts/`. Claude
auto-invokes a skill based on its `description`, or you can call it explicitly
with `/<name>`.

All external access — HyperDX, Langfuse, GitHub — goes through the bundled
scripts, never raw `curl` or `gh api`. That is deliberate: the scripts read
`.agent.env`, route to the right API, and are exactly what the permission
allowlist approves.

## Roadmap

- Distribute as a Claude Code **plugin marketplace** so the skills install via
  `/plugin install` with versioning and updates, alongside the install script.

## License

MIT — see [LICENSE](LICENSE).
