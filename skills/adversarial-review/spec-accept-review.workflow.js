export const meta = {
  name: 'spec-accept-review',
  description: 'Adversarial review of a spec/RFC change (normative prose + conformance fixtures) before tagging or publishing',
  whenToUse: 'Reviewing a spec/RFC change before commit+tag/publish. Assemble context inline first, pass via args.context.',
  phases: [
    { title: 'Lenses', detail: 'independent adversarial passes over the change' },
    { title: 'Merge', detail: 'cluster raw findings into distinct defects before verifying' },
    { title: 'Verify', detail: 'refute each distinct defect on VALIDITY not severity; 3 angles for blocker/should, 1 for nit' },
    { title: 'Synthesize', detail: 'rank survivors; keep refuted-with-reasoning for audit' },
  ],
}

// USAGE: assemble context inline (the diff + new fixtures/examples + unchanged collaborators + today's date),
// then Workflow({ scriptPath: <this file>, args: { scope: '...', context: '<assembled text + file paths>' } }).
// args.context should point the lens agents at the assembled files AND name any load-bearing claims to
// verify against source. args.scope is a short human label.

const SCOPE = (args && args.scope) || 'spec/RFC change under review'
const CONTEXT = (args && args.context) ||
  'No context supplied. Read the uncommitted git diff and any new/changed conformance fixtures or examples, ' +
  'plus the unchanged sections of the spec the change depends on (cross-referenced clauses, tables, and any ' +
  'companion documents it binds to).'

// Sandbox + ref support, kept byte-identical to adversarial-review.workflow.js.
// scripts/validate.sh asserts these constants match across both engines: with no
// import mechanism in the Workflow runtime they must be duplicated, and the two
// have drifted before — twice shipping docs that apologised for the difference.
const ISOLATE = args && args.isolate === true
const SAFE_REF = /^[A-Za-z0-9][A-Za-z0-9._\/~^@{}+-]{0,254}$/
const isSafeRef = (v) => typeof v === 'string' && v !== '' && SAFE_REF.test(v) && v.indexOf('..') === -1
const REVIEW_REF = args && isSafeRef(args.reviewRef) ? args.reviewRef : ''
const BASE_REF = args && isSafeRef(args.baseRef) ? args.baseRef : ''
const REVIEW_REF_REJECTED = !!(args && args.reviewRef) && !REVIEW_REF
const BASE_REF_REJECTED = !!(args && args.baseRef) && !BASE_REF

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

// Appended to EVERY prompt below (both stages build from PREAMBLE, so there is
// no call site to keep in sync).
//
// Without isolation this workflow is the HIGHEST-RISK configuration in the skill:
// it reviews UNCOMMITTED work, in the user's real tree, and there is no undo.
// With args.isolate it runs in throwaway worktrees like the code engine, and the
// warning below is then belt-and-braces rather than the only guard. It is still
// emitted in both modes: a submodule working tree is not sandboxed, and agents
// have been seen acting on the real repo path rather than their worktree.
//
// It exists because a generic "report, don't fix" instruction is not enough: an
// agent comparing before/after reaches for `git checkout <file>` and does not
// classify that as "editing" — it reads as "look at the previous version". That
// silently reverted a file holding uncommitted work, and the loss was noticed an
// hour later by accident. So name the destructive commands, and name the safe
// substitute alongside them.
const READ_ONLY_MANDATE = [
  '',
  '## You are READ-ONLY (non-negotiable)',
  'You are reviewing an UNCOMMITTED diff in the real working tree. There is no backup and no',
  'isolation: anything you revert or overwrite is gone permanently, including the change under review',
  'itself.',
  'NEVER run: git checkout, git restore, git stash, git reset, git clean, git apply, git revert,',
  'or any other command that writes to the working tree. Do not create, edit, move, or delete',
  'files. Do not run formatters or any tool that rewrites fixtures.',
  'To read a different version of a file, use `git show <ref>:<path>` — it writes nothing. To see',
  'what changed, use `git diff` / `git log -p`. Both read the uncommitted state correctly.',
  'If verifying a claim seems to REQUIRE mutating the tree, do not do it: lower your confidence,',
  'say in the finding what you could not verify and why, and move on. An honestly-hedged finding',
  'is worth far more than a destroyed change under review.',
].join('\n')

