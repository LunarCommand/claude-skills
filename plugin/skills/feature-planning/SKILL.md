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
- Work the approach out in chat instead of in the file
- Raise a concern, alternative or question you have not written down first
- Put the questions to the user as prose in chat. Answers are collected by the user
  editing the file, or through Step 2a's walkthrough, and nowhere else
- Skip the analysis because the requirements seem solid
- Skip the questions because the requirements seem clear enough

✅ The ONLY correct action is to open `$REQUIREMENTS_FILE` and append BOTH sections below to the bottom of it using your file write tools, then tell the user where to find them.

Step 2a offers to walk the written items one at a time, and it is not an exception
to any of the above. It puts items already on disk in front of the user and writes
their answers back; the analysis itself is written first, always.

Note: when the requirements file was generated from a `$DESCRIPTION`, expect more gaps than usual — lean harder on Clarifying Questions to surface what the prose didn't cover.

The sections MUST use this exact format:

```markdown
## Approach Analysis

### What's strong about this approach
- <point>
- <point>

### Concerns & risks

**Open**
- **C-1** <concern> — why it matters. **Reco:** <what you would do about it>
- **C-2** <concern> — why it matters. **Reco:** <...>
  **Answered:** <what the user said, when it did not settle the concern. Present only
  on an item that has been put to them and is still open.>

**Addressed**
<Empty when first written. A concern moves here when an answer or a decision settles
it, keeping the ID it was given:>
- **C-3** <concern> — settled by <the question it answered, or the Direction entry>

### Gaps & holes in the requirements
Poke holes in the requirements *as written* — this is about defects in the spec, not risks in the approach. Look for:

**Open**
- **G-1** <ambiguity or under-specified behavior> — what's unclear and why it will bite. **Reco:** <...>
- **G-2** <unstated assumption the reqs depend on> — what happens if it's false. **Reco:** <...>
- **G-3** <missing edge case / failure mode not addressed>. **Reco:** <...>
- **G-4** <internal contradiction or requirement that conflicts with another>. **Reco:** <...>
- **G-5** <unstated invariant the reqs assume but never declare — a property that must always hold for the feature to be correct>. **Reco:** <...>

**Addressed**
<as above, keeping the ID — what settled it, not just that it is settled>

### Opportunities worth considering
Things the user did NOT ask for but should see — adjacent wins, low-cost additions, things that would make the feature notably better. Flag them; do not assume them into scope (the user decides at Gate 1).
- **OPP-1 <Opportunity>** — <what it is>. Value: <low/med/high>. Cost: <low/med/high>. **Reco:** <take it / skip it> — <why>.
- **OPP-2 <Opportunity>** — <what it is>. Value: <low/med/high>. Cost: <low/med/high>. **Reco:** <...>
  **Answered:** <what the user decided. Present only on an item that has been put to
  them — there is no **Addressed** section here, so this line is the whole record.>

### Alternative approaches worth considering
These are one decision rather than several — `### My recommendation` picks among
them, so they carry no per-item **Reco:**.
- **ALT-1 <Alternative name>** — <one-line description>. Trade-off: <what you gain / lose vs. the proposed approach>.
- **ALT-2 <Alternative name>** — <one-line description>. Trade-off: <what you gain / lose vs. the proposed approach>.

### Direction taken at Gate 1
<Decisions the user made in chat that answer no single question. Empty until there is one.>
- **D-1** <ISO date> — <the decision, in the user's terms> — <what it changes>

### My recommendation
<One paragraph. Be opinionated — pick one approach and defend it. If the proposed approach is the right one, say so and explain why the alternatives lose. If a different approach is better, say so directly.>

## Clarifying Questions

**Q-1: <question>**
Reco: <your proposed answer, or `Your call — <what only the user can decide>`>
A: 

