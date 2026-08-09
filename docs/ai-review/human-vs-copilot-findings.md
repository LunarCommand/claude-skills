# Human review vs. Copilot review — what we learned

A retrospective from one real PR that was reviewed in two distinct ways: earlier
rounds by GitHub Copilot's autoreview, and a final round of threads by a strong
human reviewer. Comparing them exposed a clear, repeatable gap — and, more
usefully, *why* it exists and what closes it.

## The headline

The human produced three catches that a diff-scoped autoreview bot is
**structurally incapable** of producing — not because the model is weak, but
because the review *harness* is the wrong shape for them. All three share a
signature: they require whole-system context, reasoning about what the code
*doesn't* do, and a multi-hop causal chain rather than a local pattern match.

## The three structurally-missed catches

### #1 — Cleanup in the wrong scope

`cancel.set()` lived only inside `except TimeoutError`. But `CancelledError`
(raised on client disconnect or server shutdown) is a `BaseException`, so it
slips past `except Exception` entirely — leaving the worker thread writing to the
DB with the cancel token never set. Fix: move it to `finally`.

**Why a bot misses it:** the line is *locally correct*. You only see the defect by
asking "what else can abandon this `await`, and does cleanup run on all of those
paths?" — a whole-function, exception-hierarchy question. A hunk-scoped reviewer
has no reason to flag a correct-looking line.

### #2 — A conflated failure mode

The OTel endpoint probe treats a connect **timeout** the same as a **refused**
connection. A timeout more likely means "valid config, transiently unavailable,"
where the exporter should attach and retry. Worse, the fallback interacts with a
decision in another part of the file (stdout handler skipped when OTel is the
sink), so a naïve fix risks a silent total logging blackout.

**Why a bot misses it:** the defect is in what the code *doesn't* distinguish, and
the danger is only visible when you combine the probe logic with the
sink-selection logic and with domain knowledge of how batch exporters behave.
Presence-oriented review flags what's written, not what's absent.

### #3 — An inoperative safety mechanism

A write helper's `db.rollback()` on failure is a **no-op**: the engine runs under
`isolation_level="AUTOCOMMIT"` (set in a *different* file), so every prior
statement already committed. The docstring's "rolls back on failure" was simply
false.

**Why a bot misses it:** the deciding fact — the isolation level — lives in an
unchanged file that isn't in the diff. Judging the changed file correctly
requires pulling in its collaborators. Diff-only review can't.

## Root-cause taxonomy

Every structural miss traces to one or more of these four properties of
off-the-shelf autoreview:

1. **Diff-scoped** — reviews hunks, not the whole file or its collaborators.
   (Misses #1, #3.)
2. **Presence-oriented** — flags what is written, not what is missing or
   should-be. (Misses #2, and the "what's-missing" class generally.)
3. **Single-pass, non-adversarial** — describes the code rather than trying to
   break it. (Misses #1, #2.)
4. **Cheap/fast model** — optimized for latency and cost, not multi-hop
   reasoning. (Amplifies all of the above.)

The important consequence: **these are configuration limits, not capability
limits.** A reasoning model given whole-system context and an adversarial prompt
reproduced #1 and #3 during the review itself (reading the whole function and
checking `CancelledError`'s MRO; cross-referencing the engine config against the
write helper). The fix is a different harness, not a smarter model. That harness
is the [multi-lens workflow](multi-lens-review-workflow.md).

## Hit rate is the wrong metric — signal quality is the right one

Raw "comments that led to a change" understates the difference. The human's fix
rate wasn't dramatically higher than Copilot's. What differed was the value of
the **declines**:

- Copilot's false positives were noise — declining them taught us nothing, and
  two of its *suggested fixes would have made things worse* (collapsing a
  structured telemetry payload into an opaque string).
- The human's declines mostly forced us to **verify or articulate a real design
  property** — the TOCTOU role of a uniqueness constraint, the transaction and
  isolation semantics, a timestamp-precision write convention. Even a "no
  change" verdict had positive value.

So evaluate reviewers (human or AI) on **signal quality** — does engaging a
comment leave you understanding the system better? — not on raw hit rate.

## Where the human still wins

Three things AI review will not reliably reproduce. Don't over-index on
automating them away:

- **Judgment about whether a real issue is worth doing now.** The human correctly
  *deferred* the observability work rather than gold-plating a narrowly-scoped
  PR. AI tends to surface everything at once.
- **Undocumented domain knowledge.** AI checks against invariants you give it; it
  won't independently know a business rule that isn't written down.
- **Taste** — which nits to suppress entirely.

## Where AI can *exceed* the human

Even a strong human reviewer had one comment that was **confidently wrong** on a
specific technical claim (asserting a `sorted()` call was valueless when it was
load-bearing for both sliceability and determinism). A wrong comment stated with
authority is expensive.

The [refute pass](multi-lens-review-workflow.md#the-verify--refute-pass) is
exactly the antidote: forcing each finding to be reproduced or refuted before it's
surfaced catches confidently-wrong claims that humans wave through. On the
precision axis, a well-harnessed AI can be *better* than the human, even while
trailing on insight.

## Recommendations

1. **Write the invariants down** — e.g. a `CLAUDE.md` "Operational Invariants"
   section. This is the highest-leverage change; it upgrades every future review
   (and onboarding).
2. **Review with a reasoning agent over whole-system context**, not a diff-scoped
   bot, for anything touching concurrency, failure modes, or data consistency.
3. **Use adversarial, multi-lens passes plus a refute step.** See the
   [workflow](multi-lens-review-workflow.md) and
   [checklist](adversarial-review-checklist.md).
4. **Keep the human for judgment.** Automate the finding; keep the "not now" call
   human.
