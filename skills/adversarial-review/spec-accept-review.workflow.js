export const meta = {
  name: 'spec-accept-review',
  description: 'Adversarial review of a spec/RFC change (normative prose + conformance fixtures) before tagging or publishing',
  whenToUse: 'Reviewing a spec/RFC change before commit+tag/publish. Assemble context inline first, pass via args.context.',
  phases: [
    { title: 'Lenses', detail: 'independent adversarial passes over the change' },
    { title: 'Verify', detail: 'refute each finding on VALIDITY not severity' },
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

// Appended to EVERY prompt below (both stages build from PREAMBLE, so there is
// no call site to keep in sync).
//
// This workflow is the HIGHEST-RISK configuration in the skill: it reviews
// UNCOMMITTED work, in the user's real tree, with no worktree isolation
// available (a worktree can only hold committed work). There is no undo.
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

const VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['verdict', 'reasoning'],
  properties: { verdict: { type: 'string', enum: ['CONFIRMED', 'REFUTED', 'PARTIAL'] }, reasoning: { type: 'string' } },
}

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

phase('Lenses')
const raw = await pipeline(
  LENSES,
  (lens) => agent(PREAMBLE + '\n\n' + lens.prompt, { label: 'lens:' + lens.key, phase: 'Lenses', schema: FINDING_SCHEMA })
    .then(r => (r?.findings || []).map(f => ({ ...f, lens: lens.key }))),
  (findings) => parallel((findings || []).map(f => () =>
    agent(
      PREAMBLE +
      '\n\nADVERSARIAL VERIFICATION. A prior lens raised this finding:\n' +
      'TITLE: ' + f.title + '\nSEVERITY: ' + f.severity + '\nLOCATION: ' + f.location +
      '\nFAILURE: ' + f.failure + '\nWHY REAL: ' + f.why_real + '\nPROPOSED FIX: ' + (f.fix || '(none)') +
      '\n\nRead the actual files and judge it. REFUTE (verdict REFUTED) ONLY if the finding is FACTUALLY WRONG, ' +
      'describes INTENDED behavior, or its fix would REGRESS / is unnecessary. Do NOT refute a factually-correct ' +
      'finding merely because it is low-severity or has no runtime reproduction — for a spec/docs artifact, ' +
      '"reproduction" means showing it misleads a reader, makes two conforming impls diverge, contradicts another ' +
      'section, or is literally false; a true-but-minor finding is CONFIRMED (as a nit), not refuted. Do NOT refute ' +
      'via a charitable reading when a plain reading is false. CONFIRM if the claim holds under a plain reading; ' +
      'PARTIAL if the core reproduces but the framing/severity is overstated. Cite the specific spec/fixture text.',
      { label: 'verify:' + (f.lens || 'x'), phase: 'Verify', schema: VERDICT_SCHEMA }
    ).then(v => ({ ...f, verdict: v?.verdict || 'REFUTED', verify_reasoning: v?.reasoning || '' }))
  ))
)

phase('Synthesize')
const all = raw.flat().filter(Boolean)
const survivors = all.filter(f => f.verdict === 'CONFIRMED' || f.verdict === 'PARTIAL')
const order = { blocker: 0, should: 1, nit: 2 }
survivors.sort((a, b) => (order[a.severity] ?? 3) - (order[b.severity] ?? 3))
log('lenses raised ' + all.length + ' findings; ' + survivors.length + ' survived verification')

return {
  total_raised: all.length,
  survived: survivors.length,
  findings: survivors.map(f => ({ severity: f.severity, verdict: f.verdict, title: f.title, location: f.location,
    failure: f.failure, why_real: f.why_real, fix: f.fix, lens: f.lens, verify_reasoning: f.verify_reasoning })),
  // Refuted findings are returned WITH their reasoning so the caller can audit for wrong refutations
  // (the recurring failure mode) instead of re-deriving from scratch.
  refuted: all.filter(f => f.verdict === 'REFUTED').map(f => ({ title: f.title, lens: f.lens,
    severity: f.severity, refutation: f.verify_reasoning })),
}