**Q-2: <question>**
Reco: <...>
A: 
```

**Every item the table below gives an ID carries one**, numbered within its own kind
so appending a gap never renumbers a question, and kept when the item moves. They
exist for the same reason `T-<n>` and `P<phase>.<task>` do: chat and the file have
to be able to name the same item, and prose gets reworded. An item added later takes
the next free number rather than reusing a retired one.

**The kinds are not uniform.** What each carries, and where an answer to it is
recorded:

| Kind | ID | `Reco:` | Open / Addressed | Where an answer is recorded |
| --- | --- | --- | --- | --- |
| What's strong about this approach | none | no | no | nothing to answer |
| Concerns & risks | `C-<n>` | yes | yes | **Addressed** once settled, `Answered:` on the item until then |
| Gaps & holes | `G-<n>` | yes | yes | as above |
| Opportunities | `OPP-<n>` | yes | no | `Answered:` on the item |
| Alternative approaches | `ALT-<n>` | no — `### My recommendation` decides them together | no | `### Direction taken at Gate 1` |
| Clarifying Questions | `Q-<n>` | yes | no | the `A:` line |
| Direction taken at Gate 1 | `D-<n>` | no | no | it is itself the record |

**Where the table says `Reco:`, every item has one, or says why it cannot** — write
`Your call — <what only they can decide>` rather than inventing a recommendation. This
is what makes a thirty-item file tractable: without it the user is answering alone;
with it they are agreeing or disagreeing. An invented recommendation reads exactly like
a real one, and it does the most damage on the items you understand least.

**Record an answer even when it does not settle the item.** "I'll think about C-4" is
an answer. Without it a concern the user has already discussed is byte-identical to one
never put to them, and a resumed walkthrough asks it a second time.

The Approach Analysis is **required** even when you fully agree with the proposed approach — in that case, your job is to explain *why* the alternatives lose so the user can sanity-check your reasoning. Rubber-stamping isn't analysis.

If you genuinely have no alternatives worth raising and zero concerns, write a brief version — but you must still poke holes in the requirements and note opportunities (or explicitly state there are none):

```markdown
## Approach Analysis

The proposed approach is the right one. I considered <alternative 1> and <alternative 2> but rejected them because <reason>. No material concerns.

### Gaps & holes in the requirements

**Open**
- **G-1** <gap> — why it will bite. **Reco:** <...>

<or "None — requirements are complete and unambiguous." in place of the list>

**Addressed**
None open.

### Opportunities worth considering
- **OPP-1 <Opportunity>** — <what it is>. Value: <...>. Cost: <...>. **Reco:** <...>

<or "None worth flagging.">
```

The brief form is shorter, not differently shaped: the IDs, the `Reco:` lines and the
**Open** / **Addressed** split are the same as the full template.

Leave every `A:` line blank when the section is first written. They are filled in as
answers arrive — by the user editing the file, or by you recording what they said in the
walkthrough. The user may also edit the Approach Analysis section to push back, agree, or
redirect — those edits are direction changes you must respect.

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

After writing to the file, tell the user. Make the walkthrough offer only when Step
2a's conditions are met — `AskUserQuestion` available, and enough items to be worth
batching:

> "I've added my approach analysis and clarifying questions to `$REQUIREMENTS_FILE` —
> <n> items in all. Want me to walk you through them one at a time with a
> recommendation for each, or would you rather answer in the file yourself — `A:`
> lines for the questions, a note on any other item? Either way, push back on or
> accept the analysis and reply **'answered'** when you're done."

When those conditions are not met, send the same message without the offer, asking
them to answer in the file and reply **'answered'**.

---

### Step 2a — Offer to walk the items

A requirements file routinely carries thirty or more items to settle, and answering
them one at a time in the file is slow. Offer to walk them instead. **Offer once**,
in the message above, and take no for an answer — the file route is unchanged and
equally correct, and a user who declines is not asked again.

**Offer only when there is enough to batch.** Skip it on the brief form and whenever
the analysis settles out at a handful of items: two questions are answered faster in
the file than in a dialog, and "0 items in all — want me to walk you through them?" is
the shape to avoid. `<n>` in the message is the number of questions the walkthrough
would actually ask — the concerns, gaps, opportunities and clarifying questions that
have a real choice set, plus one for the alternatives — not the number of lines in the
file.

The walkthrough changes **how answers are collected, not where they live.** Every answer
is written into `$REQUIREMENTS_FILE` as it is given, by the rules in *While Gate 1 is
open* below. An answer that exists only in the chat transcript has not been recorded.

