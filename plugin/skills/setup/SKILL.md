---
name: setup
description: Always use this skill when the user asks whether this toolkit is installed or configured correctly, when a bundled script prompts for permission on every call, when a script is "command not found", when a skill appears broken or absent, when asked to check, diagnose, verify or fix the setup, or when asked to report a bug or file an issue against the toolkit. Triggers include "is this installed right", "why does it keep asking permission", "why does it prompt every time", "command not found", "the skill is broken", "nothing happens when I run", "check my setup", "diagnose the plugin", "is the plugin loaded", "what version am I on", "did the update work", "file an issue", "report a bug", "something is wrong with the toolkit".
---

# Setup and support skill

Diagnoses an installation, explains what the findings mean, and turns what
cannot be fixed locally into a filable issue. It reads; it changes nothing.

## The bundled script

```bash
lunar_doctor.sh          # the report
lunar_doctor.sh --raw    # same, without redacting $HOME to ~
```

Invoke it by bare name, never by a path — a path-qualified call prompts even
though the script is approved, because the rules match the bare form.

**Run it first, before theorising.** Most reports of a broken skill are an
unmerged permission template or a session that predates the install, and the
report separates those in one pass.

It is **read-only** and always exits 0 when it ran. A non-zero status means a
usage error, not a bad installation — the findings are the result, not the exit
code. Unlike every other script here it does **not** refuse when a dependency is
missing: it reports the absence and carries on, because a diagnostic that exits
127 has refused to answer at the moment it was most needed.

## Reading the report

Three statuses, and they mean different things:

- **`FAIL`** — this will not work until it is fixed. Act on it.
- **`warn`** — works, but something is absent or unverifiable. Judge it against
  what the user actually uses; an absent `.agent.env` matters only to someone
  reaching for hyperdx or langfuse.
- **`ok`** — nothing to do.

**Read every section before concluding.** A `FAIL` under Permissions and a clean
Plugin section is a configured-wrong install, which is a different problem from a
plugin that never loaded, and they are fixed in opposite places.

## What each finding means

| Finding | What it is | What to do |
| --- | --- | --- |
| `install kind: a checkout` | A `directory` marketplace is loading a working tree | Expected when developing the toolkit. On a consumer machine it means two install routes collided |
| `not loaded` under Install record | The install record describes a copy that is **not** running | The record is stale, not wrong. Trust the Plugin section's `loaded from` |
| `script rules: N of M` | Scripts with no allowlist rule | The template was not merged, or was merged at an older version. See below |
| `by design: … prompts on purpose` | A deliberate absence, declared in the script's own header | Nothing to do. Never "fix" it by adding a rule |
| `deny: N of 7` | The environment deny block is incomplete | Real exposure: these scripts take API keys from the environment, so `env` prints a live key into the transcript |
| `collisions` | A rule sits in two buckets | Precedence is `deny > ask > allow`, so the stricter wins and the file does not show it. Decide which the user meant; do not silently delete one |
| `gh scope` warn | `gh` lacks the `project` scope | `gh auth refresh -s project`. Without it gh-tasks exits 77 |
| `over-approved` | A rule approves a script that ships unruled on purpose | Tell the user to remove it. The rule approves the `bash -c` wrapper rather than the payload, which is why the exemption exists |
| `N rule(s) abbreviated` | A colliding rule the user wrote, not from the template | Its arguments are withheld because this output is meant for a public issue. `--raw` prints them, for reading yourself |
| `sections the template has and this file does not` | The user CLAUDE.md is missing whole sections the shipped template carries | What a copy merged from an older version looks like. Offer to merge the missing sections; it compares headings, not content, so an edited file is not flagged |

### A partially merged template is worse than none

It reads as working until it reaches the rules that are missing. A template
merged at an earlier version carries that version's rules and no more — the
read-only half of a skill works and the write half prompts, which looks like the
skill misbehaving rather than like unfinished setup.

The report counts rules rather than matching a pattern, so this case shows up as
`N of M` rather than as a reassuring non-zero.

### Fixing the permission findings

Nothing installs the rules — a plugin cannot ship a permissions layer, and one
that could pre-approve its own scripts would be granting itself the consent the
prompt exists to collect. The templates now **ship with the plugin**, so the file
is already on the machine. The report prints where.

Tell the user to merge `install/user/settings.json`, from the plugin copy the
report names, into `~/.claude/settings.json`. Merge, never replace: that file
holds their own settings too.

**Permissions load at startup, and the report reads the file.** Those are
different things, and conflating them misreads both. The report opens
`~/.claude/settings.json` on every run, so a re-run right after a merge shows the
new rules at once — a clean report confirms the merge landed on disk and says
nothing about whether this session applies it. The running session loaded its
rules at startup and keeps them until restarted, so calls can still prompt while
the report reads clean. Tell the user to restart; do not let the clean report be
read as proof the prompting has stopped.

## Reporting a bug

Only after the report is clean, or after it shows something it cannot explain.
A bug filed against unfinished setup wastes everyone's time, and the report is
how that gets ruled out first.

Issues go to `LunarCommand/claude-skills`. The repository has templates; the bug
form asks for the report's output, which is the single most useful thing an
issue can carry.

**The output is redacted by default** — `$HOME` prints as `~`, `.agent.env` is
reported by key name with no values, and permission rules are read as strings.
It is safe to paste. If the user ran `--raw`, ask them to re-run without it
before anything is posted.

Two things to establish before filing, because they are the two that turn a bug
into a non-bug:

- **Which copy ran.** The report's `loaded from` line. A defect in a checkout
  that is not reproducible from a released version is a different report.
- **The version**, from the Plugin section — not from the install record, which
  can describe a copy that is not running.

A failing bundled script is a bug in the script, never a reason to work around
it with raw `curl` or `gh api`. The script's error message is the bug report.