const PREAMBLE = [
  'You are adversarially reviewing a spec/RFC change about to be git-tagged and released. This is a',
  'normative SPEC artifact: prose specifications and, often, declarative machine-readable conformance',
  'fixtures or worked examples. Where fixtures exist they are the cross-implementation source of truth — a',
  'fixture that can pass wrongly, or pins inconsistent data, is a real defect that freezes into a shipped',
  'contract. Documentation defects (a false claim, a stale cross-reference, a coverage gap vs precedent, a',
  'CHANGELOG date that does not match the tag day) are REAL even though they have no runtime reproduction.',
  '',
  'SCOPE: ' + SCOPE,
  '',
  'CONTEXT:',
  CONTEXT,
  '',
  'Read the diff and collaborators FULLY before forming findings. Verify claims against the actual spec text',
  "and the template/precedent fixtures — do not trust the change's own prose.",
  READ_ONLY_MANDATE,
  // REF_SCOPE_MANDATE names the review's boundaries in BOTH modes; the other
  // three are self-gating and collapse to '' when their precondition is absent.
  REF_SCOPE_MANDATE,
  WORKTREE_REF_MANDATE,
].join('\n')

const FINDING_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['findings'],
  properties: { findings: { type: 'array', items: {
    type: 'object', additionalProperties: false,
    required: ['title', 'severity', 'location', 'failure', 'why_real'],
    properties: {
      title: { type: 'string' }, severity: { type: 'string', enum: ['blocker', 'should', 'nit'] },
      location: { type: 'string' }, failure: { type: 'string' }, why_real: { type: 'string' },
      fix: { type: 'string' },
    } } } },
}

// `adjusted_severity` exists so PARTIAL means something. Without it a verifier
// could say "the core reproduces but the severity is overstated" and the finding
// still printed at its original severity, because synthesis treated CONFIRMED and
// PARTIAL identically. Now a downgrade is applied.
const VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['verdict', 'reasoning'],
  properties: {
    verdict: { type: 'string', enum: ['CONFIRMED', 'REFUTED', 'PARTIAL'] },
    reasoning: { type: 'string' },
    adjusted_severity: { type: 'string', enum: ['blocker', 'should', 'nit'] },
  },
}

// One canonical finding per distinct defect, for the merge stage.
// `lenses` is REQUIRED: a merged finding can never carry the singular `lens`
// (not a permitted property here), so an omitted `lenses` makes the synthesis
// fallback collapse to [] and the convergence signal vanishes silently.
const MERGE_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['findings'],
  properties: { findings: { type: 'array', items: {
    type: 'object', additionalProperties: false,
    required: ['title', 'severity', 'location', 'failure', 'why_real', 'lenses'],
    properties: {
      title: { type: 'string' }, severity: { type: 'string', enum: ['blocker', 'should', 'nit'] },
      location: { type: 'string' }, failure: { type: 'string' }, why_real: { type: 'string' },
      fix: { type: 'string' },
      // Which lenses independently found this. Convergence is signal worth keeping:
      // three lenses arriving at one defect is stronger evidence than one.
      lenses: { type: 'array', items: { type: 'string' } },
    } } } },
}

// The three refutation angles, ported from the main adversarial-review workflow.
// A nit is judged by 'claim-true' alone: it is a claim about correctness, and
// 'reproduce' would auto-refute a prose defect that can never have a runtime trigger.
const ANGLES = [
  { key: 'reproduce', ask:
    'Reproduce this finding concretely. This is a SPEC repo, so most real defects have NO triggering input: ' +
    '"reproduce" means show concretely how the artifact misleads a reader, makes two conforming implementations ' +
    'diverge, contradicts another section, or states something false. Do NOT refute merely because there is no ' +
    'runtime trigger.' },
  { key: 'regress', ask:
    'Would the implied fix actually resolve this without regressing something else, and is it necessary at all? ' +
    'If the fix is wrong, unnecessary, or would break a sibling rule or a shipped fixture, the finding is not ' +
    'actionable as stated.' },
  { key: 'claim-true', ask:
    'Is the underlying claim even true, under a PLAIN reading, against the actual spec text and fixtures (not ' +
    'general intuition, and not the most charitable interpretation)? A claim that is false, or a reference that ' +
    'is ambiguous under a plain reading, is a real defect even if a generous reading exists.' },
]

