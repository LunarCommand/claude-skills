// Multi-lens adversarial code review — the parallel engine behind the
// adversarial-review skill.
//
// Runs each review lens as an INDEPENDENT agent (so they don't average together
// the way a single-context review does), MERGES the raw findings into distinct
// defects, then verifies each distinct defect by refutation from diverse angles
// before it surfaces. Merging BEFORE verifying is deliberate: it avoids paying to
// verify the same defect once per duplicate (the dominant cost). Survivors are
// ranked by severity.
//
// Invoked by the skill, which assembles context and passes it via `args`:
//   args.scope       - human description of what's under review (e.g. "PR #123")
//   args.context     - assembled whole-system context: changed files, callers, diff
//   args.invariants  - the target repo's operational invariants (from CLAUDE.md)
//   args.targetKind  - 'code' | 'spec' | 'any' (default 'any'). Selects which
//                      lenses run. 'any' runs all of them and is the safe
//                      fallback; pass a specific kind to stop spending agents on
//                      lenses that cannot apply (a concurrency lens finds nothing
//                      in a prose spec; a normative-language lens finds nothing
//                      in a Python module).
//   args.isolate     - true to run every lens/merge/verify agent in its own
//                      throwaway git worktree (harness-managed, no shell, no
//                      extra permissions), so a stray mutating git command hits a
//                      sandbox instead of the user's tree. Requires the reviewed
//                      state to be COMMITTED, since a worktree can only hold
//                      committed work. The skill sets this for PR /
//                      committed-branch reviews and after a Step 0 commit, and
//                      leaves it false for a deliberate in-place review of
//                      uncommitted work.
//                      CAUTION, observed in the field: the worktree is created
//                      from the repo's DEFAULT BRANCH, not from current HEAD. A
//                      review commit sitting on a feature branch is therefore
//                      NOT checked out inside it. See args.reviewRef.
//   args.reviewRef   - the committed ref holding the change under review (SHA or
//                      branch), plus optional args.baseRef for the ref to diff
//                      against. REQUIRED when args.isolate is true: it is the
//                      only way an isolated agent can reach the change, since
//                      its worktree sits at the default branch. Agents are told
//                      to read the change via `git show <reviewRef>:<path>` and
//                      `git diff <baseRef> <reviewRef>`, never from their own
//                      working copy.
//
// This is plain JS: no TypeScript, no filesystem, no Date/Math.random.

export const meta = {
  name: 'adversarial-review',
  description:
    'Multi-lens adversarial code review: specialized lenses scan the change in parallel, raw findings are merged into distinct defects, each is verified by refutation, and survivors are ranked by severity.',
  phases: [
    { title: 'Review', detail: 'one agent per adversarial lens, in parallel' },
    { title: 'Merge', detail: 'cluster raw findings into distinct defects before verifying' },
    { title: 'Verify', detail: 'refute each distinct defect; 3 angles for blocker/should, 2 for nit' },
    { title: 'Synthesize', detail: 'severity-rank the survivors' },
  ],
}

// args may arrive as a parsed object or, depending on how the caller passes it,
// as a JSON-encoded string — normalize both so scope/context/invariants actually
// reach the lenses.
let a = args || {}
if (typeof a === 'string') {
  try {
    a = JSON.parse(a)
  } catch (e) {
    a = {}
  }
}

const scope = a.scope || 'the current change'
const context =
  a.context ||
  'No context was supplied. Read the changed files and their callers from the working tree yourself before reviewing.'
const invariants =
  a.invariants ||
  'No invariants were supplied. Infer them from the code and any CLAUDE.md, and treat clear violations as blockers.'

// 'any' is deliberately the default: running a lens that finds nothing costs one
// agent, but SKIPPING a lens that would have found a blocker costs the review.
// Only narrow this when the target kind is unambiguous.
const targetKind = a.targetKind === 'code' || a.targetKind === 'spec' ? a.targetKind : 'any'

// Worktree isolation: when the reviewed state is committed, run every
// file-touching agent in its own throwaway checkout so a stray `git checkout`
// (this HAS happened — see READ_ONLY_MANDATE) mutates a sandbox, not the user's
// tree. Off by default: a worktree can only hold committed work, so the skill
// only sets args.isolate once the change is committed.
//
// Isolation is NOT a complete sandbox. Two observed leaks: (1) submodule
// working trees are not isolated, and an agent has written into one during an
// isolated run; (2) agents sometimes operate on the real repo path directly
// rather than their worktree. So the READ_ONLY_MANDATE and the caller's
// snapshot both still matter with isolation on.
const ISOLATE = a.isolate === true

