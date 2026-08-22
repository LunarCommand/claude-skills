---
name: mutation-test
description: >-
  Breaks code on purpose to find out whether the tests notice. Use when a test,
  fixture, assertion or guard has been reported as working and you want proof it
  checks something rather than merely passing; when you want to know whether a
  change is pinned by its suite; or to check a claim that some code is dead,
  unused or unreachable. Triggers on "mutation test", "mutation testing", "prove
  it fails", "are these tests real", "does this test actually assert anything",
  "is that assertion live", "did you verify it's not vacuous", "how do you know
  it's checking anything", "check test quality", or any claim that a test passes
  being offered as evidence the behaviour is correct. Also use it proactively
  before reporting harness or fixture work as done.
---

# Mutation testing

A green test run is the **null result**, not evidence. A dead assertion and a
live one produce identical output, so "it passed" discriminates nothing.

This skill establishes the one thing that does discriminate: **break the
behaviour and watch it go red.** Work is not done when it passes. It is done
when it has been seen to fail for the right reason.

## Input — and the shape decides the path

`$SCOPE` — free text. Two shapes, two paths:

| What you have | Path |
| --- | --- |
| **One claim** — an assertion, fixture or guard just written, and a doubt that it checks anything | **[Path A](#path-a--one-claim-no-tooling)**, by hand, no scripts |
| **A scope** — a PR number, a diff, a file, a topic, or a dead-code claim | **[Path B](#path-b--a-scope-scripted)**, scripted |

Resolve a Path B scope to files and line numbers:

- **A PR number** (`pr 55`, `#55`, `55`) → `gh pr diff <n>`
- **Nothing** → uncommitted work, else branch vs merge-base
- **A file or directory** → the whole file
- **A topic** (`the breaker trip logic`) → grep to the files first, say which you chose
- **A claim** (`CodeQL says _span_exporter is unused`) → skip the map, go to
  [Claim checking](#claim-checking)

Diff scope means **diff lines** — on a PR you are asking whether *this change* is
pinned, not whether the file is.

**When in doubt, take Path A first.** It is one mutation and costs a minute. A
single claim does not need scope resolution, a coverage map, or a batch runner.

## Rules for both paths

- **Break the source, never the test.** Mutating the test proves only that the
  test tests itself.
- **Never mutate test files.**
- **Never leave the tree mutated.** Path B's runner restores and verifies; Path A
  is on you. Confirm with `git status` before reporting, either way. A stray
  mutation left behind is worse than every finding is good.
- **Survivors are coverage gaps, not bugs.** The code is usually correct as
  written. The finding is that a future edit could change behaviour with the
  suite still green.
- **Do not write the tests that close the gaps** unless asked. Report, then stop —
  see [Why this reports and does not fix](#why-this-reports-and-does-not-fix).
- **When the same class keeps recurring, stop mutating and build a guard.** See
  [Retire the class](#retire-the-class).

## Path A — one claim, no tooling

For each claim under test, one at a time.

### 1. Name the claim precisely

Not "fixture 147 passes" but "fixture 147 asserts that a null `prompt_tokens`
reaches no span attribute". A claim you cannot state in one sentence cannot be
mutation-tested, because you do not know what to break.

### 2. Choose the mutation

Prefer the smallest mutation that violates the claim and nothing else. If the
claim is "X is absent when Y", make X present when Y. If it is a pair of opposite
claims (X true here, false there), you need **both directions**: a one-way
mutation can only ever kill one of them, and the survivor is not evidence of
anything.

### 3. Confirm the mutation landed — before running anything

This is the step that is skipped, and skipping it produces false "survivors".
Read the mutated line back. A find/replace that matched nothing, matched in the
wrong place, or matched a comment leaves the behaviour intact, and the green run
that follows means nothing at all.

### 4. Run, and read the failure message

Not just that it went red — *why*. A test that fails with an import error or a
fixture error when you expected an assertion failure did not exercise the claim;
it broke on the way there.

### 5. Restore, and verify the restore

`git status` and `git diff`. Confirm the file is byte-identical to where it
started. Do this before reporting anything, not after.

### 6. Report the two claims separately

"The mutation landed" and "the test caught it" are different findings. Say both.
A reader cannot tell a live assertion from a skipped step otherwise.

## Path B — a scope, scripted

Scripts are bash plus `jq`. The only stack-specific piece is `--test-cmd`, and the
line → test map is Python-only; everything else works anywhere.

Invoke by bare name — `bin/` is on the Bash tool's `PATH` whenever the skill is
installed. Never by path: the bare form is the only spelling that works on both
install routes, and it is what the permission rules match.

### 1. Resolve scope to changed lines

```bash
gh pr diff 55 | mutation_test_changed_lines.sh --suffix .py --out /tmp/changed.json
```

Pure diff parsing, so it works on any language.

### 2. Build the line → test map (Python only, and optional)

```bash
mutation_test_build_map.sh --files utils/logging_config.py --out /tmp/map.json
```

Runs the suite once with `--cov-context=test` and records which tests execute
each line. This is what lets the user name a PR instead of a test: the mapping
comes from execution, so it holds when test filenames do not mirror source
layout. Skip it for any other language and let each mutant run the whole suite.

**A map built from a red suite is invalid.** Errored tests register no context, so
their lines read as uncovered. Get the suite green first.

**Never read a repo's existing `.coverage`.** `mutation_test_build_map.sh` writes
to a temp `COVERAGE_FILE`, because a stale one from `make test` has no contexts
and every context comes back as the empty string — which reads as "1 covering
test".

### 3. Choose mutations — do not automate this part

Read the diff and pick changes a *plausible future edit* could make, where
surviving means real risk:

- **Boundaries** — `>=`↔`>`, `<`↔`<=`, off-by-one on an index or floor
- **Decision constants** — a timeout, threshold, retry count. Change to a
  different *plausible* value, not to garbage
- **Sentinels and defaults** — `None`↔`{}`, a fail-closed default flipped open
- **Operators** — `and`↔`or`, a dropped negation
- **Deleted stores** — remove a write, see if any test observes it
- **Error paths** — swallow a raise, drop a rollback, skip a cleanup

Do **not** generate every arithmetic and string mutation a tool would. On a real
file that is 80+ mutants, mostly on log strings and formatter plumbing, and
triage costs more than the findings are worth. Ten chosen mutants beat a hundred
generated ones.

```json
[{"file": "utils/logging_config.py", "line": 165,
  "find": ">=", "replace": ">", "desc": "trip boundary >= -> >"}]
```

`find`/`replace` apply to that **one line** and match **literally**, so `(`, `.`
and `*` are safe and common tokens need no uniqueness tricks.

### 4. Run

```bash
mutation_test_run_mutants.sh --spec /tmp/mutants.json --map /tmp/map.json --out /tmp/results.json
# no map / any other language:
mutation_test_run_mutants.sh --spec /tmp/mutants.json --test-cmd 'npm test --'
```

**The runner takes a baseline first.** It runs the suite unmutated before scoring
anything, and aborts with exit 2 if that is not green. Without it, a command that
fails for its own reasons — a bad flag, a missing dependency, the wrong working
directory — exits non-zero for every mutant and reports a clean sweep that proves
nothing. A green baseline is what makes a later non-zero exit mean *the tests
noticed*.

Use `--dry-run` first on a large spec to see the plan and per-mutant test counts
without touching a file. `--select-cmd 'CMD {tests}'` overrides how selected test
ids reach the runner, for stacks that need a flag rather than positional args.
`--timeout <seconds>` bounds each run so a mutant that hangs the suite cannot
hang the whole batch; it needs `timeout` or `gtimeout` on `PATH` and says so when
absent.

Serial by design — mutants share one working tree. Originals are copied up front
and restored via `trap` on exit, interrupt, or crash, then verified byte-for-byte;
a failed restore exits 3 loudly. **Check `git status` yourself afterwards anyway.**

Budget roughly: mapped lines are sub-second, import-time and unmapped lines cost
a full suite run each. Say so before running a long spec.

### 5. Report

Survivors are a to-do list, not a bug report. Rank:

- **Uncovered changed line** — nothing executes it. Strongest finding.
- **Survivor on a decision constant or fail-closed default** — worth a test.
- **Survivor on an exact boundary** — worth a test, lower urgency.
- **Survivor on logging/formatting** — usually noise. Say so and move on.

State what a survivor does *not* mean: a line covered by a test that imports it
but never asserts on it will survive, and that is the tool working.

## What a survivor means

A mutation that leaves the suite green means one of:

- **The assertion is dead** — it exists but is not pointed at anything.
- **The mutation did not land** — check step 3 again before concluding anything.
- **The mutation was not a violation** — you broke something the claim does not
  actually cover. Sharpen the claim or the mutation.
- **The claim is a negative control** — it fails only for a non-conforming
  implementation, so no conforming mutation kills it. Legitimate, but say so
  explicitly rather than leaving it looking verified.
- **The fixtures derive from the mutated value** — mutating a constant moves both
  sides together. Usually correct and refactor-safe, not a defect.

Rule out the middle three before reporting the first.

## Why this reports and does not fix

The report is the artifact. Closing a gap is a separate decision, taken with the
report in hand — the same split as `pr-review` and `adversarial-review`.

The reason is not just workflow tidiness. **A test written to kill a mutant tends
to test the mutant rather than the behaviour.** Handed `>= → >` and told "make
this fail", the path of least resistance is to assert on the exact boundary
value, which pins an implementation detail and makes the threshold harder to tune
later. You get a green suite that is no more correct and more expensive to change.

Deciding what a survivor *means* needs judgement the mutation cannot supply:

- Most survivors on a constant happen because the tests derive their fixtures
  FROM that constant, so mutating it moves both sides together. That is usually
  correct and refactor-safe, not a defect.
- Pinning the literal (`assert WINDOW == 60.0`) closes the mutant and buys
  nothing — a pure change-detector that fails on every legitimate retune.
- The useful test states the *operational* claim in absolute terms ("two minutes
  of silence means the endpoint recovered"), which kills a 60→600 mutation while
  surviving a 60→90 retune.

Those three look identical from the survivor list. Only a human reading the code
can tell them apart, so report, then stop.

## Retire the class

If the same class of defect keeps appearing, a mutation run per instance is the
wrong tool. Prefer a **structural guard** that makes the class impossible:
enumerate what each consumer actually reads and fail when something declares a
key nobody reads. That retires the class instead of re-detecting it, and it keeps
working when nobody remembers to run this skill.

## Claim checking

For "this code is dead / unused / can be removed", skip the map. Delete the thing,
run the tests it plausibly touches, report what broke. A claim that survives
deletion is probably right; one that kills two tests is answered, and the reply
writes itself. This is the only way to disagree with a static-analysis finding on
evidence rather than assertion.

## Highest-risk signal

**A test that passes the moment you wire it, with no other work**, is the most
likely to be vacuous — not the easiest win. Treat an immediate pass as a reason
to mutate, not a reason to move on.