// Generic spec-review lenses. Each hunts for a failure, not a summary.
const LENSES = [
  { key: 'fixture-consistency', prompt: [
    'LENS 1 — Fixture / example consistency & self-testing. TRY TO BREAK every new/changed conformance',
    'fixture or worked example.',
    '(a) Internal consistency: does every asserted value match its inputs (derived figures, ids, raw and',
    'typed fields)? Any mismatch vs the template/precedent fixture it copies (wire shape, headers,',
    'absent/required keys, construction block)? Verify arithmetic and structural equality by reading the',
    'fixture.',
    '(b) Can a fixture PASS the WRONG way — a non-conforming implementation that still passes? Are the',
    'discriminating assertions load-bearing (do the pinned values actually differ from what a wrong impl',
    'would produce)?',
    '(c) Does a positive value coincide with something an impl could return by accident (e.g. a sum that',
    'equals the input count)? Empty result is valid.',
  ].join('\n') },
  { key: 'spec-reconciliation', prompt: [
    'LENS 2 — Spec consistency & reconciliation. TRY TO BREAK the normative spec edits.',
    '(a) Is the new rule stated consistently everywhere it appears (all affected rows/sections/tables)? Does',
    'it CONTRADICT another section, an earlier proposal it builds on, or a companion surface it forgot to',
    'update? Grep for sections still asserting the OLD behavior (the reconcile-contradicted-sections',
    'discipline).',
    '(b) Cross-reference claims: does "aligns with §X" / "matches clause N" actually hold when you READ §X /',
    'clause N? A false specific cross-reference (claiming §X says one thing when §X says another) is a real nit.',
    '(c) RFC 2119 / 8174: does new prescriptive behavior use MUST / MUST NOT / SHOULD correctly, or a bold',
    '"not" / "no" that should be MUST NOT? Confirm the document actually invokes the RFC 2119 keywords',
    'before relying on them. Empty result is valid.',
  ].join('\n') },
  { key: 'design-and-claims', prompt: [
    'LENS 3 — Design soundness, cross-implementation derivability, and claim truth. TRY TO BREAK the design',
    'and its stated rationale.',
    '(a) Would a fresh, independent implementer DERIVE the right behavior from the spec text alone, or does a',
    'fixture rely on an undocumented harness affordance / tribal knowledge? Is any new directive scoped',
    'correctly (applied to every surface that needs it, and none that it does not)?',
    '(b) Is every rationale claim TRUE under a plain reading — the divergence-from-prior-proposal',
    'justification, the "first / second / Nth" ordinals, the precedent citations? Verify each against source.',
    '(c) Is a design decision (reject vs merge, null vs present, fail-loud vs degrade) internally consistent',
    'with sibling rules and any pending / related work? Empty result is valid.',
  ].join('\n') },
  { key: 'whats-missing', prompt: [
    'LENS 4 — The "what is missing" critic. Name what the change does NOT handle, or any FALSE / unverified',
    'claim.',
    '(a) Coverage vs precedent: if the rule binds MULTIPLE surfaces (two operations, response AND event), is',
    'each tested — AND does the precedent proposal actually test both (do not demand more coverage than',
    'precedent)?',
    '(b) Mechanical accuracy: fixture / section counts (CHANGELOG vs README vs actual), the CHANGELOG date vs',
    'TODAY / the tag day, history-entry accuracy, any index or registry the change should flip, any open',
    'question it makes salient but does not track.',
    '(c) A behavior the new prose MANDATES but NO fixture pins. (d) Any false claim in a fixture header or a',
    'companion document. Empty result is valid.',
  ].join('\n') },
]

// --- Lenses ---
// A BARRIER (parallel, not pipeline): the merge stage below needs the full result
// set to cluster across lenses. Each lens is wrapped so a dead lens is recorded
// rather than silently dropped: a transient API error once killed the
// spec-reconciliation lens mid-response, it contributed zero findings, and the
// result payload gave no hint — which reads exactly like "that lens found
// nothing." One retry, then record the failure.
phase('Lenses')
const lensFailures = []
async function runLens(lens, attempt) {
  try {
    const r = await agent(PREAMBLE + '\n\n' + lens.prompt,
      { label: 'lens:' + lens.key + (attempt > 1 ? ' (retry)' : ''), phase: 'Lenses', isolation: ISOLATE ? 'worktree' : undefined, schema: FINDING_SCHEMA })
    if (!r) throw new Error('no result')
    return (r.findings || []).map(f => ({ ...f, lens: lens.key }))
  } catch (e) {
    if (attempt < 2) {
      log('lens ' + lens.key + ' failed, retrying once')
      return runLens(lens, attempt + 1)
    }
    lensFailures.push(lens.key)
    log('LENS COVERAGE LOST: ' + lens.key + ' failed twice; its mandate went unexamined')
    return []
  }
}
const rawFindings = (await parallel(LENSES.map(lens => () => runLens(lens, 1)))).filter(Boolean).flat()
log('lenses raised ' + rawFindings.length + ' raw findings' +
  (lensFailures.length ? ' (' + lensFailures.length + ' lens(es) FAILED)' : ''))