// The ref actually holding the change, and what to diff it against. Load-bearing
// under isolation: the worktree is cut from the DEFAULT BRANCH, so on a feature
// branch the agents' checkout does NOT contain the change at all.
// Both refs are interpolated into commands verify agents are told to run, and on
// a public repo a reviewRef is routinely a contributor-supplied branch name.
// Two failure modes to avoid, and the first attempt at this hit both:
//   - a leading `-` makes the ref parse as an OPTION, so `git diff --output <p>`
//     truncates <p>. `git check-ref-format refs/heads/--output` exits 0, so git
//     itself will not stop you.
//   - failing SILENTLY is worse than not checking. A rejected ref became '', and
//     the no-ref branch below then told every agent "the skill did not pass a
//     reviewRef" — false, and under isolation it sent them to the pre-change
//     default branch with nothing logged.
// So: accept what git accepts (including ~ ^ @ {} for revisions), reject a
// leading dash and `..`, and when something IS rejected say so loudly and keep
// that fact distinguishable from "none was supplied".
const SAFE_REF = /^[A-Za-z0-9][A-Za-z0-9._\/~^@{}+-]{0,254}$/
const isSafeRef = (v) => typeof v === 'string' && v !== '' && SAFE_REF.test(v) && v.indexOf('..') === -1
const REVIEW_REF = isSafeRef(a.reviewRef) ? a.reviewRef : ''
const BASE_REF = isSafeRef(a.baseRef) ? a.baseRef : ''
// Supplied but refused — never conflate with "not supplied".
const REVIEW_REF_REJECTED = !!a.reviewRef && !REVIEW_REF
const BASE_REF_REJECTED = !!a.baseRef && !BASE_REF

// Appended to every agent prompt when ISOLATE is on.
//
// This exists because it has already produced a WRONG REVIEW: three verifier
// agents refuted a real blocker as "factually false" because the file they read
// did not contain the offending entry — their worktree was at the default
// branch, while the change sat on a feature branch. A finding died on evidence
// from the wrong tree. Absence of something in YOUR checkout proves nothing.
const WORKTREE_REF_MANDATE = !ISOLATE
  ? ''
  : '\n\n## Your checkout probably does NOT contain the change (critical)\n' +
    'You are running in an isolated git worktree cut from the repository\'s ' +
    'DEFAULT BRANCH, not from the branch under review. If the change lives on a ' +
    'feature branch, the files in your working directory are the PRE-CHANGE ' +
    'versions.\n' +
    (REVIEW_REF
      ? 'The change under review is at ref: ' +
        REVIEW_REF +
        '.\n' +
        (BASE_REF ? 'Diff it against: ' + BASE_REF + '.\n' : '')
      : (REVIEW_REF_REJECTED
          ? 'A reviewRef WAS supplied but was refused as unsafe to interpolate ' +
            'into a command, so it has been dropped. Do not assume the working ' +
            'copy holds the change: it almost certainly does not. Say in every ' +
            'finding that the reviewed ref was unavailable.\n'
          : 'The skill did not pass a reviewRef; derive it from the scope ' +
            'description and say so in your finding if you could not.\n')) +
    'Therefore:\n' +
    '- Read changed files with `git show <reviewRef>:<path>`, NOT by opening the ' +
    'path directly.\n' +
    '- Get the diff with `git diff <baseRef> <reviewRef>`.\n' +
    '- NEVER conclude "the file does not contain X", "that entry is absent", or ' +
    '"the premise is factually false" from your working copy. Re-check against ' +
    'the ref first. Refuting a real finding on wrong-tree evidence is the single ' +
    'most damaging thing you can do here.\n' +
    '- Unchanged collaborator files ARE valid to read directly: they are the same ' +
    'on both refs. It is the CHANGED files that require the ref.'

// Applies to every angle and severity. A nit panel skips `reproduce`, and an
// "untested"/"undocumented" finding is exactly the shape a nit takes — so an
// absence rule living only in that angle never reaches the findings that most
// need it.
const ABSENCE_SEARCH_MANDATE =
  '\n\n## An absence claim has to be searched, not asserted\n' +
  'If the finding asserts something is ABSENT (untested, unguarded, unhandled, ' +
  'undocumented), go look for the thing it says is missing before accepting it: ' +
  'name the test, guard or section that would have to exist, then search for it. ' +
  'An existing test refutes the finding only if it covers the thing the finding ' +
  'names, though it may cover it indirectly, and "I did not see one" is not a ' +
  'search. Absence claims are the easiest to state and the least often checked.' +
  (!REVIEW_REF
    ? ''
    : '\nSearch at the reviewed ref, not your working copy: list with ' +
      '`git ls-tree -r --name-only ' +
      REVIEW_REF +
      '` and read with `git show ' +
      REVIEW_REF +
      ':<path>`. A search of the wrong tree refutes nothing, in either ' +
      'direction — what you find there may not exist in the reviewed state, and ' +
      'what you fail to find may have been added by the change.')

