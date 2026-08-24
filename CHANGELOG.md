# Changelog

Each skill is published as its own plugin with its own version, so entries are
grouped by plugin rather than by repository. A plugin appears in a release
section only if it changed.

Changes that belong to no plugin — the installer, the checks, the release
process, repo-wide docs — go under a `### Repository` heading in the same section.
They carry no version of their own; they ship whenever they land on `main`.

**The version bump is what ships.** Marketplace users receive an update only when
a plugin's `version` changes — see [docs/RELEASING.md](docs/RELEASING.md).

This project follows [Keep a Changelog](https://keepachangelog.com/) loosely and
[Semantic Versioning](https://semver.org/) per plugin.

<!--
Shape for an entry — list the version each plugin will ship as, and only the
plugins that actually changed:

### hyperdx — 0.9.1

- Fixed local multi-term queries returning zero rows on macOS.
-->

## Unreleased

### mutation-test — 0.10.0

- Groundwork for scoped runs: `mutation_test_worktree.sh` builds a throwaway
  `git worktree` to mutate in, so the tool never writes to your source tree. The
  runner that uses it is not here yet. Every blocker that held the first attempt
  back lived in a back-up-and-restore path, and a tree you never write to cannot
  have them.
- The manual path gains the rule that makes its backup discipline
  load-bearing: mutate the file in place, never a copy in a worktree or a
  scratch checkout. An editable install records an absolute path to the original
  source, so a mutation made elsewhere is never imported, every mutant passes,
  and the run reads as missing coverage rather than as a tool that did nothing.
  Reported from a real run where the worktree shortcut looked like the tidier
  option.
- It refuses to hand back a worktree unless the baseline is green **and** a
  change to the target file provably reaches the test command. The second gate
  is the one that matters: a Python editable install records an absolute path,
  so an environment reused from the host resolves imports to the *original*
  tree. The mutant then runs against unmutated source, every test passes, and
  the run reports "no covering tests" with exit 0 — a clean-looking result that
  is entirely false. Bootstrapping inside the worktree costs about three
  seconds and is now required rather than optional.

### Repository

- `CLAUDE.md` states where a skill's `bin/` lands on `PATH`: at the end, after
  `/usr/bin` and everything else. The bare-name rule already required distinctive
  basenames, but framed a collision as a question of which copy gets reached. The
  order makes it one-sided — a same-named executable anywhere earlier shadows the
  shipped script outright, the permission rule keeps approving the call, and the
  failure reads as the skill misbehaving.

## v0.12.0 — 2026-08-23

### Repository

- `CLAUDE.md` records what the checks cannot do. Every check in
  `scripts/validate.sh` is syntactic — shellcheck, the portability scan,
  `bash -n`, the manifest and allowlist agreement — so a green run says the
  artifacts are spelled correctly and nothing about whether they do what they
  claim. The defect that prompted this passed all of them: `tr '/' '_'` is valid
  shell, and also not injective, which let one file's backup overwrite another's.
  Anything that writes to a user's tree needs its backup-and-restore path read by
  hand, and external code needs reviewing when it arrives rather than after three
  fixes are built on it.

### mutation-test — 0.9.0

New skill: proves a test actually checks something, by breaking the behaviour it
claims to cover and confirming it goes red.

- It supersedes an unreleased `prove-it-fails` and takes its name from the
  technique, which is what people search for. A green run is the null result — a
  dead assertion and a live one produce identical output — so this establishes the
  one thing that discriminates.
- Restore is by file copy and verified by content. The files this skill is pointed
  at are the ones just written, so they hold uncommitted work: `git checkout` and
  `git stash` destroy it rather than restore it, and on an already-dirty file
  `git status` cannot tell a restored file from a still-mutated one.
- **Scoped runs are deliberately not in this version.** A batch runner that
  resolves a PR to changed lines and mutates them was written and then held back:
  an adversarial review found its restore path could write one file's contents
  over another — reproduced, with the run still reporting "all files restored" —
  along with a concurrency race and two paths that eval attacker-influenced
  strings. Shipping that behind a permission rule that lets it run without
  prompting would have been worse than shipping nothing. The SKILL.md says what is
  missing rather than implying a sweep happened, and
  [#13](https://github.com/LunarCommand/claude-skills/issues/13) tracks the
  rebuild — around a throwaway `git worktree` rather than mutate-and-restore, so
  the defect class cannot recur.

## v0.11.0 — 2026-08-21

### Repository

- The recommended user CLAUDE.md opens with a communication-style section: plain
  register, short sentences, no invented jargon. It states explicitly that this is
  a register and not a vocabulary limit, so the precise technical term survives —
  the failure mode of a "keep it simple" instruction is losing precision along
  with the padding.
- The two review engines are checked for drift. The Workflow runtime gives a
  script no imports, so they must duplicate their shared refutation mandates, and
  the pair has already shipped twice with documentation apologising for a rule one
  had and the other did not. Validation now asserts the four constants are
  byte-identical — and the check cannot quietly stop checking: it compares each
  constant to the next top-level statement rather than to the first blank line,
  and a missing engine file fails the run instead of skipping it.

### adversarial-review — 0.11.0

Two batches ship under one version: the code engine's verify-stage work,
and the spec engine catching up to it. adversarial-review 0.10.0 was never
tagged, so nothing was ever released under that number.

- Refutation now has to search before it accepts an absence claim. "Untested",
  "unguarded", "unhandled" are the easiest findings to state and the least often
  checked; a verifier must name the test or guard that would have to exist and go
  look for it, and "I didn't see one" is not a search.
- A finding is re-checked against the branch tip before it is reported. A PR
  reviewed mid-stream or a resumed run leaves findings that were true at the
  reviewed ref and already fixed at the tip, and reporting those as live costs the
  reader a triage pass. Only an actual fix refutes.
- Nits are judged by two verifiers instead of one, and must survive both. A single
  angle is close to no verification, and `reproduce` is skipped for this tier
  because a prose nit can never satisfy it and would be auto-refuted.
- A verifier that returns no verdict now abstains instead of counting as a
  refusal. The threshold is taken from the verifiers that actually answered, so a
  dead agent no longer deletes a finding the survivors affirmed.
- A finding no verifier judged is reported as **unverified** rather than refuted,
  in its own bucket and its own line in the run summary. A verify-phase outage
  used to render as a clean review.
- A `reviewRef` or `baseRef` that cannot safely be interpolated into a command is
  refused — a leading dash made `git diff --output <path>` reachable, and git's own
  `check-ref-format` accepts such a branch name. A refused ref is announced in the
  run log and kept distinguishable from one that was never supplied, because
  failing silently sent every agent to the pre-change default branch.
- Confirmed findings carry the panel that judged them (`asked` vs `cast`), so a
  finding confirmed by one surviving verifier is distinguishable from one
  confirmed by three, and the run warns when a finding vanishes mid-verify.
- The spec/RFC engine can review committed work in a sandbox. It accepts
  `isolate`, `reviewRef` and `baseRef` like the code engine and runs every lens,
  merge and verify agent in a throwaway worktree. Without them it could only
  review uncommitted work in the real tree — the highest-risk configuration in the
  skill — which pushed people to the code engine for spec targets just to get
  isolation, trading the right lenses for the right safety.
- Its verify stage matches the code engine's. A verifier that returns nothing now
  abstains: the engine coerced a missing verdict to `REFUTED`, so a dead agent
  voted against, and on the one-angle nit panel it used to run that killed the
  finding outright. Nits are judged by claim-true and regress, the threshold comes
  from the verifiers that answered, and a finding nobody judged is reported as
  unverified rather than refuted.
- The absence-search and tip-recheck mandates apply on the spec path too.
- Both engines warn when `isolate` is on and no `reviewRef` was passed at all. The
  refusal warning covered only a ref that was supplied and rejected, so the missing
  case ran silently while every agent read a worktree cut from the default branch —
  the configuration that has already made three verifiers refute a real blocker.

### feature-planning — 0.10.0

- Gate 2 has a second exit. `approved` means the plan is right *and* start
  building; `accepted` means the plan is right but stop here. Conflating the two
  made "good plan, not yet" expressible only by interrupting a run that had already
  started writing code.
- The plan file carries a `## Status` line through its whole lifecycle: `Drafted`
  at write time, `Accepted — not yet implemented` with a date and a plan sha at
  Gate 2, `Implemented` when the last phase goes green. The sha is what makes the
  deferred-start check answerable — re-entry compares against it and re-presents
  Gate 2 if the plan moved, rather than asserting it did not.
- Implementation tasks carry stable `P<phase>.<task>` IDs, for the same reason
  tests carry `T-<n>`: prose gets reworded, identifiers do not. Numbering within
  the phase means appending a task never renumbers another.

## v0.10.0 — 2026-08-19

### Repository

- The recommended user CLAUDE.md allows a `docs/` branch prefix. This repository
  had already used one for a documentation-only PR, so the convention and the
  practice disagreed.
- README restructured around using the toolkit rather than listing it: a contents
  list, a diagram of how the skills chain together, per-skill "use it for" entries
  with real invocations, and four sections it never had — what an adversarial
  review costs, when not to use any of this, what surprises people, and what never
  to do. The cost section is the gap that mattered: a PR-sized adversarial review
  runs 1.5-3M tokens across dozens of agents, and nothing in the repository said
  so before installing it.
- The settings template is now scoped to this toolkit. It was a personal project
  config — `defaultMode: auto`, `Write`, `Edit`, `Agent`, `Bash(make:*)`, `uv`,
  `brew`, `nvidia-smi` — that happened to contain the script rules. Every entry
  now traces to a command a shipped skill runs, which is what makes it safe to
  suggest at user scope as well as project scope, and the `README`, `CLAUDE.md`
  and `install.sh` warnings against copying it whole are gone with it.
- README documents copying a skill by hand as a third install route. The
  manifest lives in a hidden `.claude-plugin/` directory, so the obvious
  `cp -R skills/<name>/* ...` skips it, and without it the copy is an inert
  folder: `bin/` never reaches the Bash tool's `PATH` and every bare-name call
  fails. Reported downstream as the permission rules being wrong; the rules were
  correct and the manifest was missing.
- Fixed `scripts/validate.sh` on macOS. It used `mapfile`, a bash 4 builtin, and
  macOS ships bash 3.2.57 — so on a Mac the run stopped at the first check and
  everything after it was skipped. Reported by a downstream user; present since
  the script was first committed.
- The portability check no longer exempts `install.sh`, `scripts/` and
  `.githooks/`, and now covers bash 4 syntax as well as GNU-only tool flags. The
  old exemption assumed those files never left a machine we control, which a
  public repo makes false.
- CI runs on macOS as well as Linux, with the stock bash 3.2 forced onto `PATH`
  so the job cannot pass by silently using Homebrew's bash 5.
- The credential and personal-path scans filter `.git` by path rather than by
  piping through `grep -v './.git/'`, which tested the whole matched line and so
  discarded any hit whose text happened to contain that string. A committed
  `AKIA…` key on such a line was reported as clean.
- `install.sh` installs skills and nothing else. It no longer writes the
  recommended user CLAUDE.md as `~/.claude/CLAUDE.md` when none exists — that
  file now always lands as `CLAUDE.md.recommended`. An installer for skills
  should not apply a house style to every project on the machine, and the
  previous behaviour did exactly that on a fresh workstation.
- The recommended user CLAUDE.md now carries a code comment section: comment the
  why, keep it short, and keep history, dating figures and narrative out. Doc
  comments that are a public interface are explicitly exempt, and the
  pre-commit check reads the diff rather than the whole file, so it cannot ask
  for a rewrite of code the change never touched.
- Publishing a GitHub Release is now a step in the release process rather than an
  aside. A pushed tag does not create one, and a repository showing tags with no
  Releases reads as a project that does not cut them.

## v0.9.0 — 2026-08-13

First tagged release. Every plugin starts at `0.9.0`: the skills have been in
daily use for a long time, but the interfaces are still moving, so this stays
pre-1.0 rather than promising the stability a `1.x` implies.

The toolkit is now a Claude Code plugin marketplace (`lunar-skills`), so each
skill can be installed on its own with `/plugin install <name>@lunar-skills`.
Cloning and running `install.sh` still works and installs all five at once; the
two routes are alternatives, not complements.

### adversarial-review — 0.9.0

- Multi-lens adversarial review that generates findings and verifies each by
  refutation before surfacing it, with a bundled multi-agent workflow engine.
- `spec-accept-review.workflow.js` is reachable from the skill for the first
  time: Step 3b now routes between the code and spec/RFC engines.
- Workflow engines are located by a bundled resolver rather than by prose, which
  could select a stale copy when more than one copy of the skill was installed.
- Snapshot guard captures untracked files with tar's file-list mode; the previous
  `xargs` pipeline dropped all but the final batch on large working trees.

### feature-planning — 0.9.0

- Plan-before-code workflow with two human approval gates, driven from a
  requirements file or a description in chat.

### hyperdx — 0.9.0

- Query HyperDX logs and traces with Lucene syntax, against cloud or a local
  ClickHouse instance in Docker.
- Local multi-term queries no longer collapse into a single free-text term on
  macOS. The splitter used GNU-only `\xNN` sed escapes, which BSD sed emits
  literally, silently returning zero rows as if the query had succeeded.
- Transport failures (DNS, connection, TLS, timeout) report an error and a
  non-zero exit instead of an empty result with exit 0.
- `curl` is required only in cloud mode; local mode reaches ClickHouse through
  `docker exec`.

### langfuse — 0.9.0

- Inspect Langfuse traces, observations, sessions, scores, and prompts.
  Auto-detects the server's API generation and adapts to the legacy v1 REST API
  or the v4 read API.

### pr-review — 0.9.0

- Triage GitHub PR review threads one at a time, proposing a verdict for each
  before replying and resolving.
- Scripts are named `pr_review_*`. Permission rules approve a command *name*
  resolved through `PATH`, so a generic name such as `post_reply` could be
  satisfied by an unrelated executable.
- GraphQL identifiers travel as typed variables instead of being interpolated
  into the query document, and every argument is validated.
- The standalone `jq` binary is no longer required: filters run through
  `gh api --jq`, which uses the engine embedded in `gh`.
