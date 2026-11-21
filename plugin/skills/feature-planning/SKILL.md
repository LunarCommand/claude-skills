---
name: feature-planning
description: Use this skill whenever a user wants to plan or implement a new feature, whether they reference a requirements file or describe the feature directly in chat. Triggers include phrases like "I've created a requirements file", "review the reqs for", "new feature requirements", "requirements in /_reqs/", any mention of a .md requirements document, OR a prose description of a feature the user wants planned or built (e.g. "I want to build X that does Y"). Always use this skill when the user provides either a requirements filename or a written feature description and wants Claude to review, plan, and implement — even if they don't say "skill" or "plan" explicitly.
---

# Feature Planning Skill

A structured workflow with two human approval gates before any code is written. Claude is expected to actively contribute thinking — judge the proposed approach, poke holes in the requirements, surface missed opportunities and alternatives, and be opinionated — not just transcribe requirements into a task list.

## Right-sizing the plan

The templates in this skill show the **maximum** shape. Scale the *depth* of each section to the feature — **never drop a heading** (silently skipping a section hides what wasn't considered), but let a small feature collapse a section to a single line or an explicit `None — <reason>` (e.g. "No invariants — stateless pure transform").

Heuristic: if the feature has **none** of {persistent state, external side effects, concurrency, data migration, security/performance constraints}, treat it as **light** — one phase, 1–2 test cases, terse or `None` sections. If it has one or more, treat it as **heavy** — full given/when/then test cases, multiple invariants, phased breakdown. Proportionality scales depth, not presence: a trivial feature still gets an Invariants heading, it just reads "None — <reason>". When in doubt, ask the user rather than guess at the weight.

## When This Skill Triggers

Use this skill when:
- The user references a requirements file (e.g. `/_reqs/some-feature.md`)
- The user says something like "I've created a new requirements file for X"
- The user asks Claude to review requirements and get started
- The user describes a new feature in chat (in prose, not a file) and wants to plan or build it

## Inputs

Exactly one of:
- **`$REQUIREMENTS_FILE`** — path to a requirements file (e.g. `/_reqs/csv-export.md`)
- **`$DESCRIPTION`** — a written description of the feature, provided directly in chat

If neither is clearly provided, ask the user: *"Do you have a requirements file (give me the path), or would you like to describe the feature here in chat?"*

## Workflow

---

### Step 1 — Establish the Requirements File & Get Context

**If the user provided `$REQUIREMENTS_FILE`:**
Read it in full.

**If the user provided `$DESCRIPTION` (prose, not a file):**
1. Derive a short kebab-case slug for the feature (e.g. "CSV export" → `csv-export`).
2. Create `/_reqs/<slug>.md` (creating the `/_reqs/` directory first if it doesn't exist) with this structure:

   ```markdown
   # <Feature Name>

   ## Description
   <the user's description, preserved faithfully — capture what they said, do NOT invent requirements they didn't state>

   ## Goals
   <what the user explicitly said the feature must achieve — extract only what they stated; write "Not specified" if they didn't say>

   ## Constraints
   <tech, timing, or compatibility constraints the user mentioned — extract only; "Not specified" if none stated>

   ## Non-Goals
   <anything the user explicitly said is out of scope — extract only; "Not specified" if none stated>
   ```

   ⚠️ These scaffolding sections exist to give the later hole-poking something to bite on — they are NOT license to invent. Fill each only from what the user actually said; write "Not specified" otherwise. The gaps left by "Not specified" are exactly what Step 2's Gaps & holes analysis and Clarifying Questions should target.

3. Tell the user: *"I've captured your description in `/_reqs/<slug>.md`. From here I'll treat that as the requirements file."*
4. From this point forward, treat the newly created file as `$REQUIREMENTS_FILE` for the rest of the workflow.

**Either way**, then skim the codebase for relevant context: existing patterns, related modules, prior decisions. The goal is to enter Step 2 with enough understanding to push back intelligently, not just paraphrase.

---

### Step 2 — Append Approach Analysis AND Clarifying Questions

⚠️ **Both the analysis and the questions MUST be written to `$REQUIREMENTS_FILE` on disk. This is not optional.**

❌ NEVER do any of the following:
- Discuss the approach in chat or terminal
- List your concerns, alternatives, or questions in your response
- Run an interactive interview
- Skip the analysis because the requirements seem solid
- Skip the questions because the requirements seem clear enough

✅ The ONLY correct action is to open `$REQUIREMENTS_FILE` and append BOTH sections below to the bottom of it using your file write tools, then tell the user where to find them.

Note: when the requirements file was generated from a `$DESCRIPTION`, expect more gaps than usual — lean harder on Clarifying Questions to surface what the prose didn't cover.

The sections MUST use this exact format:

```markdown
## Approach Analysis

### What's strong about this approach
- <point>
- <point>

### Concerns & risks

**Open**
- <concern> — why it matters
- <concern> — why it matters

**Addressed**
<Empty when first written. A concern moves here when an answer or a decision settles it:>
- <concern> — settled by <the question it answered, or the Direction entry>

### Gaps & holes in the requirements
Poke holes in the requirements *as written* — this is about defects in the spec, not risks in the approach. Look for:

**Open**
- <ambiguity or under-specified behavior> — what's unclear and why it will bite
- <unstated assumption the reqs depend on> — what happens if it's false
- <missing edge case / failure mode not addressed>
- <internal contradiction or requirement that conflicts with another>
- <unstated invariant the reqs assume but never declare — a property that must always hold for the feature to be correct>

**Addressed**
<as above — what settled it, not just that it is settled>

### Opportunities worth considering
Things the user did NOT ask for but should see — adjacent wins, low-cost additions, things that would make the feature notably better. Flag them; do not assume them into scope (the user decides at Gate 1).
- **<Opportunity>** — <what it is>. Value: <low/med/high>. Cost: <low/med/high>.
- **<Opportunity>** — <what it is>. Value: <low/med/high>. Cost: <low/med/high>.

### Alternative approaches worth considering
- **<Alternative name>** — <one-line description>. Trade-off: <what you gain / lose vs. the proposed approach>.
- **<Alternative name>** — <one-line description>. Trade-off: <what you gain / lose vs. the proposed approach>.

### Direction taken at Gate 1
<Decisions the user made in chat that answer no single question. Empty until there is one.>
- <ISO date> — <the decision, in the user's terms> — <what it changes>

### My recommendation
<One paragraph. Be opinionated — pick one approach and defend it. If the proposed approach is the right one, say so and explain why the alternatives lose. If a different approach is better, say so directly.>

## Clarifying Questions

**Q: <question>**
A: 

**Q: <question>**
A: 
```

The Approach Analysis is **required** even when you fully agree with the proposed approach — in that case, your job is to explain *why* the alternatives lose so the user can sanity-check your reasoning. Rubber-stamping isn't analysis.

If you genuinely have no alternatives worth raising and zero concerns, write a brief version — but you must still poke holes in the requirements and note opportunities (or explicitly state there are none):

```markdown
## Approach Analysis

The proposed approach is the right one. I considered <alternative 1> and <alternative 2> but rejected them because <reason>. No material concerns.

### Gaps & holes in the requirements
<gaps found, or "None — requirements are complete and unambiguous.">

### Opportunities worth considering
<opportunities found, or "None worth flagging.">
```

Leave every `A:` line blank — the user will fill them in directly in the file. The user may also edit the Approach Analysis section to push back, agree, or redirect — those edits are direction changes you must respect.

Good questions to consider:
- Are there edge cases not covered?
- Are there dependencies or existing systems this must integrate with?
- What are the acceptance criteria / definition of done?
- How do we verify each behavior — what's the observable pass/fail signal for each one?
- What must be tested at the integration or end-to-end level (not just units), and what are the failure modes worth a dedicated test?
- Are there performance, security, or scalability constraints?
- What's the priority if trade-offs are needed?

If the requirements are genuinely fully unambiguous and you have zero questions, write this in place of the questions section:

```markdown
## Clarifying Questions

No clarifying questions — requirements are fully specified.
```

After writing to the file, tell the user:

> "I've added my approach analysis and clarifying questions to `$REQUIREMENTS_FILE`. Please open the file, push back on or accept the analysis, fill in your answers on the `A:` lines, then reply **'answered'** when ready."

⛔ **GATE 1 — STOP. Do not continue until the user replies with "answered".**
"done", "ready", "continue" do NOT open this gate. Only "answered" does.

#### While Gate 1 is open

**Gate 1 is usually a conversation, and the file has to keep up with it.** Answers arrive in
chat at least as often as in the file, each one opens new ground, and an analysis left as first
written ends up with half its concerns settled while still reading as live. Whenever the user
answers or decides something in chat:

- Fill the `A:` line it answers, in the user's words.
- Move each concern or gap it settles under **Addressed**, naming what settled it. Keep
  **Open** first in both sections, and write `None open.` when nothing is left, so the file
  reads top-down and can be put down at the first Addressed item.
- Record under `### Direction taken at Gate 1` any decision that answers no single question.
- Append a question the answer raised to Clarifying Questions, with a blank `A:`.
- Update the requirements file's Goals, Constraints and Non-Goals to what the user has said
  since the description — still writing only what they said, never what you inferred.
- Rewrite a claim the user corrected, and anything that rested on it.

None of this opens the gate, and none of it is Step 3. Only "answered" moves on.

---

### Step 3 — Re-read the File and Verify

Re-read `$REQUIREMENTS_FILE` in full. Check that:
- Every `A:` line has been filled in
- Any edits the user made to the Approach Analysis section — these are direction changes you must respect when writing the plan
- **Concerns & risks** and **Gaps & holes** each read `None open.` or list what is genuinely
  still open. A concern left under **Open** that an answer settled is a stale file, and the plan
  will be written against it
- `### Direction taken at Gate 1` carries every decision that answered no single question

If any `A:` lines are still blank, list the unanswered questions and wait for the user to complete them. Do not proceed until all are answered.

---

### Step 4 — Write the Final Plan to Disk

⚠️ **The plan MUST be written to disk. Outputting the plan in chat is NOT sufficient.**

Write the plan to:
**`/_plans/<feature-name>-plan.md`**
(e.g. `/_reqs/csv-export.md` → `/_plans/csv-export-plan.md`)

If `/_plans/` does not exist, create it first.

The plan file MUST include the following sections (this is the maximum shape — apply **Right-sizing the plan** to scale each section's depth to the feature; keep every heading):

```markdown
# Plan: <Feature Name>

## Summary
One-paragraph overview of what will be built and why.

## Requirements Reference
/_reqs/<requirements-file>.md

## Goals & Non-Goals

### Goals
- <what this feature must achieve>

### Non-Goals
- <what this feature will never do, by decision — "not this feature", not "not yet">

## Invariants
Properties that must hold true at ALL times, across every state and input — the design contract. An invariant is a standing safety property ("X is always true"), NOT a one-time outcome ("we achieved X" — that's Success Criteria) and NOT a risk. If it can ever be false without the feature being broken, it isn't an invariant.

- **INV-1:** <the property that must always hold> — <why it matters / what breaks if violated>
- **INV-2:** <...>

Include invariants the requirements imply but never state (surfaced in Step 2's Gaps & holes). Each invariant must be verified by at least one test in Test Definitions.

## Non-Functional Requirements
Measurable quality constraints the feature must meet — distinct from functional behavior (what it does) and invariants (what must always hold). State a target, not a vibe. Where a target is measurable, map it to a `T-<n>`; where it can only be checked by judgment, say so.

- **Performance** — <target, e.g. "p95 request latency < 200ms at 100 rps", or "None — not on a hot path">
- **Security** — <authz/authn, input validation, secrets handling, data exposure constraints, or "None beyond existing system guarantees">
- **Scalability** — <expected load / growth the design must absorb, or "None — bounded single-user operation">
- **Reliability** — <availability, retries, idempotency, failure-handling expectations, or "None specified">

Add or drop categories as the feature warrants; a light feature may reduce this whole section to `None — <reason>`.

## Success Criteria
How we know this is done and working. Measurable where possible. These are the target the Test Plan, Test Definitions, and Coverage below map back to — so define them before the test sections reference them.

## Strategy

### Chosen approach
Describe the approach in 2–4 sentences. This should reflect the conclusion from the Approach Analysis after any user feedback.

### Why this approach
Explain why this beats the alternatives considered. Reference the trade-offs.

### Alternatives rejected
- **<Alternative>** — rejected because <reason>.
- **<Alternative>** — rejected because <reason>.

## Clarifications & Decisions
- [Question] → [Answer / decision made]
- [Approach feedback from user] → [How the plan reflects it]

## Risks & Mitigations
- **<Risk>** — likelihood: <low/med/high>. Mitigation: <plan>.
- **<Risk>** — likelihood: <low/med/high>. Mitigation: <plan>.

## Implementation Plan

### Phase 1: <n>
- [ ] **P1.1** Task 1
- [ ] **P1.2** Task 2

**Verified by:** T-1, T-2 _(the test IDs from Test Definitions that prove this phase is done)_

### Phase 2: <n>
- [ ] **P2.1** Task 3

**Verified by:** T-3

## Files to Create / Modify
- `path/to/file.ts` — purpose

## Test Plan
How this feature will be verified, across levels. Be specific.

- **Unit** — <what units get covered; which modules/functions; tooling/framework>
- **Integration** — <what boundaries/interactions get covered; which real vs. mocked dependencies>
- **End-to-end** — <what user-facing flows get exercised, if any; N/A if not applicable>
- **Manual / QA** — <what a human must check that automation won't; staging steps, if any>

**Execution notes:** <how/when tests run — CI, pre-commit, local only; ordering or data-setup concerns; anything that must exist before these tests can run.>

Every behavior in Success Criteria must map to at least one test ID below, and every invariant (INV-<n>) must be verified by at least one test. Every phase in the Implementation Plan must cite the test IDs that verify it.

## Test Definitions
Enumerated, reviewable test cases. Assign each a stable `T-<n>` ID and group by level. These are the concrete cases the tests will implement — approving this plan approves these behaviors.

### Unit

**T-1 — <short name>**
- **Level:** unit
- **Preconditions:** <state/fixtures required, or "none">
- **Given** <initial context>
- **When** <action / input>
- **Then** <expected observable result>

**T-2 — <short name>**
- **Level:** unit
- **Preconditions:** <...>
- **Given** <...>
- **When** <...>
- **Then** <...>

### Integration

**T-3 — <short name>**
- **Level:** integration
- **Preconditions:** <...>
- **Given** <...>
- **When** <...>
- **Then** <...>

### End-to-end / Manual

**T-4 — <short name>**
- **Level:** e2e | manual
- **Preconditions:** <...>
- **Given** <...>
- **When** <...>
- **Then** <...>

_(Include only the levels that apply. Cover the happy path, the key edge cases surfaced in Clarifying Questions, the failure modes from Risks & Mitigations, and a test that tries to violate each Invariant (INV-<n>) — don't just test the happy path.)_

## Coverage
Traceability rollup so nothing planned goes unverified. Every invariant, success criterion, measurable NFR, and phase must appear here with the test IDs that cover it. Any row with no test is a gap to close before this plan is presented.

- **INV-1** → <T-ids>
- **Success: <criterion>** → <T-ids>
- **NFR: <measurable target>** → <T-ids, or "judgment — not automatable">
- **Phase 1** → <T-ids>

## Rollout / Migration
How this ships safely — feature flags, backfills, deprecation steps, rollback plan if needed. Write "N/A — greenfield" if there's nothing to migrate.

## Out of Scope
Deferred, not declined — what a later change could reasonably add that this one does not,
including any Opportunity the user turned down at Gate 1. Something the feature will *never* do
belongs in **Non-Goals** instead. The test: would revisiting it be a change of mind, or just the
next piece of work?

## Open Questions
Any unresolved questions to revisit later.

## Amendments
_(Omit until the plan is first amended. Add it then, and keep it directly above `## Status`.)_

### Amendment <n> — <YYYY-MM-DD> — <what changed, in a phrase>
<Why the plan was wrong, what replaces it, and what that costs. Then, explicitly:>

**Supersedes <section / INV-\<n\> / T-\<n\>>.** <What the old text claimed and why it no longer holds.>
**Adds T-\<n\> / INV-\<n\>.** <Any new test or invariant this requires. Add it to Test Definitions
and to `## Coverage` as well, or the rollup is stale from here on.>
**Supersedes baseline:** plan <old-short-sha>. <The new sha goes in `## Status` and nowhere
else — see Step 5.>

## Status
`Drafted` — set at Gate 2 to `Accepted — not yet implemented (<YYYY-MM-DD>, plan <short-sha>)`,
and to `Implemented (<YYYY-MM-DD>)` when Step 5 finishes. An amendment re-baselines the sha
here, and only here.
One line, always last, never duplicated.
```

**Before presenting the plan, run the coverage check:**

```bash
feature_plan_check.sh /_plans/<feature-name>-plan.md
```

It reports an `INV-<n>` missing from Coverage, a `T-<n>` defined but never cited, a `T-<n>` cited but never defined, a phase with no `Verified by:` line, and a missing or duplicated heading. Close every gap it finds — add the missing test, or mark the row "judgment — not automatable" — before presenting. If the command is not found the plugin is not on `PATH`; say so once and do the same check by eye rather than skipping it.

**The script is textual, so it is the floor and not the ceiling.** It can tell you `T-4` is unreferenced; it cannot tell you the test is worth writing or that the mapping is honest. Still confirm by reading that every Success Criteria behavior and every measurable NFR has a test that would actually catch its failure. Do not present a plan with silent coverage gaps.

After writing the file, tell the user:

> "Plan written to `/_plans/<feature-name>-plan.md`. Please review it and reply **'approved'** to start implementing now, or **'accepted'** if the plan is right but you don't want implementation to start yet. Or tell me what you'd like to change."

⛔ **GATE 2 — STOP. Do not write any code. Do not begin Step 5.**

Two words open this gate, and they mean different things:

- **"approved"** — the plan is right *and* start building. Proceed to Step 5.
- **"accepted"** — the plan is right, **stop here**. Do NOT begin Step 5. The plan is final
  and something else happens before implementation: scheduling, waiting on a dependency, or
  simply another day. Confirm the plan is final, say nothing about what should happen next,
  and stop.

  **Record it in the plan file before you stop.** Rewrite the existing `## Status` line — the
  last section of the template, so there is one and only one — to
  `Accepted — not yet implemented (<YYYY-MM-DD>, plan <short-sha>)`. The sha is
  `git hash-object /_plans/<feature-name>-plan.md` taken *before* you write the Status line,
  and it is what makes the Gate 2 re-entry check below possible: without a recorded baseline,
  "has the plan changed" has nothing to compare against. If the repo is not a git repo, write
  `plan unversioned` and say that the check will be by eye.

  Every reason for choosing "accepted" implies the session ends, and a later session has no
  memory that the gate was ever opened. The file is the only thing that survives.

"done", "answered", "looks good" open neither.

The distinction exists because *the plan is correct* and *start building now* are separate
decisions, and conflating them means the only way to say "good plan, not yet" is to interrupt
a run that has already started writing code.

After "accepted", a later "approved" opens Step 5 without re-running Gate 2 — but **re-read the
plan file from disk first and verify it against the sha recorded in `## Status`**. Strip the
Status line, run `git hash-object` on the rest, and compare. "The plan has not changed" is an
assumption, not a fact: "accepted" exists precisely so time can pass, and the file is editable by
anyone during it. This is the read-then-write race Gate 1 already guards against, on the one gate
designed to span days.

If the shas differ, show `git diff` of the plan file, say what changed, and re-present Gate 2.
If `## Status` records no sha, say the baseline is missing and re-present Gate 2 rather than
proceeding on an unverifiable claim.
If the user requests changes, update the plan file on disk, re-present the gate message, and wait again.

---

### Step 5 — Implement & Verify

⚠️ **Only begin after the user has explicitly said "approved" in Step 4.** "accepted" does
NOT open this step — it means the plan is final but implementation waits.

Implement according to the plan and close the verification loop the plan set up — don't just write code and check boxes.

**When the final phase is green, set `## Status` to `Implemented (<YYYY-MM-DD>)`.** A plan that
ships while still reading "Accepted — not yet implemented" tells the next session the work never
started, and sends it back through the Gate 2 re-entry check for a feature already built.

**Work phase by phase, in order.** For each phase:
1. Implement the phase's tasks, checking them off as you go.
2. Write and run that phase's `Verified by:` tests (the `T-<n>` cases from Test Definitions).
3. Confirm they pass **and** that the invariants (`INV-<n>`) the phase touches still hold.
4. **Do not advance to the next phase past red tests.** If a test fails, fix it — or, if the plan itself was wrong, amend it as below rather than improvising.

**When the plan itself turns out wrong, amend it — never edit it silently.** A plan revised in
place loses the reasoning that was superseded, and it invalidates the sha in `## Status` that the
Gate 2 re-entry check compares against. So:

1. Stop and agree the change with the user. A plan is amended with their say-so, not on your
   judgement that it was wrong.
2. Edit the affected sections, then append an `### Amendment <n>` entry saying what it supersedes
   and why. Add any new `T-<n>` or `INV-<n>` to Test Definitions **and** to `## Coverage` — the
   coverage self-check ran once, at Gate 2, and an amendment is how its result goes stale.
3. Record the superseded baseline in the amendment — the sha `## Status` holds *now*, before you
   touch it. The body is then final.
4. Re-baseline: strip the `## Status` line, run `git hash-object` on the rest, and write that sha
   into `## Status`.

**The new sha goes in `## Status` and nowhere else.** The re-entry check strips only the Status
line, so the amendment body is inside the hashed region: write the new sha there and the hash no
longer describes the file it was taken from, and the next comparison fails on a plan nobody
touched. Hence the order above — the amendment records the baseline it *replaced*, which is known
before the hash is taken.

Skip the re-baseline entirely and the next session's re-entry check reports a plan that changed
behind its back, and re-presents Gate 2 for work already under way.

**After the final phase:**
- Run the **full test suite** and confirm every `T-<n>` and every `INV-<n>` in the plan is covered and green.
- If any planned test was not implemented or is failing, say so explicitly — do not report the feature as done.

**Then hand off for validation** — summarize what was built, the files changed, the tests run and their results, and anything deferred or still open. Leave commit/push to the user's normal workflow; do not commit unless asked.

## Rules

- **Right-size the plan.** The templates are the maximum shape. Keep every heading, but scale each section's depth to the feature — a trivial change gets terse or `None — <reason>` sections, not fabricated ceremony. See "Right-sizing the plan".
- **Either input works**, but a requirements file on disk is the source of truth from Step 2 onward. If the user gave a prose description, write it to `/_reqs/<slug>.md` in Step 1 before doing anything else.
- **Analysis and questions go in the file. Always. No exceptions.** Never discuss approach or ask questions in chat.
- **Keep the file current while Gate 1 is open.** Answers arrive in chat; a concern an answer
  settled still sitting under **Open** is a stale file, and the plan gets written against it.
  Move it to **Addressed** with what settled it. None of that opens the gate.
- **Be opinionated in the Approach Analysis.** "It depends" is not a recommendation. Pick one and defend it.
- **Poke holes in the requirements and surface missed opportunities.** The analysis must critique the reqs *as written* (gaps, ambiguities, unstated assumptions, contradictions) and flag opportunities the user didn't ask for — not just evaluate the proposed approach. If there are genuinely none, say so explicitly. Opportunities are flagged, not assumed into scope; the user decides at Gate 1.
- **Surface alternatives even when you agree** with the proposed approach — explain why they lose.
- There are two separate gates — Gate 1 ("answered") and Gate 2 ("approved" or "accepted") — they are not interchangeable.
- **Gate 2 has two exits.** "approved" means start building; "accepted" means the plan is final but do not start. Never treat "accepted" as permission to write code.
- **`## Status` is a single line in the plan file that every gate maintains** — `Drafted` at
  write time, `Accepted — not yet implemented` with a date and a plan sha at Gate 2, `Implemented`
  when Step 5 finishes. The state has to survive the session, the sha is what makes "has this
  changed" answerable, and a stale Status is worse than none because it is believed.
- **A plan that turns out wrong is amended, not edited.** Append an `### Amendment <n>` saying
  what it supersedes and why, add any new `T-<n>` or `INV-<n>` to Test Definitions and
  `## Coverage`, and re-baseline the sha in `## Status`. Editing in place loses the superseded
  reasoning and silently breaks the Gate 2 re-entry check, which is the one guard designed to
  span days.
- "done" does not open either gate.
- Re-reading the file after answers is mandatory — do not rely on memory of the blank questions, and watch for user edits to the analysis.
- Writing the plan to disk is mandatory — chat output does not count.
- **The plan must define invariants with stable `INV-<n>` IDs** — properties that must always hold, distinct from success criteria and risks. Surface unstated invariants the reqs only imply, and verify each with a test.
- **Every implementation task carries a stable `P<phase>.<task>` ID**, for the same reason
  tests carry `T-<n>`: prose gets reworded, identifiers do not. Anything that needs to refer
  to a specific task — a commit message, a review comment, a progress note — can then do so
  unambiguously. Number within the phase (`P1.1`, `P1.2`, `P2.1`), so appending a task to one
  phase never renumbers another.
- **The plan must include enumerated test definitions with stable `T-<n>` IDs**, not a prose "we'll write tests" narrative. Every Success Criteria behavior and every invariant maps to at least one test ID, and every implementation phase cites the test IDs that verify it. Cover edge cases and failure modes, not just the happy path.
- **Run the coverage self-check before presenting the plan.** The `## Coverage` rollup must show every invariant, success criterion, measurable NFR, and phase mapped to a test — no silent gaps. Close or explicitly mark any uncovered row before Gate 2.
- Never write any code before hearing "approved" for the plan.
- **Implementation must run the plan's tests, not just write code.** Work phase by phase, run each phase's `T-<n>` tests before advancing, never move past red tests, and confirm every `T-<n>` and `INV-<n>` is green before reporting the feature done. A feature with unrun or failing planned tests is not done — say so.
- Always derive the plan filename from the requirements filename.