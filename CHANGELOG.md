# Changelog

The repository ships as a single plugin, `lunar`, with one version. Each release
section is one version of it, with entries grouped by the skill they affect.

Sections at `v0.12.0` and below predate the consolidation, when every skill was
its own plugin with its own version. Those headings name the plugin and the
version it actually shipped as, and are left as they were — the record of what
users received.

**The version bump is what ships.** Anyone installed from GitHub receives an
update only when `version` changes — see [docs/RELEASING.md](docs/RELEASING.md).

This project follows [Keep a Changelog](https://keepachangelog.com/) loosely and
[Semantic Versioning](https://semver.org/).

## Unreleased

### lunar — 1.0.0

The six plugins become one. Installing `lunar` gets every skill, every bundled
script is on one `PATH` entry, and the skills-directory install route is gone.
Skills are now invoked as `/lunar:<name>`.

**If you installed an individual skill from the marketplace, this breaks it.**
`hyperdx@lunar-skills` and its five siblings no longer exist as plugins, and no
version bump can offer you a plugin under a different name — you will simply stop
being offered updates. Move across with:

```
/plugin marketplace update lunar-skills
/plugin install lunar@lunar-skills
```

Then uninstall the old ones. Every invocation gains a `/lunar:` prefix, which is
the other half of why this is a major version.

- **One plugin, one manifest.** `plugin/.claude-plugin/plugin.json` replaces the
  six per-skill manifests, and `marketplace.json` carries a single entry with
  `"source": "./plugin"`. Adding a skill is creating
  `plugin/skills/<name>/SKILL.md`; there is nothing to register.
- **One `bin/`.** Every bundled script moved from `skills/<name>/bin/` to a
  single `plugin/bin/`. No basename collided. The scripts are invoked exactly as
  before — bare name, no path — and the permission rules are unchanged.
- **`plugin/` is the whole of what you receive**, and nothing outside it reaches
  you. The methodology docs, the validation suite, the CI workflow and the
  templates you merge by hand all stay in the repository where they are useful,
  rather than riding along in your plugin cache. That is enforced rather than
  observed: `validate.sh` compares `plugin/` against `git ls-files` and fails on
  any untracked file inside it.

  This matters most for a local `directory` install, which is a filesystem copy
  of the plugin root — it skips `.git` and respects neither `.gitignore` nor
  `.git/info/exclude`. With the whole repository as the plugin root, a local
  scratch directory and a gitignored `.claude/` were both copied into the plugin
  cache. Nesting the payload is what stops that, and the check is what keeps the
  nesting honest.
- **The plugin carries its own `LICENSE`**, since it is redistributed on its own.
  `validate.sh` asserts it stays byte-identical to the repository's.
- **`install.sh` is gone.** It existed to copy skills into
  `~/.claude/skills/<name>/`, which was the second of two install routes and the
  source of every "which copy is loaded" problem. The remaining route is the
  marketplace, pointed either at GitHub or at a local clone via a `directory`
  source — the latter loads the working tree in place, so an edit is live after
  `/reload-plugins`, and immediately for a script.

  `/plugin install` still writes an inert snapshot under
  `~/.claude/plugins/cache/`, pinned to the commit installed from. Nothing loads
  from it, but it exists, and `adversarial_review_path.sh` is what tells you which
  copy is running — it answers for whichever copy contains it rather than
  globbing.
- **Templates moved to `install/`.** `install/user/settings.json` and
  `install/user/CLAUDE.md` are merged into `~/.claude/` once per machine;
  `install/project/.agent.env` stays per-project. Nothing installs them — a
  plugin cannot ship a permissions layer or an auto-loading CLAUDE.md.
- **`adversarial_review_path.sh` resolves against the plugin root**, one level up
  from its own `BASH_SOURCE[0]`, and still answers for the copy that contains
  it rather than globbing.
- The adversarial-review `SKILL.md` documents the step that was previously
  folklore: **copy the resolved engine into the session scratchpad and pass the
  copy** to the Workflow tool, which accepts a `scriptPath` only inside the
  working directory. The engine lives with the plugin, outside every project it
  reviews, so the copy is the mechanism rather than a workaround. Copy it fresh
  each session; never glob for it and never reuse an older copy.

### adversarial-review

- **The Step 0 snapshot no longer lands in a shared `/tmp`.** It used
  `${CLAUDE_JOB_DIR:-/tmp}/tmp`, and `CLAUDE_JOB_DIR` is not set in a normal
  session, so every review on a machine wrote its baseline to the same
  `/tmp/tmp/ar_tree_before.txt`. A second review running anywhere — another
  project, another session — overwrote it, and the Step 5 compare then judged one
  tree against another's baseline: a change reported that never happened, or
  "tree unchanged" against a baseline belonging to a different repository. The
  snapshot is the only guard for an in-place review of uncommitted work, so it
  now goes in the session's own scratchpad, which is unique by construction.
- **A missing baseline is reported as unverified rather than as damage.** `diff`
  exits non-zero when the before-file is simply absent, which read as "an agent
  mutated the tree" and sent the reader looking for damage that was never there.
  Step 5 now distinguishes the two.
- The engine copy step says to use the session scratchpad named in the
  environment, instead of an undefined `$SCRATCH`.

### All skills

- **`--help` works on every bundled script.** It was documented as working and
  did on four of eight. `hdx_query.sh` rejected it as an unknown option;
  `adversarial_review_path.sh` read it as a bundled filename;
  `langfuse_query.sh` ignored it and walked on into environment validation,
  emitting a raw bash error about a missing key; and
  `pr_review_resolve_thread.sh` handed it to `gh` as a thread node ID, so asking
  that script for help made a live GitHub API call.
- Help is answered **before** the dependency preflight. Someone without `gh` or
  `curl` installed is the reader most likely to be asking what a script needs,
  and exiting 127 at them answers a different question than the one asked.
- `validate.sh` now runs each script with `--help` and `-h`, requires usage
  output and exit 0, and requires the flag to be answered before the first
  `require_cmd`. None of this was reachable by reading the scripts, which is why
  the check runs them. All three properties were confirmed by breaking each one
  and watching the check fail.

### mutation-test

Scoping, not automation. Point it at a PR or a diff and it tells you which lines
changed and gives you a checkout you cannot damage. Choosing the mutation and
judging the result stay manual, as they were.

- **`mutation_test_changed_lines.sh`** turns a PR or a diff into a shortlist:
  every added or modified line, as `path<TAB>line`, filterable by suffix.
  Deleted lines are absent — there is nothing left to mutate. Shell only, no
  `jq` and no `python3`, so it adds no dependency to a Go or Rust project.
- It treats the diff as **untrusted input**, because the author of the PR under
  review wrote it. An added line reading `++ path` renders as `+++ path` and a
  deleted one reading `-- x` renders as `--- x`, so file headers are recognised
  only between hunks, bounded by both lengths in the `@@` header — and only the
  header portion of that line is read, since the function-context text after it
  is author-controlled too. Without that, a line could be attributed to the
  wrong file, or dropped while the summary still read as a complete inventory.
- A hunk still open at the end of the input is **refused as a malformed diff**
  rather than reported with guessed line numbers.
- **`mutation_test_worktree.sh`** is what step 3 uses: a throwaway checkout at
  the ref you name, bootstrapped, with the baseline confirmed green before your
  command runs, removed afterwards. `--ref` documents the `git fetch` a PR head
  needs, and says plainly that a non-HEAD ref means the working-tree checks are
  skipped.
- `mutation_test_worktree.sh` builds a throwaway `git worktree` to mutate in, so
  the tool never writes to your source tree. Every blocker that held the first
  attempt back lived in a back-up-and-restore path, and a tree you never write to
  cannot have them.
- **There is no batch runner, and one is no longer planned.**
  `mutation_test_changed_lines.sh` tells you which lines changed and
  `mutation_test_worktree.sh` gives you somewhere safe to mutate them; choosing
  the mutation and judging the result stay yours. A runner that did the sweep was
  written and withdrawn after five review rounds found blockers in it — every one
  in the mutate-and-restore path, and each fix opened another.
  [#13](https://github.com/LunarCommand/claude-skills/issues/13), which tracked
  rebuilding it around a worktree, is closed: its premise was that a worktree
  removes the need to restore, and that is wrong, because one worktree serves
  many mutants and each still has to be undone.
- The manual path gains the rule that makes its backup discipline
  load-bearing: mutate the file in place, never a copy in a worktree or a
  scratch checkout. An editable install records an absolute path to the original
  source, so a mutation made elsewhere is never imported, every mutant passes,
  and the run reads as missing coverage rather than as a tool that did nothing.
  Reported from a real run where the worktree shortcut looked like the tidier
  option.
- **There is no `destroy` subcommand, and no way to hand this tool a path to
  delete.** Two designs had one, and both deleted a repository — `.git` and
  uncommitted work — while printing "removed" with exit 0. The first never
  asked whether the path was a worktree; the second asked three times, printed
  git's refusal, and deleted anyway because the status was captured and never
  tested. `run` now owns the worktree from creation to teardown and its path
  never crosses the boundary.
- **It no longer claims to prove that your test command can see a mutation**,
  because nothing exit-code-shaped can. Three designs tried: break the file's
  syntax, empty it, append a statement that is fatal when executed. Each was
  defeated by a step that reads the file without running it — a linter, a type
  checker, a formatter — and in Go, Rust or Java there is no legal top-level
  fatal statement to append at all. A fourth probe would have been a fourth
  confoundable signal, not a stronger proof.
- What it establishes instead is only what it directly observes: the working
  tree has no uncommitted changes, the bootstrap you named ran, and your test
  command exits 0 in the checkout. A command that could not RUN (not found, not
  executable, killed by a signal) is reported as breakage rather than as your
  code being red.
- The wiring question moves to where it can be answered honestly — the results.
  Mutate several independent lines, and if every mutant survives, suspect the
  environment. That cannot be fooled by a linter and costs nothing.
- The uncommitted-changes check now reports untracked files too. With them
  suppressed, a test you had just written and not yet `git add`ed passed the
  check and was simply absent from the checkout — so the baseline was green,
  every mutant survived, and it read as missing coverage. That is this skill's
  most common starting state. A file carrying `assume-unchanged` or
  `skip-worktree` is refused for the same reason: it is invisible to
  `git status`, so nothing could tell whether it differed.
- `--ref HEAD` no longer buys a bypass of that check. It names the very commit
  the check compares against, and the refusal message used to steer callers
  straight to it. An explicit `--ref` to any *other* commit still skips it.
- A signal during your command now stops the run. The command was executed in
  the foreground, and bash defers trap handling until a foreground command
  returns, so `SIGTERM` did nothing until it finished — and a supervisor
  escalating to `SIGKILL` left the worktree and its registration behind with no
  message.
- The uncommitted-changes check covers the whole tree rather than one file. It
  previously checked only the file about to be mutated, so a dirty *test* file —
  the normal state when this skill is used — was silently judged at its
  committed version.

### Repository

- The three hygiene scans ask git what can be committed rather than walking the
  filesystem. They reported a personal path from a directory excluded via
  `.git/info/exclude`, which can never reach anyone; any local scratch directory
  did the same, and only locally, since CI clones fresh. They are also stricter
  in one direction now — a file someone gitignored and then force-added is
  tracked, so it is scanned.
- `scripts/validate.sh` checks that every refusal the mutation-test worktree
  script can print is asserted in its acceptance suite, and that no two guards
  share a refusal identity. Three review rounds each found a guard that could
  be deleted with the suite still green, and twice the cause was two guards
  sharing one slug so no assertion could tell them apart. The first version of
  this check had the same blind spot it was written to close — it compared sets
  of *names*, so three ref guards sharing one slug still passed it — and now
  compares **call sites**: a slug used twice fails. It checks all four
  directions, including a slug the suite asserts that the script no longer
  prints, which is what catches a guard deleted outright. Slugs no fixture can
  reach are listed with the reason, so an exemption cannot hide anywhere else.
- The settings template approves the read-only git commands the review engines
  actually mandate: `git ls-tree`, `git merge-base`, and `git branch -a
  --contains`. The absence-search and tip-recheck rules added in 0.11.0 tell
  every verifier to run these, and every one of them prompted — dozens of times
  in a single review, since the tip-recheck runs per finding per verifier. The
  template is meant to cover exactly what the shipped skills run, and for three
  releases it did not.
- `CLAUDE.md` states where `bin/` lands on `PATH`: at the end, after `/usr/bin`
  and everything else. The bare-name rule already required distinctive basenames,
  but framed a collision as a question of which copy gets reached. The order
  makes it one-sided — a same-named executable anywhere earlier shadows the
  shipped script outright, the permission rule keeps approving the call, and the
  failure reads as the skill misbehaving.
- `scripts/validate.sh` follows the consolidation. It validates one plugin
  manifest instead of six, runs `claude plugin validate` once, and checks the
  version bump against the single `version`, scoped to `skills/` and `bin/` —
  the paths the plugin delivers as running code. Two checks changed shape rather
  than moving: "every skill is listed in the marketplace" became "every tracked
  `SKILL.md` sits inside the plugin root, where it can actually load", since
  there is no longer a list to fall out of; and the duplicate-basename check is
  gone because one `bin/` makes the collision it guarded impossible. The
  end-to-end `install.sh` run is gone with the installer, which leaves
  `--quick` skipping one slow section rather than two.

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
