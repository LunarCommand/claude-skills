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
const MERGE_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['findings'],
  properties: { findings: { type: 'array', items: {
    type: 'object', additionalProperties: false,
    required: ['title', 'severity', 'location', 'failure', 'why_real'],
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
      { label: 'lens:' + lens.key + (attempt > 1 ? ' (retry)' : ''), phase: 'Lenses', schema: FINDING_SCHEMA })
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
    { label: 'merge', phase: 'Merge', schema: MERGE_SCHEMA, effort: 'low' }
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
  const angles = f.severity === 'nit' ? [ANGLES[2]] : ANGLES
  const need = Math.ceil(angles.length / 2)
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
      'spec/fixture text you relied on.',
      { label: 'verify:' + ang.key + ':' + String(f.location || '').slice(0, 40), phase: 'Verify', schema: VERDICT_SCHEMA, effort: 'low' }
    ).then(v => ({
      angle: ang.key,
      verdict: v?.verdict || 'REFUTED',
      reasoning: v?.reasoning || '',
      adjusted: v?.adjusted_severity,
    }))
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
    return {
      finding: { ...f, severity, severity_as_raised: f.severity },
      survives: kept.length >= need,
      // Votes are surfaced WITH reasoning so the caller can audit a wrong
      // refutation, which is the recurring failure mode, instead of re-deriving it.
      votes: cast.map(v => ({ angle: v.angle, verdict: v.verdict, reasoning: v.reasoning })),
    }
  })
}))

phase('Synthesize')
const judged = verified.filter(Boolean)
const survivors = judged.filter(x => x.survives).map(x => ({ ...x.finding, votes: x.votes }))
const order = { blocker: 0, should: 1, nit: 2 }
survivors.sort((a, b) => (order[a.severity] ?? 3) - (order[b.severity] ?? 3))
log(distinct.length + ' distinct defect(s) judged; ' + survivors.length + ' survived verification')

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
  refuted: judged.filter(x => !x.survives).map(x => ({
    title: x.finding.title, severity: x.finding.severity,
    lenses: x.finding.lenses || (x.finding.lens ? [x.finding.lens] : []),
    votes: x.votes,
  })),
}
