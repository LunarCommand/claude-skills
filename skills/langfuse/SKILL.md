---
name: langfuse
description: Interact with Langfuse and access its documentation. Use when needing to (1) query or modify Langfuse data programmatically — traces, prompts, scores, sessions, observations, (2) look up Langfuse documentation, concepts, integration guides, or SDK usage, or (3) understand how any Langfuse feature works. Works against self-hosted and cloud Langfuse, on both the legacy v1 REST API (server major <= 3) and the v2/v3 read APIs (server major >= 4).
---

# Langfuse

This skill helps you use Langfuse effectively: debugging traces, inspecting LLM generations and tool calls, reviewing sessions, and managing prompts.

## Core Principles

1. **Use the query script for data access**: Run `langfuse_query.sh` (in this skill's `scripts/` directory) for all Langfuse queries. It detects the server's API generation and picks the right endpoints.
2. **Documentation First**: When implementing SDK integrations, always fetch current docs before writing code (Langfuse updates frequently).

## Per-Project Configuration (.agent.env)

Each project should have a `.agent.env` file in the project root:

```
LANGFUSE_BASE_URL: http://localhost:3000
LANGFUSE_PUBLIC_KEY: pk-lf-...
LANGFUSE_SECRET_KEY: sk-lf-...
```

- `LANGFUSE_BASE_URL`: base URL of your Langfuse instance — local, EU cloud
  (`https://cloud.langfuse.com`), or US cloud (`https://us.cloud.langfuse.com`).
- API keys are in your Langfuse project under **Settings > API Keys**.

If any value is missing from `.agent.env`, ask the user to add it before proceeding.

## Permissions

The query script is pre-approved in `.claude/settings.json`:

```
Bash(~/.claude/skills/langfuse/scripts/*)
```

Run the script directly — **never** export env vars manually or run curl directly
for data access. Both trigger permission prompts. The script reads `.agent.env`
automatically from the project root.

## API generations (important)

Langfuse v4 changed the read API surface. The script reads the server version
once from `/api/public/health` and routes accordingly:

| | **legacy** (server ≤ 3) | **v4** (server ≥ 4) |
|---|---|---|
| Traces | `/traces`, `/traces/{id}` | **gone (404)** — derived from observations |
| Observations | `/observations`, `/observations/{id}` | `/v2/observations` (+ structured `filter` for a single id) |
| Sessions | `/sessions` | **gone (404)** — derived from observations |
| Scores | `/scores` | `/v3/scores` |
| Prompts | `/v2/prompts` | `/v2/prompts` (unchanged) |

Check what you're talking to:

```bash
$SCRIPT apigen        # → legacy | v4
```

Override detection with `LANGFUSE_API_GEN=legacy|v4` if needed.

### Three v4 behaviours worth knowing

- **`traces` and `sessions` are derived, not equivalent.** v4 exposes no trace
  or session read entity, so the script groups observations by `traceId` /
  `sessionId`. Both label their output as derived. A trace's "name" is
  inferred from its earliest observation.
- **Content requires field groups.** `/v2/observations` returns only `core` and
  `basic` fields by default — no input, output, usage, or model. The script
  requests `fields=core,basic,time,io,metadata,model,usage,prompt` where
  content matters. A port that forgets this silently returns metadata only.
- **Input/output are always raw strings.** `parseIoAsJson=true` is deprecated
  and returns **400**. The script decodes JSON-looking strings client-side.

### Pagination

v4 pagination is **cursor-based** (`meta.cursor`), not page-numbered — passing
`page=N` is silently ignored and returns the same rows. The script walks the
cursor transparently, so commands return the complete set rather than one page.

Walks are bounded by `LANGFUSE_MAX_RECORDS` (default **2000**) so a busy project
can't trigger an unbounded crawl. When the cap is hit the script says so on
stderr and tells you what to raise:

```
note: stopped at the 2000-record cap after 20 pages; raise LANGFUSE_MAX_RECORDS for more
```

```bash
LANGFUSE_MAX_RECORDS=10000 $SCRIPT trace <trace-id>
```

## 1. Querying Langfuse Data

```bash
SCRIPT=~/.claude/skills/langfuse/scripts/langfuse_query.sh

# List recent traces
$SCRIPT traces --limit 5
$SCRIPT traces --name my-trace-name --limit 10
$SCRIPT traces --session-id abc123 --limit 10

# Get a full trace with all observations
$SCRIPT trace <trace-id>

# Show LLM generations and tool calls for a trace (most common debugging task)
$SCRIPT generations <trace-id>

# List observations for a trace, optionally filtered by type
$SCRIPT observations <trace-id> --type GENERATION

# Get a single observation with full detail (raw JSON)
$SCRIPT observation <obs-id>

# Sessions, scores, prompts
$SCRIPT sessions --limit 5
$SCRIPT scores --trace-id <trace-id>
$SCRIPT prompts

# Which API generation am I on?
$SCRIPT apigen
```

### Common Workflows

**Check what the LLM actually received and returned:**
```bash
$SCRIPT traces --limit 3        # find the trace
$SCRIPT generations <trace-id>  # model, prompt name+version, tokens, input, output
```
On v4 this also shows the linked prompt (`promptName` / `promptVersion`), which
is the fastest way to confirm which prompt version produced a given output.

**Review a full trace end-to-end:**
```bash
$SCRIPT trace <trace-id>
```
Shows trace metadata plus a chronological list of all observations with tool
calls and token counts.

**Inspect token usage and cost:**
```bash
$SCRIPT generations <trace-id>
```

**Get raw JSON for one observation** (full untruncated input/output):
```bash
$SCRIPT observation <obs-id>
```

### Troubleshooting

- **404s on every command** — you are on a v4 server but detection returned
  `legacy` (or vice versa). Check `$SCRIPT apigen` and force with
  `LANGFUSE_API_GEN`.
- **Generations show no input/output** — the observation genuinely has none, or
  you are calling the API directly without `fields=...,io`.
- **`traces` shows fewer traces than expected on v4** — the walk stopped at
  `LANGFUSE_MAX_RECORDS`. The script prints a note on stderr when that happens;
  raise it and re-run.
- **A command is slow on v4** — it is paging. Each page is 100 observations, so
  a 2000-record trace costs 20 round trips. Narrow with `--type` where you can.

## 2. Langfuse Documentation

Three methods to access Langfuse docs, in order of preference. **Always prefer your application's native web fetch and search tools** (e.g., `WebFetch`, `WebSearch`) over `curl` when available.

### 2a. Documentation Index (llms.txt)

```bash
curl -s https://langfuse.com/llms.txt
```

Returns a structured list of every doc page with titles and URLs. Use this to discover the right page for a topic, then fetch that page directly.

### 2b. Fetch Individual Pages as Markdown

Any page listed in llms.txt can be fetched as markdown by appending `.md`:

```bash
curl -s "https://langfuse.com/docs/observability/overview.md"
```

### 2c. Search Documentation

```bash
curl -s "https://langfuse.com/api/search-docs?query=How+do+I+trace+LangGraph+agents"
```

### Instance API spec

A self-hosted instance serves its own OpenAPI spec, which is authoritative for
that exact version — more reliable than the docs site when endpoints have moved:

```bash
curl -s "$LANGFUSE_BASE_URL/generated/api/openapi.yml"
```