// Verify-stage only. The lenses judge the ref they were given, which is right:
// that is the artifact under review. But a finding is only worth reporting if it
// is still true where the work now lives, and a review ref is routinely behind
// the branch tip — a PR reviewed mid-stream, a resumed run, fixes landed while
// the review was in flight. Reporting an already-fixed defect as live costs the
// caller a triage pass and erodes trust in the rest of the findings.
const TIP_RECHECK_MANDATE = !REVIEW_REF
  ? ''
  : '\n\n## Check the finding against the current tip, not just the reviewed ref\n' +
    'The reviewed ref is ' +
    REVIEW_REF +
    ', which may be behind the branch tip. Before returning real=true:\n' +
    '- Find the branches that contain it: `git branch -a --contains ' +
    REVIEW_REF +
    '`. Ignore any `worktree-*` entry: those are this run\'s own sandboxes.\n' +
    '- The branch under review is authoritative. Another branch may also contain ' +
    'the ref — a colleague\'s spike, a merge into the default branch — and a fix ' +
    'that exists only there does NOT help the caller, who is about to merge the ' +
    'branch under review. Re-check on that branch, not on whichever one is newest.\n' +
    '- List its true descendants: `git log --oneline --ancestry-path ' +
    REVIEW_REF +
    '..<branch>`, naming the branch explicitly.\n' +
    '- **If that prints nothing, the reviewed ref IS that branch\'s tip. The check ' +
    'is DONE and the finding stands on its own merits — say nothing further about ' +
    'the tip.** A commit is not its own descendant, so an empty list here is the ' +
    'normal, healthy case, not a failure.\n' +
    '- If it does list commits, confirm the candidate before reading it: ' +
    '`git merge-base --is-ancestor ' +
    REVIEW_REF +
    ' <tip>` must succeed. A tip that fails is not a descendant, the change was ' +
    'never on it, and the finding will look absent there because you are reading ' +
    'the wrong tree — which refutes NOTHING.\n' +
    '- Only then re-check with `git show <tip>:<path>`. If it has genuinely been ' +
    'fixed, mark real=false and name the commit that fixed it.\n' +
    '- If no branch contains the ref, or a command errors, the check is SKIPPED, ' +
    'not passed. Say so and judge the finding on the reviewed ref alone. An error ' +
    'is not a negative result.\n' +
    (ISOLATE
      ? 'Never write the range with the right side omitted: a bare `' +
        REVIEW_REF +
        '..` means `' +
        REVIEW_REF +
        '..HEAD`, and under isolation HEAD is the DEFAULT BRANCH, not the branch ' +
        'under review, so it answers a different question.\n'
      : 'Name the right side of the range explicitly rather than relying on HEAD, ' +
        'so the check does not depend on which branch happens to be checked out.\n') +
    'Only an actual fix on the branch under review refutes. Do not use this ' +
    'against a finding that is merely harder to see at the tip, and never on ' +
    'evidence from a tree that does not descend from the reviewed ref: only an ' +
    'actual fix counts.'

// The refs bounding the review, surfaced whether or not isolation is on.
// Delta mode passes baseRef/reviewRef with isolation OFF; without this the
// agents never learn baseRef and silently review the whole artifact instead of
// the delta, which makes args.baseRef look functional while doing nothing.
const REF_SCOPE_MANDATE = !(REVIEW_REF || BASE_REF)
  ? ''
  : '\n\n## The refs that bound this review\n' +
    (REVIEW_REF ? 'The change under review is at ref: ' + REVIEW_REF + '.\n' : '') +
    (BASE_REF ? 'Its already-reviewed baseline is: ' + BASE_REF + '.\n' : '') +
    (REVIEW_REF && BASE_REF
      ? 'Scope your review to `git diff ' + BASE_REF + ' ' + REVIEW_REF + '`. ' +
        'Anything outside that diff is context you may read, not the change ' +
        'under review.\n'
      : '')

// Appended to EVERY agent prompt in this workflow. These agents run in the
// user's real working tree, which may hold uncommitted work with no backup.
//
// This exists because a generic "report, don't fix" instruction is not enough:
// an agent trying to compare before/after behaviour reaches for
// `git checkout <file>` and does not classify that as "editing code" — it reads
// as "look at the previous version". It silently reverted a file holding
// uncommitted work, and the loss was noticed an hour later by accident. So the
// destructive commands are named, and the safe substitute is named with them.
const READ_ONLY_MANDATE =
  '\n\n## You are READ-ONLY (non-negotiable)\n' +
  'You are reviewing a working tree that may contain UNCOMMITTED work with no ' +
  'backup. Anything you revert is gone permanently.\n' +
  'NEVER run: git checkout, git restore, git stash, git reset, git clean, ' +
  'git apply, git revert, or any other command that writes to the working tree. ' +
  'Do not create, edit, move, or delete files. Do not run formatters, linters ' +
  'with --fix, codemods, or test runs that rewrite fixtures/snapshots.\n' +
  'To read a different version of a file, use `git show <ref>:<path>` — it ' +
  'writes nothing. To see what changed, use `git diff` / `git log -p`.\n' +
  'SUBMODULES ARE OFF LIMITS ENTIRELY. Never create, move, delete, or symlink ' +
  'anything inside a git submodule, and never change what commit one points at. ' +
  'A submodule is usually a pinned dependency (a spec, a vendored library) that ' +
  'the host repo treats as read-only, and worktree isolation does NOT sandbox ' +
  'it — a write there lands in the real checkout. This has happened: an agent ' +
  'left a symlink pointing a submodule directory at itself, which makes every ' +
  'later tree walk recurse forever. Read submodule files, write nothing.\n' +
  'If verifying a claim seems to REQUIRE mutating the tree, do not do it: ' +
  'lower your confidence, say in the finding what you could not verify and why, ' +
  'and move on. An honestly-hedged finding is worth far more than a destroyed ' +
  'working tree.' +
  // Folded in here rather than appended at each agent() call: every prompt in
  // this workflow already ends with READ_ONLY_MANDATE, so these reach all of
  // them (lenses, merge, verify) with no call site to keep in sync.
  // WORKTREE_REF_MANDATE is empty when isolation is off, where the working copy
  // IS the reviewed state; REF_SCOPE_MANDATE is empty when no refs were passed.
  REF_SCOPE_MANDATE +
  WORKTREE_REF_MANDATE

