---
name: adversarial-review
description: >-
  Adversarial, multi-lens code review that GENERATES findings (not triage). Use
  before opening or merging a PR, or whenever asked to "adversarially review",
  "try to break", "deeply review", or "self-review" a change. Assembles
  whole-system context plus the repo's operational invariants, runs specialized
  lenses that look for what breaks (not what the code does), verifies each
  finding by refutation before surfacing it, and reports ranked by severity. For
  a single file it runs the lenses inline; for PR-scale scope it escalates to the
  bundled multi-agent workflow so the lenses run as genuinely independent agents.
---

# Adversarial review skill

Generates review findings from scratch. This is the pre-merge self-review
counterpart to `pr-review` (which triages *existing* comments). Its whole reason
to exist is to catch the defects a diff-scoped bot structurally can't:
whole-system, failure-mode, and consistency bugs. The method's power comes from
**independent lenses** and **adversarial verification** — preserve both.

## Input

`$SCOPE` — free text describing **what to review** and, optionally, **what to focus
on**. The agent interprets it; it is not a rigid parser. Accepted forms:

- **A file or directory** — `app/services/payments.py`, `app/api/`.
- **A PR number** — `PR #123` or `123`. Pull the diff and the changed files.
- **A diff / "the current change"** — the default when nothing is given: the
  uncommitted work, or if that's empty, the branch vs its merge base.
- **A topic or subsystem** — `the upstream fetch retry path`, `cache invalidation`.
  First **resolve which files it means** (grep/explore), then review those; a topic
  is inferred scope, so it's less precise than naming files.
- **Any of the above plus focus instructions** — `app/services/orders.py — focus on
  transaction/rollback semantics`, or `the checkout endpoint; I care most about the
  concurrency angle, skip style nits`.

### Delta mode: reviewing changes made *since* a previous review

When this skill has already reviewed the change and work continued afterwards
(fixes for the findings, a new requirement, a follow-up commit), do **not** review
the whole thing again, and do **not** skip it either. Review the delta:

- Set `args.baseRef` to the **previously-reviewed commit** and `args.reviewRef` to
  the current one, so the scope is literally `git diff <reviewed> <now>`.
- Say in `args.context` that the baseline was already reviewed and what it
  validated, so the lenses do not re-derive settled ground.
- **List the prior findings and their fixes**, with the instruction: do not
  re-report the original issue, but do check whether each fix is correct,
  complete, and free of new defects. A fix is unreviewed code.
- **Fence off settled design decisions** explicitly ("do not re-litigate X"),
  or a fresh panel will re-argue choices you already worked through.
- Measure the delta first and say how big it is. Post-review fix batches are
  routinely large enough to deserve their own review: signature changes, new
  logic, and relocated call sites all hide in them.

This is worth doing because the reviewed artifact and the merged artifact are not
the same thing. It has found a false negative in a default code path that the
full review of the baseline never reached.

Separate the two parts of whatever you're given:

