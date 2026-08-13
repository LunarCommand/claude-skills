# Changelog

Each skill is published as its own plugin with its own version, so entries are
grouped by plugin rather than by repository. A plugin appears in a release
section only if it changed.

**The version bump is what ships.** Marketplace users receive an update only when
a plugin's `version` changes — see [docs/RELEASING.md](docs/RELEASING.md).

This project follows [Keep a Changelog](https://keepachangelog.com/) loosely and
[Semantic Versioning](https://semver.org/) per plugin.

## Unreleased

Nothing yet.

<!--
Shape for the next entry — list the version each plugin will ship as, and only
the plugins that actually changed:

### hyperdx — 1.1.0

- Fixed local multi-term queries returning zero rows on macOS.
-->

## v1.0.0 — 2026-08-13

First tagged release. Every plugin starts at `1.0.0`.

The toolkit is now a Claude Code plugin marketplace (`lunar-skills`), so each
skill can be installed on its own with `/plugin install <name>@lunar-skills`.
Cloning and running `install.sh` still works and installs all five at once; the
two routes are alternatives, not complements.

### adversarial-review — 1.0.0

- Multi-lens adversarial review that generates findings and verifies each by
  refutation before surfacing it, with a bundled multi-agent workflow engine.
- `spec-accept-review.workflow.js` is reachable from the skill for the first
  time: Step 3b now routes between the code and spec/RFC engines.
- Workflow engines are located by a bundled resolver rather than by prose, which
  could select a stale copy when more than one copy of the skill was installed.
- Snapshot guard captures untracked files with tar's file-list mode; the previous
  `xargs` pipeline dropped all but the final batch on large working trees.

### feature-planning — 1.0.0

- Plan-before-code workflow with two human approval gates, driven from a
  requirements file or a description in chat.

### hyperdx — 1.0.0

- Query HyperDX logs and traces with Lucene syntax, against cloud or a local
  ClickHouse instance in Docker.
- Local multi-term queries no longer collapse into a single free-text term on
  macOS. The splitter used GNU-only `\xNN` sed escapes, which BSD sed emits
  literally, silently returning zero rows as if the query had succeeded.
- Transport failures (DNS, connection, TLS, timeout) report an error and a
  non-zero exit instead of an empty result with exit 0.
- `curl` is required only in cloud mode; local mode reaches ClickHouse through
  `docker exec`.

### langfuse — 1.0.0

- Inspect Langfuse traces, observations, sessions, scores, and prompts.
  Auto-detects the server's API generation and adapts to the legacy v1 REST API
  or the v4 read API.

### pr-review — 1.0.0

- Triage GitHub PR review threads one at a time, proposing a verdict for each
  before replying and resolving.
- Scripts are named `pr_review_*`. Permission rules approve a command *name*
  resolved through `PATH`, so a generic name such as `post_reply` could be
  satisfied by an unrelated executable.
- GraphQL identifiers travel as typed variables instead of being interpolated
  into the query document, and every argument is validated.
- The standalone `jq` binary is no longer required: filters run through
  `gh api --jq`, which uses the engine embedded in `gh`.