// Each lens is a distinct adversarial mandate. Run as separate agents so the
// perspectives stay independent. Add lenses (security, performance) by extending
// this list; the rest of the script is lens-count agnostic.
const LENSES = [
  {
    key: 'concurrency',
    brief: 'Concurrency & lifecycle',
    applies: ['code'],
    prompt:
      'LENS: CONCURRENCY & LIFECYCLE. For every await/async boundary, thread, ' +
      'background task, and external call in the change, enumerate every way it ' +
      'can fail or be abandoned (timeout, cancellation, client disconnect, ' +
      'shutdown, exception) and determine whether cleanup/rollback/cancellation ' +
      'runs on ALL of them. Watch for exception handlers that miss ' +
      'BaseException-derived cases such as asyncio.CancelledError. Ask what breaks ' +
      'if this runs twice concurrently, or is killed mid-flight.',
  },
  {
    key: 'failure-mode',
    brief: 'Failure-mode & observability',
    applies: ['code'],
    prompt:
      'LENS: FAILURE-MODE & OBSERVABILITY. For each external dependency, determine ' +
      'what happens when it is slow, down, or returns malformed data, and whether ' +
      'those cases are distinguished when they should be. Check whether any failure ' +
      'path can leave the system unable to REPORT the failure (logs, metrics, or ' +
      'traces going dark). Check that retries, queues, and backoff are bounded, and ' +
      'what happens at the bound.',
  },
  {
    key: 'consistency',
    brief: 'Data consistency & transactions',
    applies: ['code'],
    prompt:
      'LENS: DATA CONSISTENCY & TRANSACTIONS. Under this system\'s actual ' +
      'isolation/consistency model, determine what is truly atomic. Verify, do not ' +
      'assume, that any rollback or transaction is operative and not a no-op (for ' +
      'example, under AUTOCOMMIT a mid-loop rollback does nothing). If a multi-step ' +
      'write fails partway, what state is left, and is it recoverable, corrupt, or ' +
      'silently wrong? Flag read-then-write races (TOCTOU) and any detection of ' +
      'them that is being accidentally suppressed.',
  },
  {
    key: 'spec-consistency',
    brief: 'Spec consistency & implementation parity',
    applies: ['spec'],
    prompt:
      'LENS: SPEC CONSISTENCY & IMPLEMENTATION PARITY. The defect you are hunting ' +
      'is: TWO COMPETENT IMPLEMENTERS READ THIS AND BUILD INCOMPATIBLE THINGS. ' +
      'That is the bar — not "is it well written". Look for: (1) two sections that ' +
      'contradict each other, or a section that contradicts an example, a schema, a ' +
      'table, or the reference implementation; (2) a term defined in one place and ' +
      'used with a different meaning elsewhere, or used before it is defined; ' +
      '(3) dangling references — a link, section number, field, error code, or ' +
      'capability named but never defined, or defined but never reachable; ' +
      '(4) examples that would FAIL the schema/grammar they are illustrating — ' +
      'check them literally, field by field, do not skim; (5) drift between the ' +
      'spec and any reference implementation or SDK in the repo: a documented field ' +
      'the code does not emit, a code path the spec does not describe, defaults that ' +
      'disagree; (6) version/changelog skew — behaviour described as current that a ' +
      'changelog says changed; (7) under-specified behaviour at boundaries: absent ' +
      'field vs null vs empty, ordering, duplicates, case sensitivity, unicode, ' +
      'time zones, size limits, and what a conforming implementation must do when a ' +
      'limit is exceeded. For each finding, state the two divergent readings ' +
      'explicitly — "implementer A concludes X, implementer B concludes Y" — because ' +
      'that is what makes it a defect rather than a stylistic preference. Most real ' +
      'findings here have NO runtime reproduction; that does not make them unreal.',
  },
  {
    key: 'normative-language',
    brief: 'Normative language & conformance',
    applies: ['spec'],
    prompt:
      'LENS: NORMATIVE LANGUAGE & CONFORMANCE (RFC 2119 / RFC 8174). Audit every ' +
      'requirement for whether its OBLIGATION LEVEL is unambiguous and testable. ' +
      'Look for: (1) a real requirement stated in bare prose ("the server returns ' +
      '409") with no MUST/SHOULD/MAY — is it mandatory or descriptive? An ' +
      'implementer cannot tell, and a conformance test cannot be written; ' +
      '(2) keyword misuse: MUST where the spec cannot enforce or verify it, SHOULD ' +
      'where interop actually breaks if ignored (that is a MUST), MAY for behaviour ' +
      'other requirements depend on (that is not optional); (3) lowercase ' +
      '"should"/"must"/"may" used in a normative sentence — RFC 8174 makes case ' +
      'significant, and mixed usage in one document is itself the defect; ' +
      '(4) requirements with no ACTOR — who must do this: client, server, ' +
      'intermediary, all of them? (5) contradictory obligation levels: the same ' +
      'behaviour MUST in one section and SHOULD/optional in another; ' +
      '(6) untestable requirements — no observable way to tell a conforming from a ' +
      'non-conforming implementation; (7) MUST NOT / SHOULD NOT stated without the ' +
      'consequence or the required fallback; (8) whether the document declares its ' +
      'RFC 2119/8174 conformance boilerplate at all before relying on the keywords. ' +
      'For each finding, name the specific implementation choice left open and the ' +
      'interop failure it produces.',
  },
  {
    // Deliberately UNTAGGED, so it runs for every targetKind. A skipped security
    // lens reads as "no security findings" when it means "nobody looked", and
    // specs have their own security defects (under-specified auth, optional
    // controls that should be mandatory). Cheap insurance relative to the cost of
    // one missed credential leak.
    key: 'security',
    brief: 'Input trust & security',
    prompt:
      'LENS: INPUT TRUST & SECURITY. Trace TRUST BOUNDARIES, not just code. ' +
      'FOR CODE: (1) Where does untrusted data enter, and is it validated AT the ' +
      'boundary rather than deep inside — or validated somewhere it cannot help ' +
      '(against values the schema already precludes) while absent where it is ' +
      'actually needed? (2) Injection reachable from untrusted input: SQL, shell, ' +
      'template, path traversal, deserialization, SSRF, open redirect. (3) ' +
      'Authorization: a missing check, a check on the wrong object (IDOR), a check ' +
      'that runs after the side effect, or a confused deputy where a privileged ' +
      'component acts on an unprivileged caller\'s behalf. (4) SECRET AND PII ' +
      'LEAKAGE — check every egress, not just the obvious one: log lines, ' +
      'exception messages, TRACEBACKS THAT RENDER FRAME LOCALS, telemetry and span ' +
      'attributes, URLs and query strings, generated reports/CSVs, error responses, ' +
      'crash dumps, and test output. A redaction that covers ONE surface while the ' +
      'same secret stays reachable through another is a real defect, and the ' +
      'accompanying claim that it is "masked" makes it worse, not better — verify ' +
      'the claim against every surface before accepting it. (5) Credential ' +
      'handling: hardcoded values, a config typo or absent value that silently ' +
      'falls back to an ambient PRODUCTION credential, a "dry run" or test path ' +
      'that still reaches a real system, weak randomness for anything ' +
      'security-bearing, non-constant-time comparison of secrets. ' +
      'FOR A SPEC: does it leave a security-critical decision to the implementer — ' +
      'authentication, authorization, replay/nonce/expiry, token lifetime and ' +
      'revocation, rate limiting, or error responses that let an attacker ' +
      'enumerate what exists? Is a control that interop genuinely depends on ' +
      'marked MAY or SHOULD when it needs to be MUST? ' +
      'For each finding, name the attacker, what they control, and what they get. ' +
      'A finding you cannot phrase that way is probably hygiene, not a ' +
      'vulnerability — say so and rank it accordingly.',
  },
  {
    key: 'whats-missing',
    brief: "What's-missing critic",
    prompt:
      'LENS: WHAT IS MISSING. Name what the change does NOT handle but should. ' +
      'Find any claim in a docstring, comment, or name that is unverified or false. ' +
      'Identify untested cases and silently-assumed invariants. Report the absent ' +
      'thing, not the present one.\n\n' +
      'ENUMERATE THE SPELLINGS. When the change adds a rule, check, warning, or ' +
      'validation keyed on configuration or API shape, do not stop at the one ' +
      'spelling the code tests. Enumerate EVERY distinct way a caller can express ' +
      'the condition the rule is meant to catch, then check each against the ' +
      'implementation. A rule that fires on one spelling and silently misses an ' +
      'equivalent one is a false negative, and it is worse when the missed ' +
      'spelling is the more idiomatic or the DEFAULT one. Same for the inverse: an ' +
      'over-broad predicate that fires on a spelling which is not actually the ' +
      'hazard. Concretely: alternative parameter sets that reach the same state, ' +
      'a scalar pair vs a map that encode the same relation, positional vs keyword ' +
      'forms, an optional field whose absence changes meaning, and any mode switch ' +
      '(mode A vs mode B) where the rule was written with only one mode in mind. ' +
      'This has caught real defects that a per-hunk read missed twice over.',
  },
]

