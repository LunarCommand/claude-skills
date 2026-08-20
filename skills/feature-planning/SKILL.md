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
- <concern> — why it matters
- <concern> — why it matters

### Gaps & holes in the requirements
Poke holes in the requirements *as written* — this is about defects in the spec, not risks in the approach. Look for:
- <ambiguity or under-specified behavior> — what's unclear and why it will bite
- <unstated assumption the reqs depend on> — what happens if it's false
- <missing edge case / failure mode not addressed>
- <internal contradiction or requirement that conflicts with another>
- <unstated invariant the reqs assume but never declare — a property that must always hold for the feature to be correct>

### Opportunities worth considering
Things the user did NOT ask for but should see — adjacent wins, low-cost additions, things that would make the feature notably better. Flag them; do not assume them into scope (the user decides at Gate 1).
- **<Opportunity>** — <what it is>. Value: <low/med/high>. Cost: <low/med/high>.
- **<Opportunity>** — <what it is>. Value: <low/med/high>. Cost: <low/med/high>.

### Alternative approaches worth considering
- **<Alternative name>** — <one-line description>. Trade-off: <what you gain / lose vs. the proposed approach>.
- **<Alternative name>** — <one-line description>. Trade-off: <what you gain / lose vs. the proposed approach>.

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

---

### Step 3 — Re-read the File and Verify

Re-read `$REQUIREMENTS_FILE` in full. Check that:
- Every `A:` line has been filled in
- Any edits the user made to the Approach Analysis section — these are direction changes you must respect when writing the plan

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
- <what this feature explicitly will NOT do, even though it might seem related>

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
What explicitly will NOT be addressed in this implementation.

## Open Questions
Any unresolved questions to revisit later.
```

**Before presenting the plan, run a coverage self-check.** Confirm that every invariant (`INV-<n>`), every Success Criteria behavior, and every measurable NFR has at least one mapped test in the `## Coverage` section, and that every implementation phase cites its `Verified by:` tests. If anything is uncovered, close the gap — add the missing test or explicitly mark it "judgment — not automatable" — before presenting. Do not present a plan with silent coverage gaps.

After writing the file, tell the user:

> "Plan written to `/_plans/<feature-name>-plan.md`. Please review it and reply **'approved'** to start implementing now, or **'accepted'** if the plan is right but you don't want implementation to start yet. Or tell me what you'd like to change."

⛔ **GATE 2 — STOP. Do not write any code. Do not begin Step 5.**

Two words open this gate, and they mean different things:

- **"approved"** — the plan is right *and* start building. Proceed to Step 5.
- **"accepted"** — the plan is right, **stop here**. Do NOT begin Step 5. The plan is final
  and something else happens before implementation: scheduling, waiting on a dependency, or
  simply another day. Confirm the plan is final, say nothing about what should happen next,
  and stop.

  **Record it in the plan file before you stop.** Add a `## Status` section reading
  `Accepted — not yet implemented` with the date. Every reason for choosing "accepted" implies
  the session ends, and a later session has no memory that the gate was ever opened. The file
  is the only thing that survives, so if the state is not written there it does not exist.

"done", "answered", "looks good" open neither.

The distinction exists because *the plan is correct* and *start building now* are separate
decisions, and conflating them means the only way to say "good plan, not yet" is to interrupt
a run that has already started writing code.

After "accepted", a later "approved" opens Step 5 without re-running Gate 2 — but **re-read the
plan file from disk first** and confirm it still matches what was accepted. "The plan has not
changed" is an assumption, not a fact: "accepted" exists precisely so that time can pass, and the
file is editable by anyone during it. This is the same read-then-write race Gate 1 already guards
against, on the one gate designed to span days. If the file has changed since it was accepted, say
what changed and re-present Gate 2.
If the user requests changes, update the plan file on disk, re-present the gate message, and wait again.

---

### Step 5 — Implement & Verify

⚠️ **Only begin after the user has explicitly said "approved" in Step 4.** "accepted" does
NOT open this step — it means the plan is final but implementation waits.

Implement according to the plan and close the verification loop the plan set up — don't just write code and check boxes.

**Work phase by phase, in order.** For each phase:
1. Implement the phase's tasks, checking them off as you go.
2. Write and run that phase's `Verified by:` tests (the `T-<n>` cases from Test Definitions).
3. Confirm they pass **and** that the invariants (`INV-<n>`) the phase touches still hold.
4. **Do not advance to the next phase past red tests.** If a test fails, fix it (or, if the plan itself was wrong, stop and revise the plan with the user rather than improvising).

**After the final phase:**
- Run the **full test suite** and confirm every `T-<n>` and every `INV-<n>` in the plan is covered and green.
- If any planned test was not implemented or is failing, say so explicitly — do not report the feature as done.

**Then hand off for validation** — summarize what was built, the files changed, the tests run and their results, and anything deferred or still open. Leave commit/push to the user's normal workflow; do not commit unless asked.

## Rules

- **Right-size the plan.** The templates are the maximum shape. Keep every heading, but scale each section's depth to the feature — a trivial change gets terse or `None — <reason>` sections, not fabricated ceremony. See "Right-sizing the plan".
- **Either input works**, but a requirements file on disk is the source of truth from Step 2 onward. If the user gave a prose description, write it to `/_reqs/<slug>.md` in Step 1 before doing anything else.
- **Analysis and questions go in the file. Always. No exceptions.** Never discuss approach or ask questions in chat.
- **Be opinionated in the Approach Analysis.** "It depends" is not a recommendation. Pick one and defend it.
- **Poke holes in the requirements and surface missed opportunities.** The analysis must critique the reqs *as written* (gaps, ambiguities, unstated assumptions, contradictions) and flag opportunities the user didn't ask for — not just evaluate the proposed approach. If there are genuinely none, say so explicitly. Opportunities are flagged, not assumed into scope; the user decides at Gate 1.
- **Surface alternatives even when you agree** with the proposed approach — explain why they lose.
- There are two separate gates — Gate 1 ("answered") and Gate 2 ("approved" or "accepted") — they are not interchangeable.
- **Gate 2 has two exits.** "approved" means start building; "accepted" means the plan is final but do not start. Never treat "accepted" as permission to write code.
- **"accepted" is written to the plan file, not just remembered**, and a later "approved" re-reads the file before Step 5 — the state has to survive the session, and the plan may have been edited while it waited.
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