---
name: mutation-test
description: >-
  Proves a test actually checks something, by breaking the behaviour it claims to
  cover and confirming it goes red. Use when a test, fixture, assertion or guard
  has been reported as working and you want evidence rather than a green run, or
  to check a claim that some code is dead, unused or unreachable. Also use it for
  a SCOPED run over a PR or a diff — resolving the changed lines and mutating a
  chosen few in a throwaway worktree, to find which of them no test covers.
  Triggers on "mutation test", "mutation testing", "prove it fails", "are these
  tests real", "does this test actually assert anything", "is that assertion
  live", "did you verify it's not vacuous", "which changed lines are tested",
  "is this PR actually covered", "are the changes in PR 123 tested", "check the
  coverage on this diff", "mutation test this PR", or any claim that a test
  passes being offered as evidence the behaviour is correct. Also use it proactively before reporting harness or
  fixture work as done.
---

# Mutation testing

A green test run is the **null result**, not evidence. A dead assertion and a live
one produce identical output, so "it passed" discriminates nothing.

This skill establishes the one thing that does discriminate: **break the behaviour
and watch it go red.** Work is not done when it passes. It is done when it has
been seen to fail for the right reason.

## Scope, and what this version does not do

Two paths. **Path A** runs one claim at a time, by hand, mutating the file in
place — the right answer for code you have just written, because a worktree
cannot hold uncommitted work. **Path B** takes a PR or a diff and runs a batch
of mutants in a throwaway checkout; it needs committed work. There is still no
coverage map, so a scoped run executes the full suite once per mutant.

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
  load-bearing rather than merely tidy, and it is why this skill mutates in
  place instead of somewhere clean.

  If you use an isolated tree anyway, **do not try to prove the wiring with a
  probe first.** Three designs tried and each was defeated: breaking the syntax
  shows only that *something read* the file, a lint step objects while the
  judging step never runs; emptying it is no better, a type checker notices the
  symbol is gone without executing anything; appending a fatal statement is
  caught by a formatter reacting to the added bytes, and in Go, Rust or Java
  there is no legal top-level fatal statement to append at all. Every one of
  them measures the same thing — does the command react to these bytes changing
  — which any step that merely reads the file satisfies.

  Judge it from the results instead, where the signal is honest: **mutate
  several independent lines, and if every single mutant survives, suspect the
  environment before believing the coverage.** That cannot be fooled by a
  linter, needs no knowledge of the language, and costs nothing, because you
  were running the mutants anyway.
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

## Why this skill prompts for permission

`mutation_test_worktree.sh` deliberately ships **without** a permission rule, so
it asks before it runs. That is not unfinished setup, and adding a rule for it
is not the fix.

Its `--setup` and `--test` arguments are handed to `bash -c` verbatim. Any rule
that lets the script run unprompted approves the *wrapper*, not the payload — so
an agent that assembled a test command from a repository's README or CI config
could run it with no prompt at all. The script is invoked once per mutation
session rather than once per file, so the cost is a single prompt showing the
exact command that will execute.

## The isolation layer: `mutation_test_worktree.sh`