// A lens with no `applies` is kind-agnostic and always runs (the what's-missing
// critic is useful against code and prose alike). Otherwise it runs only when its
// kind matches, or when the caller left targetKind as 'any'.
const activeLenses = LENSES.filter(
  (lens) => targetKind === 'any' || !lens.applies || lens.applies.indexOf(targetKind) !== -1
)

const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['summary', 'file', 'line', 'failure_scenario', 'severity', 'category'],
        properties: {
          summary: { type: 'string', description: 'One-sentence statement of the defect' },
          file: { type: 'string', description: 'Repo-relative path' },
          line: { type: 'integer', description: '1-indexed line the finding anchors to' },
          failure_scenario: {
            type: 'string',
            description: 'Concrete inputs/state -> wrong output/crash',
          },
          severity: { type: 'string', enum: ['blocker', 'should', 'nit'] },
          category: { type: 'string', description: 'Short kebab-case slug of the defect type' },
          suggested_fix: { type: 'string' },
        },
      },
    },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['real', 'reason'],
  properties: {
    real: { type: 'boolean', description: 'True if the finding survives this refutation angle' },
    reason: { type: 'string', description: 'Why it survives or is refuted' },
  },
}

// Diverse refutation angles. A blocker/should is judged by all three and needs a
// majority; a nit is judged by claim-true and regress and needs both. Either way
// the threshold counts only verifiers that returned a verdict — see the tally.
const ANGLES = [
  {
    key: 'reproduce',
    ask: 'Reproduce this finding concretely. For a runtime bug: construct the input/state that triggers it — if you cannot, it is likely not real. For a spec/docs/config/prose target: most real defects have NO triggering input, so "reproduce" means show concretely how the artifact misleads a reader, makes two conforming implementations diverge, contradicts another section, or states something false. Do NOT mark real=false merely because there is no runtime trigger.',
  },
  {
    key: 'regress',
    ask: 'Would the implied fix actually resolve this without regressing something else? If the fix is wrong or unnecessary, the finding is not actionable. If no fix was proposed, judge whether ANY fix could resolve it; an unclear, multi-option or trivially small fix is a severity judgement, not grounds for real=false.',
  },
  {
    key: 'claim-true',
    ask: 'Is the underlying claim even true, under a PLAIN reading, against the actual code/spec/docs (not general intuition, and not the most charitable interpretation)? A claim that is false or a reference that is ambiguous under a plain reading is a real defect even if a generous reading exists.',
  },
]