// --- Merge ---
// Independent lenses converge on the same defect from different angles, so raw
// counts overstate the work: one run reported the same blocker three times and the
// same stale header three times, 24 raw for ~17 distinct. Clustering BEFORE verify
// is also the cost lever, since verify then runs per distinct defect rather than
// per duplicate. Low effort: clustering is bounded. Falls back to raw on failure.
phase('Merge')
let distinct = rawFindings
if (rawFindings.length > 1) {
  const merged = await agent(
    PREAMBLE +
    '\n\nYou are the MERGE stage of a multi-lens spec review. The lenses below reviewed the same change ' +
    'and several findings likely describe the SAME underlying defect from different angles (different line ' +
    'numbers, different wording, different lens). Cluster findings sharing a root cause and emit exactly ONE ' +
    'canonical finding per distinct defect: keep the clearest title, the most precise location, the HIGHEST ' +
    'severity in the cluster, the strongest failure and why_real, and list every lens that found it in ' +
    '`lenses`. Do NOT drop any distinct defect, and do NOT merge findings that are genuinely different defects ' +
    '(same file or section is NOT enough — they must share a root cause). Findings:\n\n' +
    JSON.stringify(rawFindings, null, 2),
    { label: 'merge', phase: 'Merge', isolation: ISOLATE ? 'worktree' : undefined, schema: MERGE_SCHEMA, effort: 'low' }
  )
  if (merged && merged.findings && merged.findings.length) distinct = merged.findings
}
log('merged to ' + distinct.length + ' distinct defect(s)')

// --- Verify (tiered, multi-angle) ---
// Full 3-angle panel for blocker/should, single claim-true verifier for a nit (a
// wrong nit is cheap; a wrongly-confirmed blocker is not). Survives on a majority
// of the angles that judged it.
phase('Verify')
const verified = await parallel(distinct.map(f => () => {
  // A nit is judged by claim-true and regress, never by reproduce, which a prose
  // nit can never satisfy and which would auto-refute it. The threshold is
  // computed after the votes are in — see the tally.
  const angles = f.severity === 'nit' ? [ANGLES[2], ANGLES[1]] : ANGLES
  return parallel(angles.map(ang => () =>
    agent(
      PREAMBLE +
      '\n\nADVERSARIAL VERIFICATION via the "' + ang.key + '" angle.\n' +
      ang.ask +
      '\n\nThe finding:\nTITLE: ' + f.title + '\nSEVERITY: ' + f.severity + '\nLOCATION: ' + f.location +
      '\nFAILURE: ' + f.failure + '\nWHY REAL: ' + f.why_real + '\nPROPOSED FIX: ' + (f.fix || '(none)') +
      '\n\nRead the actual files and judge VALIDITY, not severity. REFUTE (verdict REFUTED) ONLY if the finding ' +
      'is FACTUALLY WRONG, describes INTENDED behavior, its fix would REGRESS or is unnecessary, OR it is ' +
      'factually true but NOT A DEFECT AT ALL — nothing misleads a reader, no two conforming implementations ' +
      'diverge, nothing contradicts another section, and nothing is false (an observation about style, symmetry, ' +
      'or how many entries a proposal happens to have is not a defect). Do NOT refute a factually-correct ' +
      'finding merely because it is low-severity or has no runtime reproduction: a true-but-minor finding is ' +
      'CONFIRMED as a nit. Do NOT refute via a charitable reading when a plain reading is false. Do NOT refute ' +
      'on "I looked and it is not there" without confirming you read the reviewed state of the file. ' +
      'CONFIRM if the claim holds under a plain reading. PARTIAL if the core holds but the framing or severity ' +
      'is overstated, and then set `adjusted_severity` to what you actually believe. Cite the specific ' +
      'spec/fixture text you relied on.' +
      ABSENCE_SEARCH_MANDATE +
      TIP_RECHECK_MANDATE,
      { label: 'verify:' + ang.key + ':' + String(f.location || '').slice(0, 40), phase: 'Verify', isolation: ISOLATE ? 'worktree' : undefined, schema: VERDICT_SCHEMA, effort: 'low' }
    ).then(v =>
      // A null agent (terminal error, user skip) ABSTAINS. Coercing it to
      // REFUTED made a dead verifier an active vote AGAINST — and on the
      // one-angle nit panel this engine used to run, that killed the finding
      // outright. The `votes.filter(Boolean)` below was a no-op while this
      // returned an object unconditionally.
      v
        ? { angle: ang.key, verdict: v.verdict, reasoning: v.reasoning || '', adjusted: v.adjusted_severity }
        : null
    )
  )).then(votes => {
    const cast = votes.filter(Boolean)
    const kept = cast.filter(v => v.verdict === 'CONFIRMED' || v.verdict === 'PARTIAL')
    // PARTIAL now bites: if any surviving angle downgraded, take the LOWEST
    // severity any of them argued for, so an overstated blocker lands as it should.
    const rank = { blocker: 0, should: 1, nit: 2 }
    let severity = f.severity
    for (const v of kept) {
      if (v.verdict === 'PARTIAL' && v.adjusted && (rank[v.adjusted] ?? 3) > (rank[severity] ?? 3)) {
        severity = v.adjusted
      }
    }
    // Nits need every verifier that answered; blocker/should need a majority of
    // those. Computed from cast, so an abstention is not a vote against.
    const need = cast.length === 0 ? 0 : f.severity === 'nit' ? cast.length : Math.floor(cast.length / 2) + 1
    return {
      finding: { ...f, severity, severity_as_raised: f.severity },
      panel: { asked: angles.length, cast: cast.length },
      // Nobody returned a verdict. That is not a refutation.
      unverified: cast.length === 0,
      survives: cast.length > 0 && kept.length >= need,
      // Votes are surfaced WITH reasoning so the caller can audit a wrong
      // refutation, which is the recurring failure mode, instead of re-deriving it.
      votes: cast.map(v => ({ angle: v.angle, verdict: v.verdict, reasoning: v.reasoning })),
    }
  })
}))

