---
name: hyperdx
description: >
  Query and read logs and traces from HyperDX using Lucene syntax via the
  bundled hdx_query.sh CLI. Use this skill whenever the user asks to search
  logs, fetch errors, debug a service, investigate incidents, check log output,
  inspect traces, or look up anything in HyperDX — even if they don't say
  "HyperDX" explicitly. Trigger on phrases like "check the logs", "show me
  errors from", "what's happening with service X", "look up logs for", "any
  500s recently", "show me the traces", or "what does HyperDX say about".
  Always use this skill when log querying or incident investigation is involved.
  IMPORTANT: always query logs by running the bundled hdx_query.sh script —
  never attempt to query HyperDX via curl, the API directly, or any other
  method.
---

# HyperDX Log Querying

> **MANDATORY**: Always use `hdx_query.sh` to query logs and traces. Do not use
> curl, raw API calls, or any other method — even if it seems simpler. If the
> script fails, fix the script — do not work around it.

`hdx_query.sh` ships in this skill's `bin/` directory, which is on the Bash
tool's `PATH` whenever the skill is installed. **Invoke it by bare name** — never
by an absolute path. The bare form is what the pre-approved permission rule
matches, and it is the only spelling that works across both install routes.

The script supports two modes: **cloud** (HyperDX REST API) and **local**
(ClickHouse via docker exec into a local HyperDX container).

---

## Per-Project Configuration (.agent.env)

Each project should have the following in its `.agent.env` file at the project
root:

```
HYPERDX_MODE: local # or: cloud
OTEL_SERVICE_NAME: your-service-name
HYPERDX_LOCAL_API_KEY: your-personal-api-key
HYPERDX_CONTAINER: hdx-local
```

- `HYPERDX_LOCAL_API_KEY` is the **Personal API Key** from HyperDX account
  settings — not the Ingestion API Key.
- `HYPERDX_CONTAINER` is the Docker container name for local mode (default:
  `hdx-local`). Omit if using cloud mode only.
- `OTEL_SERVICE_NAME` is the default service to filter on. **Multi-service
  projects** (e.g. a pipeline + an API) instead define one key per service —
  `OTEL_SERVICE_NAME_<SERVICE>` (e.g. `OTEL_SERVICE_NAME_PIPELINE`,
  `OTEL_SERVICE_NAME_API`). When those are present, pick the key matching what
  you're querying and pass it as `-s`; omit `-s` to sweep all services. Treat
  the bare `OTEL_SERVICE_NAME` as optional in that case.

If a **required** value (mode, API key, container) is missing from
`.agent.env`, ask the user to add it before proceeding. The service name is
optional — without one, query without `-s` (all services).

---

## Mode Detection (read this before every query)

Before running the script, read `.agent.env` and apply this logic:

```
if HYPERDX_MODE == "local"
    → add --local --container <HYPERDX_CONTAINER>
    → do NOT pass --api-key or --url
else (HYPERDX_MODE == "cloud" or not set)
    → pass --api-key <HYPERDX_LOCAL_API_KEY>
    → do NOT pass --local
```

**Never guess the mode** — always derive it from `HYPERDX_MODE` in `.agent.env`.
If `HYPERDX_MODE` is missing, ask the user to add it before proceeding.

---

## Permissions

This script is pre-approved in `.claude/settings.json`. You do not need to ask
for permission before running it. The approved pattern is:

```
Bash(hdx_query.sh:*)
```

Run the script directly without prompting the user for approval.

Dependencies: `curl` and `jq` (both standard on most dev machines).
Local mode also requires `docker`.

---

## Arguments

| Flag          | Short | Default                  | Description                                                                                                                      |
| ------------- | ----- | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| `--query`     | `-q`  | _(required)_             | Lucene query term. **Repeat for multiple terms — they are OR'd together.** Never use shell-escaped quotes inside a single value. |
| `--service`   | `-s`  |                          | OTEL_SERVICE_NAME to filter by                                                                                                   |
| `--api-key`   | `-k`  |                          | HyperDX Personal API key (cloud mode, read from .agent.env)                                                                      |
| `--minutes`   | `-t`  | `5`                      | How many minutes to look back                                                                                                    |
| `--limit`     | `-l`  | `10`                     | Max log lines to return                                                                                                          |
| `--url`       |       | `https://api.hyperdx.io` | HyperDX base URL (cloud mode)                                                                                                    |
| `--local`     |       | off                      | Query local ClickHouse instead of cloud API                                                                                      |
| `--container` |       | `hdx-local`              | Docker container name (local mode)                                                                                               |
| `--table`     |       | `logs`                   | `logs` or `traces` (local mode only)                                                                                             |