**Run it with the `AskUserQuestion` tool**, not as prose questions in chat:

- **Up to four items per call**, grouped by kind. The schema is hard on both counts:
  1–4 questions per call, 2–4 options each.
- **Header** — the item's kind: `Concerns`, `Gaps`, `Opportunity`, `Approach`,
  `Questions`. The chip is capped at 12 characters, which is why it is `Opportunity`
  and not `Opportunities`.
- **Question text** — the position, then the item: `Gap 9 of 9: the requirements rely
  on rules they never state. Should these become Phase 2's invariants, each proven by a
  test? (1) … (2) …`. The position is progress; the ID in the file is identity.
- **Options** — concrete and mutually exclusive, the `Reco:` first and labelled
  `(Recommended)`. Each option's description says **what that answer does to the plan**,
  not what the label already said: *"Each becomes an INV in the Phase 2 plan with a test
  that tries to break it"* is a description, *"treat them as invariants"* is a
  restatement.
- **An item you cannot call is asked only if it still has two or more real choices.**
  Then put the one needing the user's knowledge first and mark nothing `(Recommended)`.
- **An item whose honest answer space is not two to four mutually exclusive choices is
  not walked.** There is no one-option form, so inventing a second choice to satisfy the
  schema is exactly how a `Your call —` item acquires a recommendation nobody made.
  Leave it in the file with its `Your call —` line intact, and name it at the end among
  what is still open.
- **Do not build escape hatches.** The harness always adds a free-text choice of its
  own, so do not write an "Other", "Skip" or "none of these" option.

**The alternatives are one question, not several.** `ALT-1`…`ALT-n` are mutually
exclusive by construction, so ask once under the `Approach` header with the proposed
approach and each alternative as options, the one `### My recommendation` names marked
`(Recommended)`. The proposed approach takes one of the four slots, so more than three
alternatives will not fit: name the three that are live and say in the question text
that the rest are in the file. Skip this question entirely when there are no
alternatives.

**Write each batch's answers to the file before asking the next** — not at the end. A
walkthrough that writes once at the end loses every answer if the session drops, and
writing as you go makes the file the record of where you got to: a resumed session
starts at the first item with no recorded answer. The table above says where each
kind's answer lives, and an answer is recorded even when it settles nothing — that is
what makes an item already put to the user distinguishable from one never reached.

**The user can stop at any point.** Items not reached keep their `Reco:` and carry no
recorded answer, and the file route still works for them.

**The walkthrough does not open Gate 1.** Settling every item means the file is
complete, not that the user has read it. Say the file is updated, say what is still open
if anything, and wait for **"answered"**.

**If `AskUserQuestion` is unavailable**, say so once and fall back to the file route. Do
not simulate it with numbered prose questions in chat: the structure is what keeps each
answer attached to an item, and prose question-and-answer drifts into a conversation
nobody can map back to the file.

---

⛔ **GATE 1 — STOP. Do not continue until the user replies with "answered".**
"done", "ready", "continue" do NOT open this gate. Only "answered" does.

#### While Gate 1 is open

**Gate 1 is usually a conversation, and the file has to keep up with it.** Answers arrive in
chat at least as often as in the file, each one opens new ground, and an analysis left as first
written ends up with half its concerns settled while still reading as live. Step 2a's
walkthrough is the structured form of this, and the rules below govern it and any answer
that arrives loose in chat alike. Whenever the user answers or decides something:

- Fill the `A:` line it answers, in the user's words.
- Move each concern or gap it settles under **Addressed**, naming what settled it. Keep
  **Open** first in both sections, and write `None open.` when nothing is left, so the file
  reads top-down and can be put down at the first Addressed item.
- Write `Answered:` on a concern, gap or opportunity the answer did not settle, in the
  user's words. An item discussed and left open must not read like one never raised —
  that is what a resumed walkthrough reads to find where it got to.
- Record under `### Direction taken at Gate 1` any decision that answers no single question.
- Append a question the answer raised to Clarifying Questions, with the next free
  `Q-<n>`, a `Reco:`, and a blank `A:`.
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
- Every item settled in the walkthrough is recorded **in the file**. An answer that
  exists only in the chat transcript is not recorded, and the plan gets written without it