phase('Synthesize')
const judged = verified.filter(Boolean)
const survivors = judged.filter(x => x.survives).map(x => ({ ...x.finding, votes: x.votes, panel: x.panel }))
// Neither confirmed nor refuted: no verifier returned a verdict. Its own bucket,
// so a verify-phase outage cannot render as a clean review.
const unjudged = judged.filter(x => x.unverified).map(x => ({ ...x.finding, panel: x.panel }))
const order = { blocker: 0, should: 1, nit: 2 }
survivors.sort((a, b) => (order[a.severity] ?? 3) - (order[b.severity] ?? 3))
log(
  distinct.length + ' distinct defect(s) judged; ' + survivors.length + ' survived verification' +
  (unjudged.length ? '; ' + unjudged.length + ' UNVERIFIED (no verifier returned a verdict)' : '')
)

return {
  raw_raised: rawFindings.length,
  distinct: distinct.length,
  survived: survivors.length,
  by_severity: {
    blocker: survivors.filter(f => f.severity === 'blocker').length,
    should: survivors.filter(f => f.severity === 'should').length,
    nit: survivors.filter(f => f.severity === 'nit').length,
  },
  // Non-empty means part of the mandate went unexamined. Treat the survivor list as
  // a floor, not a ceiling, and say so when reporting: a silent lens death once cost
  // a whole lens's coverage on a run whose payload looked healthy.
  lenses_failed: lensFailures,
  findings: survivors.map(f => ({
    severity: f.severity,
    // Present only when a PARTIAL verdict moved it, so a downgrade is visible rather than implicit.
    severity_as_raised: f.severity_as_raised !== f.severity ? f.severity_as_raised : undefined,
    title: f.title, location: f.location, failure: f.failure, why_real: f.why_real, fix: f.fix,
    // Which lenses independently converged on it. Multiple lenses is stronger evidence.
    lenses: f.lenses || (f.lens ? [f.lens] : []),
    votes: f.votes,
  })),
  // Refuted defects are returned WITH every angle's reasoning so the caller can audit a
  // wrong refutation, the recurring failure mode, instead of re-deriving from scratch.
  unverified_count: unjudged.length,
  unverified: unjudged,
  refuted: judged.filter(x => !x.survives && !x.unverified).map(x => ({
    title: x.finding.title, severity: x.finding.severity,
    lenses: x.finding.lenses || (x.finding.lens ? [x.finding.lens] : []),
    votes: x.votes,
  })),
}