---

## Multi-term Queries

Pass each search term as its own `--query` flag. The script OR's them together
automatically — no shell quote escaping needed:

```bash
# DO THIS
hdx_query.sh --query "request completed" --query "job finished" --query "status:500"

# NOT THIS — triggers shell obfuscation warning in Claude Code
hdx_query.sh --query "\"request completed\" OR \"job finished\""
```

---

## Lucene Field Reference

| Lucene field   | Cloud (HyperDX) | Local logs            | Local traces           |
| -------------- | --------------- | --------------------- | ---------------------- |
| `level:error`  | ✓               | → `SeverityText`      | —                      |
| `service:name` | ✓               | → `ServiceName`       | → `ServiceName`        |
| `TraceId:xxx`  | ✓               | → `TraceId`           | → `TraceId`            |
| `SpanName:xxx` | ✓               | —                     | → `SpanName`           |
| `"free text"`  | ✓               | → `Body ILIKE`        | → `SpanName ILIKE`     |
| `field:value`  | ✓               | → `LogAttributes` map | → `SpanAttributes` map |

**Local mode matches `field:value` exactly and case-sensitively** (it builds
`col = 'value'`). `SeverityText` is stored lowercase, so use `level:warn` /
`level:error` / `level:info` — `level:WARN` matches nothing. When unsure of a
field's stored values, drop the filter and grep `Body` with free text instead.

---

## Workflow

1. **Read `.agent.env`** — extract the service name(s) (`OTEL_SERVICE_NAME`,
   or per-service `OTEL_SERVICE_NAME_<SERVICE>` keys), `HYPERDX_LOCAL_API_KEY`,
   and `HYPERDX_CONTAINER`. For a multi-service project, pick the key matching
   what you're querying; omit `-s` to sweep all services.
2. **Determine mode** — use `--local` if the user is debugging a local run;
   use cloud (default) for deployed services.
3. **Construct the query** — use one `--query` flag per term, never escape
   quotes inside a single flag value.
4. **Run the script** — default to `--minutes 5 --limit 10` for quick checks.
5. **Interpret output** — summarize patterns, highlight repeated errors, suggest
   next steps.
6. **Iterate** — broaden query or increase `--minutes` / `--limit` if needed.

---

## Common Patterns

**Cloud — quick error check:**

```bash
hdx_query.sh \
  -k "your-key" -s "your-service" -q "level:error"
```

**Cloud — multi-term OR search:**

```bash
hdx_query.sh \
  -k "your-key" -s "your-service" \
  --query "request completed" \
  --query "job finished" \
  -t 30 -l 50
```

**Local — recent logs:**

```bash
hdx_query.sh \
  --local --container hdx-local -s "your-service" \
  -q "level:error" -t 10 -l 20
```

**Local — trace lookup:**

```bash
hdx_query.sh \
  --local --table traces -s "your-service" \
  -q "TraceId:abc123"
```

**Local — self-hosted URL:**

```bash
hdx_query.sh \
  -k "your-key" -q "level:error" --url http://localhost:8080
```

---

## Error Handling

| Error                                  | Likely cause                           | Fix                                                     |
| -------------------------------------- | -------------------------------------- | ------------------------------------------------------- |
| `No API key found`                     | Missing from .agent.env                | Add `HYPERDX_LOCAL_API_KEY`                             |
| `Error: Unauthorized`                  | Wrong key type (Ingestion vs Personal) | Use Personal API Key from account settings              |
| `ClickHouse error: docker exec failed` | Container not running or wrong name    | Check `docker ps` and `HYPERDX_CONTAINER` in .agent.env |
| `No logs found matching...`            | Query too narrow or wrong time window  | Broaden query or increase `--minutes`                   |
| `HTTP Error: ...`                      | API-side issue                         | Check HyperDX status / try again                        |