# Adversarial code-review checklist (project-agnostic)

A portable checklist for getting high-signal review out of a capable AI (or a
human). Copy it into any project. Nothing below is specific to this repo — the
worked examples that motivated it are in
[human-vs-copilot-findings.md](human-vs-copilot-findings.md).

Use it by **driving each section as a separate adversarial pass**, not by pasting
the whole thing into one prompt. One "review everything" pass averages out;
specialized passes go deep.

---

## 0. Before you review — assemble context

The single biggest determinant of review quality is what the reviewer can see.

- [ ] The **diff**, and the **full text of every changed file** (not just hunks).
- [ ] The changed files' **collaborators**: callers, callees, and any config or
      constants they depend on — even in unchanged files. (Defects often hide in
      the interaction between a changed file and an unchanged one.)
- [ ] The project's **invariants / non-negotiables**, written down. If they don't
      exist yet, write them first — it's the highest-leverage thing you can do,
      and it pays off on every future review and every new hire.
- [ ] The **intent**: what is this change supposed to do? Review checks code
      against intent, not just against itself.

## 1. Set the framing

For every pass, the instruction is **"try to break this,"** never "review this."

> Do not describe what the code does. Find the input, state, timing, or failure
> that makes it wrong. If you can't find one for a given concern, say so
> explicitly and move on.

## 2. Run the lenses (each a separate pass)

### Concurrency & lifecycle
- [ ] For every `await` / async boundary, thread, background task, and external
      call: enumerate every way it can fail or be abandoned (timeout, cancel,
      disconnect, shutdown, exception). Does cleanup/rollback/cancellation run on
      **all** of them?
- [ ] What happens if this runs **twice concurrently**? Killed **mid-flight**?
- [ ] Are exceptions caught at the right breadth? (Beware handlers that miss
      `BaseException`-derived cases like cancellation.)

### Failure-mode & observability
- [ ] For each external dependency: what happens when it is **slow**, **down**, or
      returns **malformed** data? Are those cases distinguished when they should
      be, or collapsed into one path?
- [ ] On failure, can the system lose its ability to **report** the failure (logs,
      metrics, traces, alerts)? Any path that can go silent?
- [ ] Are retries/backoff/queues bounded? What happens at the bound
      (drop? block? OOM?)?

### Data consistency & transactions
- [ ] Under this system's actual isolation/consistency model, what is **atomic**?
      Confirm — don't assume — that rollbacks and transactions are operative and
      not no-ops.
- [ ] If a multi-step write fails **partway**, what state is left? Is it
      recoverable, corrupt, or silently wrong?
- [ ] Any **read-then-write** that can race a concurrent actor (TOCTOU)? What
      detects the race — and is that detection being accidentally suppressed?

### Input trust & security *(add when relevant)*
- [ ] Which inputs are **untrusted**, and are they validated at the boundary?
- [ ] Injection, authz, secret handling, and PII/logging leaks?
- [ ] Is validation being applied where it can't help (against values the schema
      already precludes) while being absent where it's actually needed?

### Resource & performance *(add for hot paths)*
- [ ] Unbounded allocations, N+1 queries, work that scales with input in a
      surprising way?
- [ ] Anything holding a lock/connection/handle longer than necessary?

### The "what's missing" critic
- [ ] What does this change **not** handle that it should?
- [ ] What **claim** — in a docstring, comment, or name — is unverified or false?
- [ ] What case is **untested**? What invariant is **silently assumed**?
- [ ] Name the absent thing, not the present one.

> Extend the lens set to the change. These are the floor, not the ceiling.

## 3. Refute every finding (the verify pass)

Before surfacing anything:

- [ ] For each finding, construct the **concrete input/state** that triggers it.
      If you can't, mark it **refuted** and drop it.
- [ ] Confirm the **suggested fix would actually work** and wouldn't regress
      something else.
- [ ] For high-stakes findings, use **diverse verifiers** (one checks "does it
      reproduce," one "would the fix regress," one "is the claim even true") and
      require a majority to survive.

This step is what stops confidently-wrong findings — the failure mode of humans
and single-pass AI alike — from reaching the author.

## 4. Rank by severity and report

Every surviving finding gets a level; report most-severe first:

- [ ] **Blocker** — correctness, data loss, security, or invariant violation.
      Resolve before merge.
- [ ] **Should** — a real defect/risk that's safe to defer *with a tracked
      follow-up*.
- [ ] **Nit** — style/naming/consistency. Label it so it can be batched or
      skipped. Never present a nit at blocker volume.

A finding that can't be placed on this scale probably isn't one.

## 5. For each finding, write

- [ ] **What** is wrong (one sentence).
- [ ] **The failure scenario** — concrete inputs/state → wrong output/crash.
- [ ] **Severity** and whether it blocks merge.
- [ ] **The fix**, or an explicit "options / open question" if it's a judgment
      call for the author.

---

## What this checklist does not do

- It finds issues; **it does not decide which are worth doing now.** Keep that
  judgment human.
- It checks against invariants you supply; **it cannot know undocumented domain
  rules.** Write them down.
- It does not replace taste about which nits to suppress.
