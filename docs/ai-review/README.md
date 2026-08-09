# AI-assisted code review — methodology

This folder captures how to get *high-value* review out of AI, and why the
off-the-shelf autoreview bots don't deliver it on their own.

## The documents

- **[multi-lens-review-workflow.md](multi-lens-review-workflow.md)** — the
  review method: adversarial framing, whole-system context, four specialized
  lenses, a verify/refute pass, and a severity rubric. How to run it today, and
  how it could be made runnable.

- **[human-vs-copilot-findings.md](human-vs-copilot-findings.md)** — the case
  study that motivated the method. What a strong human reviewer caught that a
  diff-scoped bot structurally cannot, the root-cause diagnosis of *why*, and the
  residual gaps AI won't close.

- **[adversarial-review-checklist.md](adversarial-review-checklist.md)** — a
  portable, project-agnostic checklist you can point any capable AI (or human) at.
  This is the reusable artifact; the other two are the reasoning behind it.

## The one-sentence version

The high-value catches come from **whole-system context + an adversarial
"try to break this" framing + a reasoning model + written-down invariants** —
none of which a cheap, diff-scoped, single-pass autoreview bot is configured to
do. Change the harness, not the model, and most of the gap closes.