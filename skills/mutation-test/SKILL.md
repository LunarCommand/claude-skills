---
name: mutation-test
description: >-
  Proves a test actually checks something, by breaking the behaviour it claims to
  cover and confirming it goes red. Use when a test, fixture, assertion or guard
  has been reported as working and you want evidence rather than a green run, or
  to check a claim that some code is dead, unused or unreachable. Triggers on
  "mutation test", "mutation testing", "prove it fails", "are these tests real",
  "does this test actually assert anything", "is that assertion live", "did you
  verify it's not vacuous", "how do you know it's checking anything", or any claim
  that a test passes being offered as evidence the behaviour is correct. Also use
  it proactively before reporting harness or fixture work as done.
---

# Mutation testing

A green test run is the **null result**, not evidence. A dead assertion and a live
one produce identical output, so "it passed" discriminates nothing.

This skill establishes the one thing that does discriminate: **break the behaviour
and watch it go red.** Work is not done when it passes. It is done when it has
been seen to fail for the right reason.

## Scope, and what this version does not do

This version runs **one claim at a time, by hand**. There is no batch runner, no
coverage map, and no scripted scope resolution — see
[Not in this version](#not-in-this-version). If you were handed a PR or a diff and
asked whether it is pinned by its suite, say so plainly and pick the claims worth
checking individually rather than implying a sweep happened.

## Rules

- **Break the source, never the test.** Mutating the test proves only that the
  test tests itself.
- **Never mutate test files.**
- **Copy the file before you touch it, and restore from that copy.** Not from git.
  The files this skill is pointed at are usually the ones just written, so they
  hold uncommitted work — `git checkout`, `git restore` and `git stash` destroy it
  rather than restoring it. `cp <file> <file>.mtbak`, mutate, then `mv` it back.
- **Mutate the file where the tests actually load it from — in place.** The
  tempting shortcut is to mutate a copy instead, so the real tree stays clean: a
  `git worktree`, a scratch checkout, a second clone. By default that does not
  work, and it fails silently. A Python editable install records an *absolute*
  path to the original source; configured source roots, prebuilt artifacts and
  installed packages behave the same way. The tests go on importing the file you
  did not touch, so every mutant passes — which is indistinguishable from a real
  coverage gap, and reads as "nothing covers this line" when the truth is
  "nothing ran your change". This is what makes the backup rule above
  load-bearing rather than merely tidy. If you do need an isolated tree, one
  check is not enough to trust it. Corrupting the file so it will not parse
  proves only that *something* read it — a lint or type-check step in a compound
  command objects and goes red while the step that actually judges mutants still
  imports the original tree. Prove it twice: break the syntax, then separately
  empty the file, and require **both** to go red. Only the second needs the code
  to have run. Then restore, confirm the suite is green again, and begin.
- **Never overwrite an existing backup.** If `<file>.mtbak` is already there when
  you go to make one, a previous run was interrupted: that file is the only
  pristine copy left and the working file is probably still mutated. Recover from
  it, verify with `cmp`, delete it, and start again. Copying over it destroys the
  original permanently — the same way a colliding backup key destroyed one in the
  batch runner this version withholds.
- **Verify the restore by content, not by `git status`.** On an already-dirty file
  `git status` says "modified" before and after the mutation and `git diff` shows a
  diff either way, so neither can tell a restored file from a still-mutated one.
  Use `cmp <file> <file>.mtbak` — or a checksum taken before the mutation — and
  delete the copy only once it matches.
- **A survivor is a coverage gap, not a bug.** The code is usually correct as
  written. The finding is that a future edit could change behaviour with the suite
  still green.
- **Do not write the test that closes the gap** unless asked. Report, then stop —
  see [Why this reports and does not fix](#why-this-reports-and-does-not-fix).
- **When the same class keeps recurring, stop mutating and build a guard.** See
  [Retire the class](#retire-the-class).

## The procedure

For each claim under test, one at a time.

### 1. Name the claim precisely

Not "fixture 147 passes" but "fixture 147 asserts that a null `prompt_tokens`
reaches no span attribute". A claim you cannot state in one sentence cannot be
mutation-tested, because you do not know what to break.

### 2. Take a copy, then choose the mutation

Copy first — that copy is the only thing standing between a mutation and lost
work. Check it does not already exist before you write it: `[[ -e <file>.mtbak ]]`
means a previous run was interrupted and left the original there, so recover from
it before doing anything else. Never copy over it. Then prefer the smallest mutation that violates the claim and nothing else.
If the claim is "X is absent when Y", make X present when Y. If it is a pair of
opposite claims (X true here, false there), you need **both directions**: a
one-way mutation can only ever kill one of them, and the survivor is not evidence
of anything.

Good targets, in rough order of value:

- **Boundaries** — `>=`↔`>`, `<`↔`<=`, off-by-one on an index or floor
- **Decision constants** — a timeout, threshold, retry count. Change to a
  different *plausible* value, not to garbage
- **Sentinels and defaults** — `None`↔`{}`, a fail-closed default flipped open
- **Operators** — `and`↔`or`, a dropped negation
- **Deleted stores** — remove a write, see if any test observes it
- **Error paths** — swallow a raise, drop a rollback, skip a cleanup

### 3. Run the test unmodified — confirm it is green

Before touching anything, run the test that claims to cover the behaviour. If it
is already failing, **stop and say so.** A red starting point makes the whole
exercise unable to answer the question: the test fails identically with and
without the mutation, so "it went red" is not evidence the mutation caused it,
and a dead assertion is indistinguishable from a live one.

Knowing the test was green beforehand is what licenses the inference. Discovering
it afterwards means running the whole thing again.

### 4. Apply the mutation, and confirm it landed — before running anything

This is the step that is skipped, and skipping it produces false "survivors".
Read the mutated line back. A find/replace that matched nothing, matched in the
wrong place, or matched inside a comment leaves the behaviour intact, and the
green run that follows means nothing at all.

### 5. Run, and read the failure message

Not just that it went red — *why*. A test that fails with an import error or a
fixture error when you expected an assertion failure did not exercise the claim;
it broke on the way there.

### 6. Restore, and verify by content

`cp <file>.mtbak <file>` — copy rather than move, so the backup survives a failed
restore — then `cmp <file> <file>.mtbak`. Delete the backup **only** once they
match. If `cmp` disagrees, leave it in place and say so: it is still the only
pristine copy, and removing it on the way past is how the original gets lost. Do this before reporting anything, not after. A stray mutation left
behind is worse than every finding is good.

### 7. Report the two claims separately

"The mutation landed" and "the test caught it" are different findings. Say both.
A reader cannot tell a live assertion from a skipped step otherwise.

## What a survivor means

A mutation that leaves the suite green means one of:

- **The assertion is dead** — it exists but is not pointed at anything.
- **The mutation did not land** — check step 4 again before concluding anything.
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
this fail", the path of least resistance is to assert on the exact boundary value,
which pins an implementation detail and makes the threshold harder to tune later.
You get a green suite that is no more correct and more expensive to change.

Deciding what a survivor *means* needs judgement the mutation cannot supply:

- Most survivors on a constant happen because the tests derive their fixtures FROM
  that constant, so mutating it moves both sides together. That is usually correct
  and refactor-safe, not a defect.
- Pinning the literal (`assert WINDOW == 60.0`) closes the mutant and buys
  nothing — a pure change-detector that fails on every legitimate retune.
- The useful test states the *operational* claim in absolute terms ("two minutes
  of silence means the endpoint recovered"), which kills a 60→600 mutation while
  surviving a 60→90 retune.

Those three look identical from a survivor list. Only a human reading the code can
tell them apart, so report, then stop.

## Retire the class

If the same class of defect keeps appearing, a mutation run per instance is the
wrong tool. Prefer a **structural guard** that makes the class impossible:
enumerate what each consumer actually reads and fail when something declares a key
nobody reads. That retires the class instead of re-detecting it, and it keeps
working when nobody remembers to run this skill.

## Claim checking

For "this code is dead / unused / can be removed", the same method answers it.
Delete the thing — from a copy, per the rules above — run the tests it plausibly
touches, and report what broke. A claim that survives deletion is probably right;
one that kills two tests is answered, and the reply writes itself. This is the
only way to disagree with a static-analysis finding on evidence rather than
assertion.

## Highest-risk signal

**A test that passes the moment you wire it, with no other work**, is the most
likely to be vacuous — not the easiest win. Treat an immediate pass as a reason to
mutate, not a reason to move on.

## Not in this version

Scoped runs — point it at a PR or a diff, resolve changed lines, build a
line-to-test coverage map, and run a batch of mutants — are **not shipped here**.
The batch runner that would do it mutates real source files, and an adversarial
review of it found a restore path that could write one file's contents over
another and still report success. Rather than ship that behind a permission rule
that lets it run without prompting, this version does the part that needs no
tooling and cannot lose your work.

Until it lands: for a diff, pick the two or three claims that actually carry risk
and run them by hand. That is slower per line and better per finding — ten chosen
mutants beat a hundred generated ones anyway.

Tracked as issue #13, which also carries the argument for building it around a
throwaway `git worktree` rather than mutate-and-restore: every blocker in the
withheld runner lived in the backup/restore path, and a runner that never touches
the working tree cannot have them.

**What a batch runner has to prove before it ships.** Round-trip integrity, on a
fixture tree built to break it: two paths that collide under whatever key the
backup uses (`a/b.py` alongside `a_b.py` defeated `tr '/' '_'`), a path with a
space, a symlink, a file named after the runner's own scratch file, and two runs
against the same tree at once. Every file byte-identical afterwards, or the run
says so loudly. The restore path is the whole product here — a mutation tool that
loses work is worse than no mutation tool, and "all files restored" printed over
a corrupted tree is worse still.
