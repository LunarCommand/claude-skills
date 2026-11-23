---
name: setup
description: Always use this skill when the user asks whether this toolkit is installed or configured correctly, when a bundled script prompts for permission on every call, when a script is "command not found", when a skill appears broken or absent, when asked to check, diagnose, verify or fix the setup, when asked to apply, merge or install the toolkit's permission rules or settings template, or when asked to report a bug or file an issue against the toolkit. Triggers include "is this installed right", "why does it keep asking permission", "why does it prompt every time", "command not found", "the skill is broken", "nothing happens when I run", "check my setup", "diagnose the plugin", "is the plugin loaded", "what version am I on", "did the update work", "fix my permissions", "merge the settings template", "install the permission rules", "stop it asking every time", "file an issue", "report a bug", "something is wrong with the toolkit".
---

# Setup and support skill

Diagnoses an installation, explains what the findings mean, and turns what
cannot be fixed locally into a filable issue. The diagnosis reads and changes
nothing. Merging the permission template is the one thing here that writes, and
it writes only under `--apply`. **Show the user the report's diff and get their
go-ahead before passing it.** A permission prompt normally also stands in the
way, but that prompt belongs to the harness and does not appear in a session
running with permissions bypassed or with a rule the user added themselves —
both states `lunar_doctor.sh` reports. The go-ahead is the part this skill can
actually require.

## The bundled scripts

```bash
lunar_doctor.sh          # the report
lunar_doctor.sh --raw    # same, without redacting $HOME to ~

lunar_install.sh         # what merging the permission template would change
lunar_install.sh --apply # merge it
```

Invoke each by bare name, never by a path. For `lunar_doctor.sh` the reason is
prompting: a path-qualified call prompts even though the script is approved,
because the rules match the bare form. `lunar_install.sh` prompts whatever you
do, so the reason there is a different and worse one — it reads the template out
of its own copy of the plugin, and every machine that has run `/plugin install`
has a second, older copy under `~/.claude/plugins/cache/`. A path reaches that
one and merges its stale rule set.

**Run it first, before theorising.** Most reports of a broken skill are an
unmerged permission template or a session that predates the install, and the
report separates those in one pass.

`lunar_doctor.sh` is **read-only** and always exits 0 when it ran. A non-zero
status means a usage error, not a bad installation — the findings are the
result, not the exit code. Unlike every other script here it does **not** refuse when a dependency is
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

Nothing applies the rules on its own — a plugin cannot ship a permissions layer,
and one that could pre-approve its own scripts would be granting itself the
consent the prompt exists to collect. What ships is the template, inside the
plugin, and a script that merges it when asked.

**`lunar_install.sh` reports and writes nothing. `--apply` is what writes.** Run
the first, read the diff, then run the second. It backs the file up, inserts
rules as text so the formatting survives, and checks the result against the
original before replacing anything: if the edit did not come out as planned,
nothing is written.

**If `--apply` is blocked, hand it to the user — do not route around it.** A
permission classifier can refuse the call precisely because it changes what the
agent may run; one has, naming it as undermining oversight. That is the control
working, not a fault, and it is the same judgement that keeps this script off
the allowlist. Tell the user to run `! lunar_install.sh --apply` themselves,
then restart. **Never write `~/.claude/settings.json` with the Edit tool, a
heredoc or a shell redirect instead** — that is the same change with the
verification, the backup, the collision report and the prompt all removed, and
it is the one file where losing those costs the user the ability to correct it.

**It prompts on every call, by design.** It ships with no allowlist rule because
the rule would sit in the file it writes. Approve it once you have read what it
is about to do — the prompt shows whether `--apply` was passed, which is the
only argument that changes anything.

Six of the things it hands back rather than deciding — not the whole list:

| It says | Why it stopped | What to tell the user |
| --- | --- | --- |
| `already has them in another list` | The template wants a rule in one list, their file has it in another | Their placement is the only one in force today. Adding the template's beside it would hand the stricter list the decision — `deny > ask > allow` — and the file would not show that it had. Theirs to move or keep |
| `Denied by the template, permitted by your file` | The same collision, the other way round: the template **denies** a rule they allow or ask | Do not relay this as a tidy judgement call. The denial is not in force and this merge does not put it in force. `Bash(env)` and `Bash(printenv:*)` are denied because a transcript is not somewhere an API key can be withdrawn from. Ask whether they allowed it on purpose |
| `not one rule per line` | An inline array, which it will not reflow | It prints the rules to paste. Reformatting someone's file to make room for a rule is not a thing a merge should do |
| `does not start its own line` | The file is written on one line | Same: the rules are printed to paste |
| blocked before it runs, by a permission classifier | It writes the file that decides what the agent may run, which is what the classifier is there to catch | Not a refusal from the script and not a defect. Ask the user to run `! lunar_install.sh --apply` themselves, then restart. Do not reach for the Edit tool on `~/.claude/settings.json` |
| `changed while this was running` | Something edited the settings file after the script read it | Nothing was written, and nothing is wrong. This is the one refusal where re-running is the answer, because the file did change: the next run reads it as it now stands |

Only `permissions` is touched. The user CLAUDE.md, the optional settings and the
per-project templates are merged by hand or with the Edit tool, where the diff
is visible before it lands.

**Exit 1 describes the file, not the run.** It means the settings file still
differs from the template — because this was the report and `--apply` has not
been run, or because a collision was skipped. **A report exiting 1 is the normal
case**, not a failure. Exit 0 means there is nothing left to add.

**Exit 3 is a refusal, and it is the one to read.** Nothing was written, and
stderr names what stopped it. The table above covers four; the script has more,
and the right move for any of them is the same: relay the message verbatim and
stop. Do not re-run an unchanged file — it will refuse identically — and do not
edit the script. If the message says it is a defect in the script, that is the
one case where filing an issue is the next step.

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

**The report is redacted by default** — `$HOME` prints as `~`, `.agent.env` is
reported by key name with no values, and permission rules are read as strings.
It is safe to paste. If the user ran `--raw`, ask them to re-run without it
before anything is posted.

That is `lunar_doctor.sh` only. **`lunar_install.sh` output is not redacted**:
its diff is a slice of the user's own settings file, so it belongs in the
terminal and not in an issue. Ask for the report instead.

Two things to establish before filing, because they are the two that turn a bug
into a non-bug:

- **Which copy ran.** The report's `loaded from` line. A defect in a checkout
  that is not reproducible from a released version is a different report.
- **The version**, from the Plugin section — not from the install record, which
  can describe a copy that is not running.

A failing bundled script is a bug in the script, never a reason to work around
it with raw `curl` or `gh api`. The script's error message is the bug report.