- The **scope** decides which files to pull into context (Step 1).
- Any **focus / emphasis / exclusion** is threaded into the assembled context so the
  lenses weight their passes accordingly — and on the workflow path it goes into
  `args.context` verbatim so it reaches the lens agents. Honor exclusions ("skip
  nits"), but never let a focus instruction suppress a **blocker** in another area:
  surface those regardless, flagged as outside the requested focus.

## Step 0 — Protect the working tree (do this first, every time)

The strongest protection is **worktree isolation**: when the reviewed state is
committed, every agent runs in its own throwaway checkout (Step 3b), so a stray
mutating git command rewrites a sandbox and can never reach the user's real tree.
It's preventive, not reactive — prefer it whenever it's available. A worktree
only holds committed work; the steps below decide whether isolation is on the
table and keep a git snapshot guard for when it isn't.

> **The worktree is cut from the DEFAULT BRANCH, not from current HEAD.** A
> review commit sitting on a feature branch is therefore *not* checked out inside
> it — the agents see the **pre-change** files. Isolation protects the tree; it
> does **not** deliver the change. So whenever you set `args.isolate: true` you
> MUST also pass `args.reviewRef` (and `args.baseRef`), which the workflow turns
> into a standing instruction to read changed files via `git show <ref>:<path>`.
> This has already produced a wrong review: three verifier agents refuted a real
> blocker as "factually false" because the offending entry was absent from
> *their* checkout. Also put the diff itself in `args.context` so the change is
> reachable even without git.

1. **Check whether the tree is dirty:** `git status --porcelain`.
2. **If the reviewed state is already committed** (a PR, or a committed branch vs
   its merge base), set `args.isolate: true` **and `args.reviewRef`** (Step 3b)
   and proceed — the agents run isolated and cannot touch the tree.
3. **If it is dirty and the scope is the local diff**, do not start yet. Offer, in
   order of preference:
   - **(a) commit to a WIP/branch first** — *recommended*: it captures the work
     AND unlocks worktree isolation (set `args.isolate: true` **and pass the new
     commit as `args.reviewRef`** — without it the isolated agents cannot see the
     change at all), the only option that makes the agents physically unable to
     mutate the tree. This commit is
     **scaffolding for isolation, not the final state**: once the review and any
     fixes have landed, restore the uncommitted working state (`git reset --soft
     <pre-review-ref>`, e.g. the branch point or `main`) so the reviewed change +
     fixes remain as uncommitted edits to review in the editor — unless the user
     explicitly wants the commit kept to push/PR immediately.
   - **(b) `git stash`** — noting the review then sees nothing.
   - **(c) proceed in place, uncommitted** — explicitly accepting the risk: agents
     run in the real tree, `args.isolate` stays `false`, and the only guards are
     the read-only mandate and the snapshot below.
   Wait for the user's choice.
4. **Snapshot before the fan-out** (cheap, and the fallback guard when not
   isolated):
   ```bash
   SNAP="${CLAUDE_JOB_DIR:-/tmp}/tmp"; mkdir -p "$SNAP"
   git status --porcelain  > "$SNAP/ar_tree_before.txt"
   git diff HEAD           > "$SNAP/ar_diff_before.txt"
   # UNTRACKED files are invisible to `git diff HEAD`, so copy them too or the
   # snapshot silently fails to cover brand-new files (a new module, a new test).
   git ls-files --others --exclude-standard -z \
     | xargs -0 -r tar czf "$SNAP/ar_untracked_before.tgz" 2>/dev/null || true
   # SUBMODULES are also invisible to `git diff HEAD` (it reports only a changed
   # POINTER, never dirty content inside). Record their state separately.
   git submodule status --recursive > "$SNAP/ar_submodules_before.txt" 2>/dev/null || true
   git submodule foreach --recursive --quiet \
     'git status --porcelain | sed "s|^|$displaypath |"' \
     > "$SNAP/ar_submodule_dirt_before.txt" 2>/dev/null || true
   ```

   If the change adds new files, say so when offering option (c): the snapshot's
   coverage of them is the weakest part of an in-place review.

This step exists because it has already gone wrong: a lens agent ran
`git checkout <file>` to compare pre-change behaviour and silently reverted a
file holding uncommitted work. Worktree isolation is the *enforcement* that a
prompt rule (`READ_ONLY_MANDATE`) can only request — a sandboxed agent's
`git checkout` rewrites its own throwaway checkout, not the user's file. The
snapshot is the last line for the one case isolation can't cover: a deliberate
in-place review of uncommitted work.

## Step 1 — Assemble context (do this before any reviewing)

Context quality is the single biggest determinant of review quality.

1. **The change itself** — the diff, and the **full text of every changed file**
   (not just hunks).
2. **Collaborators** — for each changed file, pull its callers and callees and any
   config/constants it depends on, *including unchanged files*. Grep for callers;
   read the config. (Defects hide in the interaction between a changed file and an
   unchanged one — e.g. an engine's isolation setting deciding whether a rollback
   in another file even works.)
3. **Invariants** — read the target repo's `CLAUDE.md`, especially an
   "Operational Invariants" section if present. These are non-negotiables; a
   violation is a blocker. If none exist, infer them and note that they're
   unwritten.

## Step 2 — Choose scale (and understand the fidelity tradeoff)

The two paths are **not** equal-fidelity — this is the most important choice here.

- **Inline** (this agent runs the lenses in its own context) — a *quick, lighter*
  structured review. Good for one file, a small focused diff, or a fast sanity
  check. Its limitation: the lenses run in a single context, so they bleed toward
  one averaged review, and the refutation is the same mind that made the finding —
  i.e. it partly reintroduces the single-pass weakness the method exists to fix.
  Cheap and conversational. Go to Step 3a.
- **Workflow** (the bundled multi-agent engine) — the *full-fidelity* path, and the
  one that earns the method its keep. Each lens is a separate agent (genuinely
  independent), findings are merged into distinct defects, then each is verified by
  independent refuters before it surfaces. Use it for a PR, several files, a
  release check, whenever the user asks for "thorough" / "deep" / "adversarial", or
  whenever the answer actually matters. Heavier and slower (runs in the background).
  Go to Step 3b.

When in doubt, prefer the workflow: inline is the convenience, the workflow is the
method.

## Step 3a — Inline lenses

Run **each lens below as its own focused pass** — do not merge them into one
"review everything" prompt. For each pass, the instruction is *"try to break
this,"* never *"review this."* Describe nothing; find the input, state, timing, or
failure that makes it wrong. An empty result for a lens is a valid answer — say so
and move on.

Then run Step 4 (refute) and Step 5 (rank + report).

## Step 3b — Workflow escalation

Call the Workflow tool with the bundled script and the assembled context as args:

```
Workflow({
  scriptPath: "<this skill's base directory>/adversarial-review.workflow.js",
  args: {
    scope: "<human description, e.g. 'PR #123' or 'app/api/orders.py'>",
    context: "<the assembled whole-system context from Step 1: changed files, callers, diff>",
    invariants: "<the operational invariants text from CLAUDE.md>",
    targetKind: "code" | "spec" | "any",  // optional, defaults to "any"
    isolate: true | false,                // Step 0: true when the reviewed state
                                          // is committed, false for in-place work
    reviewRef: "<sha or branch holding the change>",  // REQUIRED when isolate is
    baseRef: "<sha or branch to diff against>"        // true — the worktree is at
                                          // the DEFAULT BRANCH, so without these
                                          // the agents never see the change
  }
})
```

Set `targetKind` from what you actually read in Step 1 — you already know whether
the changed files are source or prose:

- **`spec`** — the changed files are specs, schemas, docs, `.md`/`.yaml`/IDL, with
  no meaningful executable logic. Skips the three code lenses.
- **`code`** — source changes with no spec/prose component. Skips the two spec lenses.
- **`any`** *(default, and the right choice whenever unsure)* — mixed changes, or a
  spec repo that also ships a reference implementation, which is exactly where
  spec↔implementation drift lives and where you want both sets running.

The workflow fans the lenses out in parallel, verifies each finding by refutation
(diverse angles, majority survives), dedupes, and returns findings ranked by
severity. Relay its result via Step 5.

**On worktree isolation.** Set `args.isolate: true` and the workflow runs every
lens, merge, and verify agent in its own throwaway git worktree — via the
harness's built-in `isolation: 'worktree'`, so there are no shell commands and no
added permissions, and the worktrees are auto-cleaned. A destructive git command
then rewrites a sandbox instead of the user's tree: this is the *enforcement* the
`READ_ONLY_MANDATE` prompt rule can only ask for. It is **not** a substitute for
Step 0's judgement — a worktree holds only **committed** work, so uncommitted
work is invisible inside it. Set it whenever the reviewed state is committed (a
PR, a committed branch, or after a Step 0 commit); leave it `false` only for a
deliberate in-place review of uncommitted work, which then relies on the read-only
mandate and the snapshot guard.

**Isolation does not deliver the change — you must.** The worktree is cut from
the **default branch**, so on a feature branch the agents open pre-change files.
Always pass `args.reviewRef` (+ `args.baseRef`) alongside `isolate: true`; the
workflow turns them into a standing instruction to read changed files with
`git show <ref>:<path>` and to never infer absence from the working copy. Put
the diff in `args.context` as well, so the change survives even if an agent
ignores git entirely. Skip this and the run still *looks* healthy — agents
review the old code and report confidently on it.

## Step 4 — Refute every finding (inline path)

Before surfacing anything, try to **refute** each finding — but refute on **validity, not severity**:

- **REFUTE only if the finding is wrong**: the claim is factually false, it describes *intended*
  behavior, or the proposed fix would regress or is unnecessary. A finding that is factually correct but
  low-impact is **not** refuted — it survives as a **nit** (adjust its severity down; don't discard it).
  Do not conflate "minor" with "invalid."
- **"Reproduce it" means different things by target.** For a runtime bug, construct the concrete
  input/state that triggers it — if you can't, it's likely not real. For a **spec / docs / config /
  prose** target, most real defects have *no* triggering input: "reproduction" is showing concretely how
  the artifact **misleads a reader, makes two conforming implementations diverge, contradicts another
  section, or states something false**. Don't drop a real consistency / accuracy / parity defect just
  because it has no runtime repro — that filter is code-calibrated and mis-fires on documentation.
- **No charitable-reading dismissals.** If a claim is false or a reference ambiguous under a *plain*
  reading, that's a real defect even if a generous interpretation exists.
- **Never refute on "I looked and it isn't there" without checking the reviewed ref.** A refutation
  resting on *file contents* ("that entry doesn't exist", "the premise is factually false", "that
  line number is out of range") is only as good as the tree it read. Under isolation the agent's
  worktree is the **default branch**, so a change on a feature branch is simply absent from it, and
  "absent" reads exactly like "the finding is wrong". Re-check with `git show <reviewRef>:<path>`
  before killing it. This has already destroyed a real blocker: three verifiers agreed a CI-breaking
  manifest entry was imaginary, because none of them was looking at the branch that had it.
  Refutations that rest on *logic*, *spec text*, or *intended behaviour* are unaffected.
- Confirm the suggested fix would actually work and wouldn't regress something.

This is what stops confidently-**wrong** findings from reaching the author — *wrong*, not merely *minor*.

## Step 5 — Rank and report

**First, verify the tree survived** against the Step 0 snapshot. Before reading a
single finding:

```bash
SNAP="${CLAUDE_JOB_DIR:-/tmp}/tmp"
git status --porcelain  > "$SNAP/ar_tree_after.txt"
git diff HEAD           > "$SNAP/ar_diff_after.txt"
git submodule foreach --recursive --quiet \
  'git status --porcelain | sed "s|^|$displaypath |"' \
  > "$SNAP/ar_submodule_dirt_after.txt" 2>/dev/null || true
diff "$SNAP/ar_tree_before.txt" "$SNAP/ar_tree_after.txt" && \
  diff "$SNAP/ar_diff_before.txt" "$SNAP/ar_diff_after.txt" && \
  diff "$SNAP/ar_submodule_dirt_before.txt" "$SNAP/ar_submodule_dirt_after.txt" && \
  echo "tree unchanged"
```

**Isolation does NOT make this check redundant.** Two leaks are confirmed: a
submodule working tree is not sandboxed, and agents sometimes act on the real
repo path rather than their worktree. On one isolated run an agent left a
self-referential symlink inside a submodule. So run the compare either way.

The three compares cover different things, and each is blind to the others'
territory. The porcelain compare catches added / removed / renamed files **and is
the only one that reveals a dirty submodule** (as a ` M <path>` line). The
`git diff HEAD` compare catches a tracked in-place edit, including one that
leaves the line count unchanged, but it says **nothing** about untracked files or
about content inside a submodule. The submodule compare covers the rest.

If any differ, an agent mutated the tree despite the read-only mandate: **say so
at the top of your report, before the findings**, name what changed, and help the
user restore it. `$SNAP/ar_diff_before.txt` holds the exact pre-review state of
every tracked change; `ar_untracked_before.tgz` holds the new files. Report the
damage proportionately — distinguish "a stray file was added" (annoying) from "a
file holding your work was reverted" (serious) — but never omit it. A silently
reverted file is a worse outcome than any finding in the report is a good one.
Before deleting anything an agent created, look at it: confirm it is review
debris and not something of the user's, and say what it was.

**Second, sanity-check the refutations you're about to trust.** The workflow
returns a `refuted` array alongside `findings`, each entry carrying the
refutation reasoning — read it. Scan for any refutation resting on **file
contents** ("that entry doesn't exist", "the premise is factually false", "that
line is out of range"): under isolation that evidence came from the default
branch, not the change, so one `git show <reviewRef>:<path>` settles it. A
refutation resting on *logic*, *spec text*, or *intended behaviour* needs no
recheck. Also re-check any finding you *expected* to see and didn't. Treat the
survivor list as a floor, not a ceiling, and say plainly if you had to resurrect
something — a review that killed a real defect is worth knowing about.

Then report survivors **most-severe first**, each with: what's wrong (one sentence),
the concrete failure scenario, severity, and the fix (or an explicit open question
if it's a judgment call). If the host exposes `ReportFindings`, emit through it so
the findings render ranked; otherwise use markdown.

Severity:
- **Blocker** — correctness, data loss, security, or an invariant violation.
  Resolve before merge.
- **Should** — a real defect/risk that's safe to defer *with a tracked follow-up*.
- **Nit** — style/naming/consistency. Label it so it can be batched or skipped;
  never present a nit at blocker volume.

## The lenses

### 1. Concurrency & lifecycle
For every `await`/async boundary, thread, background task, and external call:
enumerate every way it can fail or be abandoned (timeout, cancellation, client
disconnect, shutdown, exception) and confirm cleanup/rollback/cancellation runs on
**all** of them. Watch for handlers that miss `BaseException`-derived cases (e.g.
`asyncio.CancelledError`). What breaks if this runs twice concurrently, or is
killed mid-flight?

### 2. Failure-mode & observability
For each external dependency: what happens when it's **slow**, **down**, or returns
**malformed** data — and are those cases distinguished when they should be? Can any
failure path leave the system unable to **report** the failure (logs/metrics/traces
going dark)? Are retries/queues/backoff bounded, and what happens at the bound?

### 3. Data consistency & transactions
Under this system's actual isolation model, what is truly **atomic**? Verify — don't
assume — that rollbacks and transactions are operative and not no-ops (e.g. under
AUTOCOMMIT a mid-loop `rollback()` does nothing). If a multi-step write fails
**partway**, what state is left — recoverable, corrupt, or silently wrong? Flag
read-then-write races (TOCTOU) and any detection of them that's being suppressed.

### 4. Input trust & security
Trace **trust boundaries**, not just code. Which inputs are untrusted, and are they
validated *at* the boundary — or validated where they can't help (against
schema-precluded values) while absent where they're actually needed? Injection
(SQL/shell/template/path/deserialization/SSRF), authorization (missing, on the wrong
object, after the side effect, confused deputy), and **secret/PII leakage across
every egress** — logs, exception messages, tracebacks that render frame locals,
telemetry and span attributes, URLs, generated reports, error responses, test output.

A redaction covering **one** surface while the same secret stays reachable through
another is a real defect, and a claim that it's "masked" makes it worse — verify that
claim against every surface. Also: a config typo or missing value that silently falls
back to an ambient **production** credential; a "dry run" path that still reaches a
real system. For a spec: is a security-critical decision (auth, replay/nonce/expiry,
token lifetime, rate limiting, enumeration-safe errors) left to the implementer, or
marked `MAY`/`SHOULD` when interop needs `MUST`?

Name the attacker, what they control, and what they get. A finding you can't phrase
that way is hygiene, not a vulnerability — rank it accordingly.

### 5. Resource & performance *(add for hot paths)*
Unbounded allocations, N+1 queries, work that scales surprisingly with input,
locks/connections/handles held longer than necessary.

### 6. The "what's missing" critic
What does the change **not** handle that it should? What claim — in a docstring,
comment, or name — is unverified or false? What case is untested, what invariant
silently assumed? Name the absent thing, not the present one.

### 7. Spec consistency & implementation parity *(spec targets)*
The bar is **two competent implementers read this and build incompatible things** —
not "is it well written". Sections that contradict each other, an example that
contradicts its own schema, a term redefined or used before definition, dangling
references, drift between the spec and a reference implementation, version/changelog
skew, and under-specified boundaries (absent vs null vs empty, ordering, duplicates,
case, limits). State the two divergent readings explicitly; that is what makes it a
defect rather than a preference.

### 8. Normative language & conformance *(spec targets)*
RFC 2119 / RFC 8174 audit. A requirement in bare prose with no MUST/SHOULD/MAY —
mandatory or descriptive? SHOULD where interop actually breaks (that's a MUST), MAY
for behaviour others depend on (that's not optional), lowercase keywords in
normative sentences, requirements with no actor, the same behaviour at conflicting
obligation levels in different sections, untestable requirements, and MUST NOT
without a stated consequence or fallback. Name the implementation choice left open
and the interop failure it produces.

> Extend the lens set to the change. These are the floor, not the ceiling.

### Which lenses actually run

The workflow script runs seven lenses: 1, 2, 3, 4, 6, 7 and 8. Only **lens 5
(resource & performance)** is documented but not in `LENSES` — it's genuinely
hot-path-conditional, and running it on every review produces mostly noise. Use it
on the inline path, or add it to the script when reviewing something performance-
sensitive.

Selection is driven by `args.targetKind`, and each lens carries an `applies` tag:

| `targetKind` | lenses run |
|---|---|
| `any` *(default)* | all seven |
| `code` | concurrency, failure-mode, consistency, **security**, what's-missing |
| `spec` | spec-consistency, normative-language, **security**, what's-missing |

**Security is untagged, so it runs in every mode.** A skipped security lens reads as
"no security findings" when it means "nobody looked", and specs have their own
security defects — under-specified auth, replay protection left to the implementer,
controls marked `MAY` that interop actually requires. One agent is cheap next to one
missed credential leak.

`any` is the default on purpose — running a lens that finds nothing costs one agent,
while skipping one that would have found a blocker costs the review. Narrow it only
when the target kind is unambiguous (a docs/spec-only repo, or a pure code change
with no prose). The workflow logs which lenses it skipped, so a narrowed run never
reads as "nothing found in that dimension" when it means "never looked".

## Rules

- **Break it, don't describe it.** Every pass hunts for a failure, not a summary.
- **Whole-system context or it doesn't count.** Never review a hunk in isolation.
- **Verify before surfacing.** A finding that can't be reproduced is refuted.
- **Rank, and label nits.** Most-severe first; never a nit at blocker volume.
- **Findings, not fixes-in-place.** This skill reports; it does not edit code.
- **Read-only means the working tree, not just the source.** Never run
  `git checkout`, `git restore`, `git stash`, `git reset`, `git clean`,
  `git apply`, or `git revert`; never write, move, or delete a file; never run a
  `--fix` linter or a snapshot-rewriting test. To read another version of a file
  use `git show <ref>:<path>`. This is spelled out because the generic rule above
  was not enough — an agent reverted a file to "compare before/after" and did not
  consider that editing. If a check appears to require mutating the tree, skip the
  check and hedge the finding instead.