If any `A:` lines are still blank, list the unanswered questions and wait for the
user to complete them. Do not proceed until all are answered. A concern or gap the
user chose to leave open is not a blocker — the plan is written against what is
genuinely still open. An answer they gave that the file does not record is one, so
write it down rather than asking for it a second time.

---

### Step 4 — Write the Final Plan to Disk

⚠️ **The plan MUST be written to disk. Outputting the plan in chat is NOT sufficient.**

Write the plan to:
**`/_plans/<feature-name>-plan.md`**
(e.g. `/_reqs/csv-export.md` → `/_plans/csv-export-plan.md`)

If `/_plans/` does not exist, create it first.

The plan file MUST include the following sections (this is the maximum shape — apply **Right-sizing the plan** to scale each section's depth to the feature; keep every heading):

The template marks who each line is for, and the three markers are the whole rule:

- **`_(italic parenthetical)_`** — an instruction to you. Never copy it into the plan.
- **`<angle brackets>`** — a placeholder. Replace it with the real content.
- **Anything else** — the plan's own prose. Keep it as it stands.

A line with no marker is text the plan's reader is meant to see, so an instruction that
arrives unmarked will end up in the delivered file.

```markdown
# Plan: <Feature Name>

## Summary
<One-paragraph overview of what will be built and why.>

## Requirements Reference
/_reqs/<requirements-file>.md

## Goals & Non-Goals

### Goals
- <what this feature must achieve>

### Non-Goals
- <what this feature will never do, by decision — "not this feature", not "not yet">

## Invariants
Properties that must hold true at ALL times, across every state and input — the design contract.

_(An invariant is a standing safety property — "X is always true" — NOT a one-time outcome such as "we achieved X", which is Success Criteria, and NOT a risk. If it can ever be false without the feature being broken, it isn't an invariant.)_

- **INV-1:** <the property that must always hold> — <why it matters / what breaks if violated>
- **INV-2:** <...>

_(Include invariants the requirements imply but never state — surfaced in Step 2's Gaps & holes. Each invariant must be verified by at least one test in Test Definitions.)_

## Non-Functional Requirements
Measurable quality constraints the feature must meet — distinct from functional behavior, which is what it does, and invariants, which must always hold.

_(State a target, not a vibe. Where a target is measurable, map it to a `T-<n>`; where it can only be checked by judgment, say so.)_

- **Performance** — <target, e.g. "p95 request latency < 200ms at 100 rps", or "None — not on a hot path">
- **Security** — <authz/authn, input validation, secrets handling, data exposure constraints, or "None beyond existing system guarantees">
- **Scalability** — <expected load / growth the design must absorb, or "None — bounded single-user operation">
- **Reliability** — <availability, retries, idempotency, failure-handling expectations, or "None specified">

_(Add or drop categories as the feature warrants; a light feature may reduce this whole section to `None — <reason>`.)_

## Success Criteria
How we know this is done and working. Measurable where possible.

_(These are the target the Test Plan, Test Definitions, and Coverage below map back to — so define them before the test sections reference them.)_

## Strategy

### Chosen approach
_(Describe the approach in 2–4 sentences. This should reflect the conclusion from the Approach Analysis after any user feedback.)_

### Why this approach
_(Explain why this beats the alternatives considered. Reference the trade-offs.)_

### Alternatives rejected
- **<Alternative>** — rejected because <reason>.
- **<Alternative>** — rejected because <reason>.

## Clarifications & Decisions
- <question> → <the answer or decision made>
- <approach feedback from the user> → <how the plan reflects it>

## Risks & Mitigations
- **<Risk>** — likelihood: <low/med/high>. Mitigation: <plan>.
- **<Risk>** — likelihood: <low/med/high>. Mitigation: <plan>.

## Implementation Plan

### Phase 1: <n>
- [ ] **P1.1** <task>
- [ ] **P1.2** <task>

**Verified by:** T-1, T-2 _(the test IDs from Test Definitions that prove this phase is done)_

### Phase 2: <n>
- [ ] **P2.1** <task>

**Verified by:** T-3

## Files to Create / Modify
- `<path/to/file>` — <purpose>

## Test Plan
How this feature will be verified, across levels. _(Be specific.)_

- **Unit** — <what units get covered; which modules/functions; tooling/framework>
- **Integration** — <what boundaries/interactions get covered; which real vs. mocked dependencies>
- **End-to-end** — <what user-facing flows get exercised, if any; N/A if not applicable>
- **Manual / QA** — <what a human must check that automation won't; staging steps, if any>

**Execution notes:** <how/when tests run — CI, pre-commit, local only; ordering or data-setup concerns; anything that must exist before these tests can run.>

_(Every behavior in Success Criteria must map to at least one test ID below, and every invariant `INV-<n>` must be verified by at least one test. Every phase in the Implementation Plan must cite the test IDs that verify it.)_

## Test Definitions
Enumerated, reviewable test cases. These are the concrete cases the tests will implement — approving this plan approves these behaviors.

_(Assign each a stable `T-<n>` ID and group by level.)_

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
- **Level:** <e2e / manual>
- **Preconditions:** <...>
- **Given** <...>
- **When** <...>
- **Then** <...>

_(Include only the levels that apply. Cover the happy path, the key edge cases surfaced in Clarifying Questions, the failure modes from Risks & Mitigations, and a test that tries to violate each Invariant (INV-<n>) — don't just test the happy path.)_

## Coverage
Traceability rollup so nothing planned goes unverified.

_(Every invariant, success criterion, measurable NFR, and phase must appear here with the test IDs that cover it. Any row with no test is a gap to close before this plan is presented.)_

- **INV-1** → <T-ids>
- **Success: <criterion>** → <T-ids>
- **NFR: <measurable target>** → <T-ids, or "judgment — not automatable">
- **Phase 1** → <T-ids>

## Rollout / Migration
How this ships safely — feature flags, backfills, deprecation steps, rollback plan if needed.

_(Write "N/A — greenfield" if there's nothing to migrate.)_

## Out of Scope
Deferred, not declined — what a later change could reasonably add that this one does not.

_(Include any Opportunity the user turned down at Gate 1. Something the feature will *never* do
belongs in **Non-Goals** instead — the test being whether revisiting it would be a change of
mind, or just the next piece of work.)_

## Open Questions
<Any unresolved questions to revisit later, or "None." >

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
`Drafted`

_(One line, always last, never duplicated. At Gate 2 it becomes `Accepted — not yet implemented
(<YYYY-MM-DD>, plan <short-sha>)`, and `Implemented (<YYYY-MM-DD>)` when Step 5 finishes. An
amendment re-baselines the sha here, and only here.)_
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
- **Analysis and questions go in the file. Always. No exceptions.** Never work the
  approach out in chat, and never raise an item you have not written down first. Step
  2a's walkthrough asks about items already in the file and writes the answers back,
  which is not the same as thinking in chat.
- **Offer the walkthrough once, and take no for an answer.** It is how answers are
  collected, never where the analysis is made, and every answer it collects goes into the
  file as it is given. See Step 2a.
- **Every item the table gives an ID carries one** — `C-<n>`, `G-<n>`, `OPP-<n>`,
  `ALT-<n>`, `Q-<n>`, `D-<n>`, numbered within their own kind and kept when the item
  moves. Same reason as `T-<n>` and `P<phase>.<task>`: chat and the file must be able
  to name the same item. The kinds are not uniform — the table in Step 2 says which
  carry an ID, which carry a `Reco:`, which have an **Open** / **Addressed** split,
  and where an answer to each is recorded.
- **Every item the table marks `Reco:` carries one, or says why it cannot.** `Your call
  — <what only they can decide>` is a complete answer; an invented recommendation is
  not, and it does the most damage on the items you understand least. Alternatives are
  the exception by design: `### My recommendation` decides them together.
- **Write each walkthrough batch's answers to the file before asking the next**, and
  record an answer even when it settles nothing. This is the one walkthrough rule whose
  breach loses the user's answers outright.
- **The walkthrough does not open Gate 1.** Only "answered" does, however many items it
  settled.
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