// --- Review ---
// Barrier: run all lenses in parallel and collect every raw finding before
// merging. The barrier is justified — semantic dedupe needs the full result set.
// Each lens returns at most its 6 highest-severity findings to cap the blast
// radius and force prioritization.
phase('Review')
// A refused ref silently disables every check that depends on it, so it is said
// out loud before the fan-out rather than inferred later from a thin review.
if (ISOLATE && !REVIEW_REF && !REVIEW_REF_REJECTED) {
  log(
    'WARNING: isolate is on but no reviewRef was passed. Every agent is running in ' +
    'a worktree cut from the DEFAULT BRANCH, which does not contain the change — ' +
    'they are reviewing pre-change files. Findings from this run are unreliable ' +
    'unless the change was supplied in full via args.context.'
  )
}

if (REVIEW_REF_REJECTED || BASE_REF_REJECTED) {
  log(
    'WARNING: ' +
      (REVIEW_REF_REJECTED ? 'reviewRef ' : '') +
      (REVIEW_REF_REJECTED && BASE_REF_REJECTED ? 'and ' : '') +
      (BASE_REF_REJECTED ? 'baseRef ' : '') +
      'was supplied but refused as unsafe to interpolate into a command (a ref ' +
      'must start alphanumeric and contain no ".."). The checks that depend on ' +
      'it are DISABLED for this run' +
      (ISOLATE
        ? ', and with isolation on the agents are reading a worktree cut from ' +
          'the default branch — treat this result as unreliable.'
        : '.')
  )
}

log(
  'Adversarial review of ' +
    scope +
    ' — ' +
    activeLenses.length +
    ' of ' +
    LENSES.length +
    ' lenses (targetKind=' +
    targetKind +
    ': ' +
    activeLenses.map((l) => l.key).join(', ') +
    ')'
)
if (activeLenses.length < LENSES.length) {
  // Say what was skipped. A silently narrowed lens set reads as "nothing found
  // in that dimension" when it actually means "that dimension was never looked at".
  log(
    'Skipped for targetKind=' +
      targetKind +
      ': ' +
      LENSES.filter((l) => activeLenses.indexOf(l) === -1)
        .map((l) => l.key)
        .join(', ')
  )
}