This skill ships three scripts, and this is the one `mutation_test_run_mutants.sh`
rests on. `mutation_test_changed_lines.sh` is a standalone diff parser that opens
no repository and is run on its own, in Path B step 1.
**The manual procedure above uses none of them** — Path A mutates in place,
which is the whole point of the in-place rule. This script is for the case
where you genuinely need an isolated tree, and [Path B](#path-b-a-scoped-run)
below is built on it: it hands the worktree to
`mutation_test_run_mutants.sh`, which refuses to run anywhere else.

```
mutation_test_worktree.sh run --test <cmd> [--setup <cmd>] [--repo <path>]
                              [--ref <ref>] [--keep] -- <command>...
```

It creates a throwaway `git worktree`, runs your command inside it, and removes
it. The worktree's path never leaves the script; your command sees it as the
working directory and in `$MUTATION_TEST_WORKTREE`, and its exit status is
passed through unchanged.

Before your command runs it establishes three things, all of them directly
observed:

1. the repository has no uncommitted or untracked changes, so the checkout
   matches what you are looking at — a worktree holds committed work only.
   **This one is skipped when `--ref` names something other than `HEAD`**, since
   the reasoning only holds while the worktree is cut from the commit your tree
   is sitting on. Path B's PR recipe always passes such a ref, so it always
   skips this; the run says so when it does
2. a `--setup` command you named ran successfully in it
3. `--test` exits 0 in it, so the baseline is green

**What it deliberately does NOT establish** is that `--test` can see a mutation
at all. Nothing exit-code-shaped can: three designs tried and each was defeated
by a step that reads a file without executing it. That is what a `control`
mutant is for — the runner establishes by experiment, mid-run, what this layer
cannot establish in advance. This script says so on success rather than implying
more.

It refuses rather than guessing, and every refusal prints a machine-readable
`mutation_test_worktree: refused: <slug>` line before exiting. It asks for
permission on every run, deliberately — see [Why this skill prompts for
permission](#why-this-skill-prompts-for-permission).

## Path B: a scoped run

For a PR or a diff, rather than one claim at a time. It needs **committed**
work, because a worktree holds nothing else — so the manual path above remains
the answer for code you have just written.

Three steps, and you make the judgement in the middle one.

**1. Get the candidate lines.**

```
gh pr diff 277 | mutation_test_changed_lines.sh --suffix .py
```

Every added or modified line in the diff, as `path<TAB>line`. Deleted lines are
absent — there is nothing left to mutate.

**Fetch the PR's head and note its SHA now**, because step 3 needs both:

```
git fetch origin pull/277/head
gh pr view 277 --json headRefOid --jq .headRefOid
```

`gh pr diff` and `gh pr view` are API calls that write nothing to your object
database, and a fork's head is never fetched by the default refspec — so without
the `git fetch` the SHA is real but absent locally, and step 3 stops with
`refused: bad-ref`. These line numbers address the PR's
head, and the worktree defaults to your own `HEAD`. Reviewing someone else's PR
from your own main is the ordinary case, so without `--ref` the numbers and the
files come from different revisions: most mutants fail to resolve, and the ones
that do can apply a short literal like `>=` cleanly to an entirely different
statement and report a verdict against it.

**2. Choose the mutations, and write them down.**

This is the part no tool does for you. Pick the lines that carry real risk,
decide what edit would be a genuine behaviour change, and write a spec. One
mutant per line, tab-separated, `find` and `replace` matched **literally**
against the single line given:

```
file<TAB>line<TAB>find<TAB>replace[<TAB>desc[<TAB>control]]

src/pkg/limits.py	42	>=	>	trip the boundary
src/pkg/limits.py	51	return True	return False
src/pkg/parse.py	12	==	!=	a line you KNOW is covered	control
```

**Include one `control`** — a mutant on a line you are confident the tests
cover. It is the difference between a result and a guess: if it dies, the tests
demonstrably see your edits, so every other survivor is a real coverage gap.

`control` is the **sixth** field, so leave the description empty to reach it
without writing one: `file⇥line⇥find⇥replace⇥⇥control`. Writing `control` in the
fifth field is refused rather than read as a description — that is the way to
believe you marked a control and not have.

**The rule is that a run in which nothing died is refused — when there is
enough to conclude from.** That means a control was given, or the survivors
span two or more distinct lines. A lone survivor is reported rather than
refused, because one mutant on one line cannot tell a broken environment from an
uncovered one. Anything
killed, control or not, proves the tests see this checkout. So a control that
survives *beside a kill* is not a refusal: it means the line you picked is not
covered after all, and the run says so and carries on. Without a control, a run
where *everything* survives is refused as probable mis-wiring — which is wrong
precisely where this tool is most often pointed, since freshly changed code is
where coverage is thinnest.

**Write it outside the repository** — `/tmp/mutants.tsv` — and pass an absolute
path. A spec written inside the repo is an untracked file, so the worktree will
not contain it and the run cannot find it. Blank lines and `#` comments are
skipped. An empty `replace` deletes the token, which is a legitimate mutation.

Ten chosen mutants beat a hundred generated ones. A generated edit that breaks
the syntax goes red for the wrong reason, which tells you nothing about
coverage.

**3. Run them in a throwaway checkout.**

```
mutation_test_worktree.sh run --ref <pr-head-sha> --test 'make test' -- \
    mutation_test_run_mutants.sh --spec /tmp/mutants.tsv --test 'make test'
```

`--ref` is the head SHA from step 1. It is not optional for a PR: it defaults to
your `HEAD`, and the spec's line numbers do not address that.

**A non-HEAD `--ref` also turns the working-tree checks off.** They exist to
catch work that would be missing from the worktree, and that reasoning only
holds when the worktree is being cut from the commit your tree is sitting on. So
on this path the clean-tree and untracked-file guards below do not run, and the
run says `the working tree is not consulted` when it skips them. The runner's
own per-target guards still apply.

The worktree layer checks the baseline is green — and, when `--ref` is HEAD or
absent, that the tree is clean; the
runner applies each mutant, runs the suite, restores the file from a byte-exact
copy it took first, and reports. Both the apply and the restore land by renaming
a file into place, so the target is never in a half-written state. Your files are never touched — and the runner **refuses to run
outside a linked worktree**, so it can never touch your main checkout. It cannot
tell a throwaway worktree from a long-lived one, which is why the restore has to
be exact rather than merely likely. `--dry-run` resolves every mutant against the source and runs no mutants — but
in this composed form it still pays the worktree layer's baseline, so it costs
**one full suite run**, not nothing. That is still worth it before ten of them.
To check a spec for typos without paying even that, run the runner with
`--dry-run` directly inside a worktree you already have. A dry run writes
nothing, so it is allowed even when your targets carry uncommitted work.

**Without `--dry-run` it will mutate that worktree.** Each mutant is undone from
a byte-exact copy taken immediately before the write, and the restore is verified
rather than assumed, so uncommitted work, untracked files and files git has been
told to ignore all come back exactly as they were. The composed form above is
still the one to reach for by default, because a fresh throwaway worktree has
nothing to lose in the first place — and a crash between the write and the
restore would still leave one mutant applied.

If an unrelated untracked file blocks the run, name it — `--untracked-ok
scratch.md`. That acknowledges one path; it does not excuse the others, so a
test you had forgotten still stops the run. **This applies to the HEAD path
only** — with the non-HEAD `--ref` of the PR recipe above, the scan does not run
and `--untracked-ok` has nothing to do.

### Reading the result

A **killed** mutant means that line is covered. A **survivor** is a coverage
gap, not a bug — the same reading as the manual path.

**If nothing was killed, the run refuses** — provided a control was given or the
survivors span two or more distinct lines. With a control it can say why: you named a line as covered and its mutant lived too, which points at
the environment rather than the coverage, since a suite resolving to a different
copy of your source produces exactly this.

**A control that survives beside a kill is reported, not refused.** Something
died, so the tests demonstrably see this checkout; the honest reading is that
the line you picked is not covered. The run names it in a NOTE and carries on,
rather than discarding a report it has just proven sound over one wrong guess —
and since there is no coverage map, guessing is the normal case.

**With no control, a run where everything survives across two or more distinct
lines is refused**, because nothing present can tell mis-wiring from genuinely
untested code. A lone survivor, or survivors all on one line, stays a reported
finding — one mutant cannot make that distinction. That is not a
hypothetical: pointing this at a freshly changed module refused four mutants
whose lines a coverage report independently called untested. Add a control and
the same run reports them as the gaps they are.

### What is still not here

No coverage map, so every mutant runs the full suite. That map is where "0
covering tests for all nine mutants" came from, and running everything is slower
but cannot be subtly wrong. No timeout, because `timeout` is GNU coreutils and
absent on a stock macOS. Mutants run serially: two in one working tree cannot be
told apart.
