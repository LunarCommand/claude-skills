# The multi-lens adversarial review workflow

A method for getting senior-level review out of AI — the kind that catches
whole-system, failure-mode, and consistency defects, not just style nits.

It exists because the defects that matter most are the ones a diff-scoped
autoreview bot **structurally cannot** find (see
[human-vs-copilot-findings.md](human-vs-copilot-findings.md)). Those defects
share a shape, and the method is built around that shape.

## The core reframe

Three shifts turn a low-signal reviewer into a high-signal one. None of them
requires a better model — they change the _harness_, not the intelligence.

| Default (low-signal)         | This method (high-signal)                                                                            |
| ---------------------------- | ---------------------------------------------------------------------------------------------------- |
| "Review this line / hunk"    | "**Try to break this.** What input, state, or failure makes it wrong?"                               |
| Sees the diff only           | Sees the **changed files plus their collaborators** (callers, config, the invariants they depend on) |
| One pass, describes the code | **Several passes**, each with a specialized adversarial mandate, then a verify pass                  |

The reframe is the whole game. "Review this" produces descriptions of what the
code does. "Try to break this" produces the failure the author didn't consider.

## The four levers (in order of payoff)

1. **Adversarial framing.** Ask what breaks it, not whether it looks right.
   Biggest lever, zero cost.
2. **Whole-system context.** Give the reviewer the changed files _and_ their
   callers and the config they depend on. Some defects are only visible when an
   unchanged file is in view (e.g. an engine's isolation setting deciding whether
   a rollback in another file even works).
3. **Written-down invariants.** Feed the reviewer the system's non-negotiables
   (see your project's invariants doc, e.g. a `CLAUDE.md` "Operational
   Invariants" section). This turns generic review into _invariant-checking_ —
   the reviewer flags "this violates the logging-never-dark rule" instead of
   missing it.
4. **Multiple lenses + a verify pass.** Run specialized passes; then refute each
   finding before surfacing it.

## The lenses

Run each as a **separate pass** with its own mandate. A single "review
everything" prompt averages out; specialized passes go deep. Each lens below
lists the question it asks.

### 1. Concurrency & lifecycle

> For every `await`, thread, background task, and external call: what exceptions
> or abandonment paths exist, and does cleanup/cancellation run on **all** of
> them? What happens if this is killed mid-flight, or runs twice concurrently?

### 2. Failure-mode & observability

> What happens when each external dependency is **slow**, **down**, or returns
> **garbage**? Are those cases distinguished when they should be? On failure, can
> the system lose its ability to tell you it failed (logs, metrics, alerts)?

### 3. Data consistency & transactions

> Under this system's isolation model, what is actually atomic? If a
> multi-step write fails partway, what state is left? Is a rollback here
> operative or a no-op? Can a read-then-write race with a concurrent actor?

### 4. The "what's missing" critic

> What does this change **not** handle that it should? What case is untested,
> what claim in a docstring or comment is unverified, what invariant is silently
> assumed? Name the absent thing, not the present one.

> Extend the lens set to fit the change. A security-sensitive PR wants an
> auth/input-trust lens; a hot path wants a resource/allocation lens. The four
> above are the floor, not the ceiling.

## The verify / refute pass

After the lenses produce findings, run one more pass that tries to **refute**
each one:

> For each finding: construct the concrete input/state that triggers it. If you
> can't, or if the "fix" wouldn't actually work, mark it refuted.

This is what stops confidently-wrong findings from reaching the author — the AI
equivalent of the mistake even good human reviewers make (a confident, wrong
claim on a specific technical point; a refute pass catches exactly that). It is
also where AI can **exceed** an unassisted human on precision, even where it
trails on insight.

Prefer perspective-diverse refutation over N identical skeptics: have one
verifier check "does it reproduce," another "would the fix regress anything,"
another "is the claim even true." For high-stakes findings, require a majority to
survive.

## Severity rubric

Counters the AI failure mode of flagging everything at one volume. Every surfaced
finding gets a level:

- **Blocker** — correctness, data loss, security, or an invariant violation. Must
  be resolved before merge.
- **Should** — a real defect or risk that is safe to defer with a tracked
  follow-up.
- **Nit** — style, naming, consistency. Label it as such so the author can batch
  or skip. Never present a nit at blocker volume.

A finding that can't be placed on this scale probably isn't a finding.

## How to run it today

Point Claude Code (or an equivalent agent that can read whole files and grep for
callers) at the branch, and drive the passes explicitly. The
[checklist](adversarial-review-checklist.md) is the promptable form. The essential
moves:

1. Assemble context: the diff, the changed files in full, their callers/config,
   and the invariants doc.
2. Run each lens as its own adversarial pass.
3. Run the refute pass; drop what doesn't survive.
4. Rank surviving findings by severity; report most-severe first.

## Making it runnable (optional, not yet built)

The method maps cleanly onto a multi-agent workflow: fan out the lenses in
parallel, pipe each lens's findings into a refute stage, dedupe, rank, and
surface only survivors. That would make it a one-command review rather than a
driven conversation. Deferred until the doc's home is settled; noted here so the
path is on record.

## Limits — what this does not buy you

- **Judgment about whether a real issue is worth doing now.** The method finds
  issues; a human decides what to defer. Pair it with the severity rubric, but
  the final "not this PR" call stays human.
- **Undocumented domain knowledge.** The reviewer checks against invariants you
  _give_ it. A business rule that lives only in someone's head won't be found —
  which is itself an argument for writing invariants down.
- **Taste.** Which nits to suppress entirely is still a human call.