const lensResults = await parallel(
  activeLenses.map((lens) => () =>
    agent(
      lens.prompt +
        '\n\n## Scope\n' +
        scope +
        '\n\n## Context\n' +
        context +
        '\n\n## Operational invariants (treat clear violations as blockers)\n' +
        invariants +
        '\n\nReview adversarially: do NOT describe the code, find what breaks it. ' +
        'Assign each finding a severity of blocker, should, or nit. Return at most ' +
        'your 6 highest-severity findings — prioritize, do not pad. An empty ' +
        'findings array is a valid, honest answer.' +
        READ_ONLY_MANDATE,
      {
        label: 'lens:' + lens.key,
        phase: 'Review',
        schema: FINDINGS_SCHEMA,
        isolation: ISOLATE ? 'worktree' : undefined,
      }
    )
  )
)

const rawFindings = lensResults.filter(Boolean).flatMap((r) => (r && r.findings) || [])

if (!rawFindings.length) {
  log('No findings surfaced.')
  return { scope: scope, counts: { blocker: 0, should: 0, nit: 0 }, findings: [] }
}

// --- Merge (before verify) ---
// One agent clusters the raw findings by root cause and emits a single canonical
// finding per distinct defect. A string key (file:line:category) is too brittle:
// independent lenses report the SAME defect at slightly different lines and with
// different category slugs. Running this BEFORE verify is the key cost lever —
// verify then runs on distinct defects, not once per duplicate. Runs at low
// effort; clustering is a bounded task. Falls back to the raw findings if the
// merge yields nothing.
phase('Merge')
let distinct = rawFindings
if (rawFindings.length > 1) {
  const merged = await agent(
    'You are the merge stage of a multi-lens code review. Independent lenses ' +
      'reviewed the same code and produced the findings below; several likely ' +
      'describe the SAME underlying defect from different angles (different line ' +
      'numbers, different category slugs, different wording). Cluster findings that ' +
      'share a root cause and emit exactly ONE canonical finding per distinct ' +
      'defect: keep the clearest summary, the most precise file and line, the ' +
      'HIGHEST severity present in the cluster, and the strongest failure_scenario ' +
      'and suggested_fix. Do not drop any distinct defect, and do not merge ' +
      'findings that are genuinely different bugs. Findings:\n\n' +
      JSON.stringify(rawFindings, null, 2) +
      READ_ONLY_MANDATE,
    {
      label: 'merge',
      phase: 'Merge',
      schema: FINDINGS_SCHEMA,
      effort: 'low',
      isolation: ISOLATE ? 'worktree' : undefined,
    }
  )
  if (merged && merged.findings && merged.findings.length) {
    distinct = merged.findings
  }
}

// --- Verify (tiered) ---
// Verify each DISTINCT finding by refutation: the full 3-angle panel for
// blocker/should, two for a nit (claim-true and regress). Verify agents run at low
// effort — refutation is a bounded check, not open-ended discovery. A blocker or
// should survives on a majority of the verifiers that RETURNED A VERDICT; a nit
// needs all of them. A panel where nobody answered is unverified, not refuted.
phase('Verify')
const verified = await parallel(
  distinct.map((f) => () => {
    // A nit is a claim about correctness (consistency / accuracy / parity), not
    // a runtime failure — judge it by 'claim-true' (is it actually true?), NOT by
    // 'reproduce', which a prose/docs nit can never satisfy and which would auto-refute it.
    //
    // 'regress' as well, so a nit is not decided by a single verifier. One angle
    // is close to no verification at all, and a lens capped at `should` pushes
    // most of its output into this tier.
    const angles = f.severity === 'nit' ? [ANGLES[2], ANGLES[1]] : ANGLES
    // Threshold is computed after the votes are in, from the votes actually cast
    // — see the tally below.
    return parallel(
      angles.map((ang) => () =>
        agent(
          'Adversarially REFUTE this finding via the "' +
            ang.key +
            '" angle.\n\nFinding: ' +
            f.summary +
            '\nLocation: ' +
            f.file +
            ':' +
            f.line +
            '\nFailure scenario: ' +
            f.failure_scenario +
            // Only the `regress` angle judges the fix. Appending this to every
            // angle put "judge whether any fix could resolve this" in front of
            // claim-true, whose whole job is deciding whether the claim is true.
            (ang.key === 'regress' && f.suggested_fix
              ? '\nSuggested fix: ' + f.suggested_fix
              : '') +
            '\n\n' +
            ang.ask +
            '\n\nJudge VALIDITY, not severity: mark real=false ONLY if the finding is factually wrong, ' +
            'describes intended behavior, or its fix regresses/is unnecessary. Do NOT mark real=false ' +
            'merely because the finding is low-severity or has no runtime reproduction — a factually ' +
            'correct but minor finding is REAL (it stays a nit). Default to real=false only when the ' +
            'claim itself is dubious, never when it is merely minor. Return a verdict.' +
            ABSENCE_SEARCH_MANDATE +
            TIP_RECHECK_MANDATE +
            READ_ONLY_MANDATE,
          {
            label: 'verify:' + ang.key + ':' + f.file,
            phase: 'Verify',
            schema: VERDICT_SCHEMA,
            effort: 'low',
            isolation: ISOLATE ? 'worktree' : undefined,
          }
        )
      )
    ).then((votes) => {
      // agent() returns null on a terminal error or a user skip, so `cast` can be
      // smaller than `angles` — or empty.
      const cast = votes.filter(Boolean)
      const survived = cast.filter((v) => v.real).length
      // A nit needs every verifier that answered; blocker/should need a majority
      // of those. This stops a dead agent being counted as a vote against — but
      // it does NOT restore the finding's margin: at two votes a majority is
      // still two, so a degraded panel is a stricter panel. That is why the
      // degradation is carried forward rather than hidden.
      const need = cast.length === 0 ? 0 : f.severity === 'nit' ? cast.length : Math.floor(cast.length / 2) + 1
      const panel = { asked: angles.length, cast: cast.length }
      return {
        finding: f,
        panel: panel,
        // Nobody voted. That is not a refutation.
        unverified: cast.length === 0,
        survives: cast.length > 0 && survived >= need,
        // Kept so a REFUTED finding stays auditable instead of vanishing.
        // A refutation resting on wrong-tree evidence has already killed a
        // real blocker; without the reasoning surfaced, that is invisible.
        votes: cast.map((v) => ({ real: v.real, reason: v.reason })),
      }
    })
  })
)

phase('Synthesize')
const settled = verified.filter(Boolean)
// A finding nobody voted on is neither confirmed nor refuted. Reporting it as
// refuted turned a verify-phase outage into a clean review.
const unverifiedFindings = settled
  .filter((x) => x.unverified)
  .map((x) => ({ ...x.finding, panel: x.panel }))
// Survivors carry their panel, so a blocker confirmed by one surviving verifier
// is not reported identically to one confirmed by three.
const finalFindings = settled
  .filter((x) => x.survives)
  .map((x) => ({ ...x.finding, panel: x.panel }))

// Rank most-severe first.
const order = { blocker: 0, should: 1, nit: 2 }
finalFindings.sort(
  (x, y) =>
    (order[x.severity] === undefined ? 3 : order[x.severity]) -
    (order[y.severity] === undefined ? 3 : order[y.severity])
)

// Reconcile: anything that entered Verify must leave it in exactly one bucket.
// A per-finding task returning null was previously dropped by both filters, so a
// run that lost a blocker to a panel-level failure looked like a clean review.
const lost = distinct.length - settled.length
if (lost > 0) {
  log(
    'WARNING: ' +
      lost +
      ' of ' +
      distinct.length +
      ' findings vanished in the verify phase (panel-level failure). They are ' +
      'neither confirmed nor refuted — the result below is incomplete.'
  )
}

const counts = {
  blocker: finalFindings.filter((f) => f.severity === 'blocker').length,
  should: finalFindings.filter((f) => f.severity === 'should').length,
  nit: finalFindings.filter((f) => f.severity === 'nit').length,
}
// Refuted findings are RETURNED, not dropped. A refutation is itself a
// judgement that can be wrong, and a wrong one is indistinguishable from
// "no such defect" once the finding disappears — that is exactly how a
// confirmed CI-breaking blocker was lost on one run, refuted by three
// agents reading the wrong git ref. Surfacing each refutation's reasoning
// lets the caller spot-check the ones that rest on file contents.
const refutedFindings = settled
  .filter((x) => !x.survives && !x.unverified)
  .map((x) => ({
    summary: x.finding.summary,
    file: x.finding.file,
    line: x.finding.line,
    severity: x.finding.severity,
    refutations: x.votes.filter((v) => !v.real).map((v) => v.reason),
  }))

log(
  'Confirmed ' +
    finalFindings.length +
    ' finding(s): ' +
    counts.blocker +
    ' blocker, ' +
    counts.should +
    ' should, ' +
    counts.nit +
    ' nit' +
    (refutedFindings.length
      ? '; ' + refutedFindings.length + ' refuted (returned for spot-checking)'
      : '') +
    (unverifiedFindings.length
      ? '; ' + unverifiedFindings.length + ' UNVERIFIED (no verifier returned a verdict)'
      : '')
)

return {
  scope: scope,
  counts: counts,
  findings: finalFindings,
  refutedCount: refutedFindings.length,
  refuted: refutedFindings,
  // Neither confirmed nor refuted: no verifier returned a verdict on these. Their
  // own bucket, so a verify-phase outage cannot render as a clean review.
  unverifiedCount: unverifiedFindings.length,
  unverified: unverifiedFindings,
}
