#!/usr/bin/env bash
set -euo pipefail

# Dependency preflight. Without it a missing binary surfaces partway through a
# pipeline as `python3: command not found`, which reads as a bug in this script.
# The skill instructs the agent to fix a failing script rather than work around
# it, so an unclear failure sends it editing working code.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "Missing required command: $1" >&2
  echo "  $2" >&2
  exit 127
}
require_cmd curl    "Install curl — most systems ship it (apt install curl / brew install curl)."
require_cmd python3 "Install Python 3 — this script uses it to format JSON (apt install python3 / brew install python3)."

# langfuse_query.sh — Query a self-hosted or cloud Langfuse instance.
# Requires: LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, LANGFUSE_BASE_URL
# Uses curl + python3 for JSON formatting (no jq dependency).
#
# Supports two API generations, detected automatically from /api/public/health:
#
#   legacy (server major <= 3) — the v1 REST API: /traces, /observations,
#       /sessions, /scores.
#   v4     (server major >= 4) — those endpoints return 404 once the server
#       runs in `events_only` write mode. Reads go through
#       /api/public/v2/observations (with `fields` groups for io/usage/model)
#       and /api/public/v3/scores.
#
# Override detection with LANGFUSE_API_GEN=legacy|v4.
#
# Paging is cursor-based on v4 and handled transparently by _v4_obs, bounded
# by LANGFUSE_MAX_RECORDS (default 2000).
#
# Two commands are DERIVED on v4, not equivalent: v4 exposes no trace or
# session read entity, so `traces` and `sessions` are reconstructed by
# grouping observations. Both say so in their output.

# ---------------------------------------------------------------------------
# Config — load from .agent.env if present, then validate
# ---------------------------------------------------------------------------

AGENT_ENV="$(pwd)/.agent.env"
if [[ -f "$AGENT_ENV" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue   # skip comments
    [[ -z "${line// }" ]] && continue             # skip blank lines
    # Support both `KEY=VALUE` and `KEY: VALUE` formats.
    if [[ "$line" == *"="* && ( "$line" != *":"* || "${line%%=*}" != *":"* ) ]]; then
      key="${line%%=*}"
      value="${line#*=}"
    else
      key="${line%%:*}"
      value="${line#*:}"
    fi
    # Trim leading/trailing whitespace from key and value, strip surrounding quotes.
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
      value="${value:1:${#value}-2}"
    fi
    [[ -z "$key" || -z "$value" ]] && continue
    # Skip lines that aren't valid identifiers (e.g., malformed entries).
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    export "$key"="$value"
  done < "$AGENT_ENV"
fi

: "${LANGFUSE_PUBLIC_KEY:?LANGFUSE_PUBLIC_KEY not set — add it to .agent.env}"
: "${LANGFUSE_SECRET_KEY:?LANGFUSE_SECRET_KEY not set — add it to .agent.env}"
: "${LANGFUSE_BASE_URL:?LANGFUSE_BASE_URL not set — add it to .agent.env}"

API="${LANGFUSE_BASE_URL}/api/public"
AUTH="${LANGFUSE_PUBLIC_KEY}:${LANGFUSE_SECRET_KEY}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_curl() {
  curl -sf -u "${AUTH}" "$@"
}

_fmt() {
  python3 -m json.tool 2>/dev/null || cat
}

# Detect the API generation once per invocation and cache it.
# /api/public/health reports {"status":"OK","version":"4.1.0"} on every
# supported server; anything we cannot parse falls back to legacy, which is
# the conservative choice (a legacy call against v4 fails loudly with 404
# rather than silently returning wrong data).
_API_GEN_CACHE=""
_api_gen() {
  if [[ -n "$_API_GEN_CACHE" ]]; then
    echo "$_API_GEN_CACHE"; return
  fi
  if [[ -n "${LANGFUSE_API_GEN:-}" ]]; then
    _API_GEN_CACHE="${LANGFUSE_API_GEN}"; echo "$_API_GEN_CACHE"; return
  fi
  local version major
  version="$(curl -sf -u "${AUTH}" "${API}/health" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null || true)"
  major="${version%%.*}"
  if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 4 )); then
    _API_GEN_CACHE="v4"
  else
    _API_GEN_CACHE="legacy"
  fi
  echo "$_API_GEN_CACHE"
}

# v4 field groups. `io` carries input/output, `usage` the token/cost detail,
# `prompt` the linked prompt name+version. Without `fields` the server returns
# only core+basic, which is why a naive port loses all content.
_V4_FIELDS_FULL="core,basic,time,io,metadata,model,usage,prompt"
_V4_FIELDS_LIST="core,basic,time,model"

# Safety cap on how many observations a single command will page through.
# Prevents an unbounded walk on a busy project; override if you need more.
_V4_MAX_RECORDS="${LANGFUSE_MAX_RECORDS:-2000}"

# Page through /v2/observations and emit ONE merged {"data":[...]} document,
# so every renderer can stay a simple stdin consumer.
#
# v4 pagination is cursor-based: each response carries meta.cursor, which is
# passed back as ?cursor=. An absent/empty cursor means exhausted. Page
# numbers do NOT work — ?page=N is silently ignored and returns the same rows.
#
# $1 = query string (must include limit=, must NOT include cursor=)
# $2 = optional max records (defaults to _V4_MAX_RECORDS)
#
# NOTE: do not add parseIoAsJson — it is deprecated on v2 and returns 400.
# Input/output always come back as raw strings, so renderers coerce them
# with _V4_COERCE below.
_v4_obs() {
  LF_API="${API}" LF_AUTH="${AUTH}" LF_QUERY="$1" LF_MAX="${2:-$_V4_MAX_RECORDS}" \
  python3 -c '
import base64, json, os, sys, urllib.error, urllib.parse, urllib.request

api   = os.environ["LF_API"]
query = os.environ["LF_QUERY"]
mx    = int(os.environ["LF_MAX"])
hdr   = {"Authorization": "Basic " + base64.b64encode(os.environ["LF_AUTH"].encode()).decode()}

rows, cursor, pages = [], None, 0
while True:
    q = query + ("&cursor=" + urllib.parse.quote(cursor) if cursor else "")
    try:
        with urllib.request.urlopen(urllib.request.Request(f"{api}/v2/observations?{q}", headers=hdr), timeout=60) as r:
            doc = json.load(r)
    except urllib.error.HTTPError as e:
        detail = e.read()[:300].decode("utf-8", "replace")
        sys.stderr.write(f"Langfuse API error {e.code} on /v2/observations: {detail}\n")
        sys.exit(1)
    except Exception as e:
        sys.stderr.write(f"Langfuse request failed: {e}\n")
        sys.exit(1)
    page = doc.get("data") or []
    rows.extend(page)
    pages += 1
    cursor = (doc.get("meta") or {}).get("cursor")
    # Stop on: empty page, exhausted cursor, or cap reached.
    if not page or not cursor or len(rows) >= mx:
        break
if len(rows) >= mx:
    sys.stderr.write(f"note: stopped at the {mx}-record cap after {pages} pages; raise LANGFUSE_MAX_RECORDS for more\n")
json.dump({"data": rows[:mx]}, sys.stdout)
'
}

# Shared python prelude: v4 returns input/output as raw strings, so decode
# them back to objects where possible. Legacy returned parsed JSON already.
_V4_COERCE='
def _load():
    # _v4_obs exits non-zero and reports on stderr when the API call fails,
    # leaving stdin empty. Exit quietly rather than dumping a traceback on
    # top of the message the user already saw.
    raw = sys.stdin.read()
    if not raw.strip():
        sys.exit(1)
    try:
        return json.loads(raw).get("data", [])
    except ValueError:
        sys.stderr.write("Langfuse returned a non-JSON response\n")
        sys.exit(1)

def _j(v):
    if isinstance(v, str):
        s = v.strip()
        if s[:1] in ("{", "["):
            try: return json.loads(s)
            except Exception: return v
    return v
'

_usage() {
  cat <<'EOF'
Usage: langfuse_query.sh <command> [options]

Commands:
  traces   [--limit N] [--name X] [--session-id X]   List recent traces
  trace    <trace-id>                                 Get a single trace (includes observations)
  generations <trace-id>                              Show LLM generations + tool calls for a trace
  observations <trace-id> [--type TYPE]               List observations for a trace
  observation  <obs-id>                               Get a single observation
  sessions [--limit N]                                List sessions        (derived on v4)
  scores   [--trace-id X] [--limit N]                 List scores
  prompts                                             List prompts
  apigen                                              Print the detected API generation

Environment variables (required):
  LANGFUSE_PUBLIC_KEY   Your Langfuse public key
  LANGFUSE_SECRET_KEY   Your Langfuse secret key
  LANGFUSE_BASE_URL     e.g. http://localhost:3000

Optional:
  LANGFUSE_API_GEN      Force "legacy" or "v4" instead of auto-detecting.

API generations:
  The server major version is read once from /api/public/health. Servers
  >= 4 run the v2/v3 read APIs; the v1 endpoints (/traces, /observations,
  /sessions, /scores) return 404 there. Servers <= 3 use the v1 API.

  On v4, `traces` and `sessions` are DERIVED by grouping observations —
  v4 exposes no trace or session read entity. Both label their output.
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# v4 implementations
# ---------------------------------------------------------------------------

# DERIVED. v4 has no trace read entity, so group observations by traceId.
# We over-fetch observations to find enough distinct traces; --limit still
# means "number of traces", matching the legacy contract.
_v4_traces() {
  local limit="$1" name="$2" session_id="$3"
  # sessionId is NOT a supported query filter on v2/observations (it is
  # accepted and silently ignored), so filter it client-side instead.
  _v4_obs "limit=100&fields=${_V4_FIELDS_LIST}" | python3 -c "
import json, sys, collections
${_V4_COERCE}
limit = int(sys.argv[1]); want_name = sys.argv[2]; want_session = sys.argv[3]
rows = _load()
if want_session:
    rows = [r for r in rows if r.get('sessionId') == want_session]
traces = collections.OrderedDict()
for o in sorted(rows, key=lambda r: r.get('startTime',''), reverse=True):
    tid = o.get('traceId')
    if not tid: continue
    t = traces.setdefault(tid, {'n':0,'start':o.get('startTime',''),'names':[],'session':o.get('sessionId',''),'cost':0.0})
    t['n'] += 1
    t['names'].append(o.get('name',''))
    t['cost'] += (o.get('totalCost') or 0)
    if o.get('startTime','') < t['start']: t['start'] = o.get('startTime','')
shown = 0
for tid, t in traces.items():
    root = t['names'][-1] if t['names'] else 'unnamed'
    if want_name and want_name not in t['names']: continue
    print(f\"{t['start'][:19]}  {root}\")
    print(f'  id: {tid}')
    print(f\"  session: {t['session']}  observations: {t['n']}  cost: {t['cost']}\")
    print()
    shown += 1
    if shown >= limit: break
if not shown:
    print('No traces found.')
print('(derived: v4 has no trace entity — grouped from observations)')
" "$limit" "$name" "$session_id"
}

_v4_trace() {
  local trace_id="$1"
  _v4_obs "traceId=${trace_id}&limit=100&fields=${_V4_FIELDS_FULL}" | python3 -c "
import json, sys
${_V4_COERCE}
rows = _load()
if not rows:
    print('No observations found for this trace.'); sys.exit(0)
rows.sort(key=lambda o: o.get('startTime',''))
first = rows[0]
print(f\"Trace: {first.get('name','unnamed')}\")
print(f\"  ID:        {first.get('traceId','')}\")
print(f\"  Session:   {first.get('sessionId','')}\")
print(f\"  Timestamp: {first.get('startTime','')[:19]}\")
print(f\"  Cost:      {sum((o.get('totalCost') or 0) for o in rows)}\")
print()
print(f'Observations ({len(rows)}):')
for obs in rows:
    model = obs.get('model') or ''
    model_str = f' model={model}' if model else ''
    print(f\"  [{obs.get('type','?')}] {obs.get('name','unnamed')}{model_str}  latency={obs.get('latency','?')}s  id={obs.get('id')}\")
    out = _j(obs.get('output'))
    if isinstance(out, dict) and 'tool_calls' in out:
        for tc in out['tool_calls']:
            print(f\"    -> {tc.get('name','')}({json.dumps(tc.get('args', {}))})\")
    elif isinstance(out, dict) and out.get('content'):
        print(f\"    output: {str(out['content'])[:150]}\")
    elif isinstance(out, str) and out:
        print(f'    output: {out[:150]}')
    usage = obs.get('usageDetails') or {}
    if usage.get('input') or usage.get('output'):
        print(f\"    tokens: in={usage.get('input','')} out={usage.get('output','')}\")
print()
"
}

_v4_generations() {
  local trace_id="$1"
  _v4_obs "traceId=${trace_id}&type=GENERATION&limit=100&fields=${_V4_FIELDS_FULL}" | python3 -c "
import json, sys
${_V4_COERCE}
gens = _load()
if not gens:
    print('No generations found for this trace.'); sys.exit(0)
for g in sorted(gens, key=lambda o: o.get('startTime','')):
    print(f\"Generation: {g.get('name','unnamed')}  model={g.get('model','?')}  latency={g.get('latency','?')}s\")
    print(f\"  id: {g.get('id')}\")
    if g.get('promptName'):
        print(f\"  prompt: {g['promptName']} v{g.get('promptVersion','?')}\")
    usage = g.get('usageDetails') or {}
    if usage.get('input') or usage.get('output'):
        print(f\"  tokens: in={usage.get('input','')} out={usage.get('output','')}\")
    inp = _j(g.get('input'))
    msgs = inp.get('messages') if isinstance(inp, dict) else (inp if isinstance(inp, list) else None)
    if isinstance(msgs, list):
        for m in msgs:
            if isinstance(m, dict) and m.get('role') in ('user','human'):
                print(f\"  user input: {str(m.get('content',''))[:200]}\"); break
    elif isinstance(inp, str) and inp:
        print(f'  user input: {inp[:200]}')
    out = _j(g.get('output'))
    if isinstance(out, dict):
        if 'tool_calls' in out:
            print(f\"  tool_calls ({len(out['tool_calls'])}):\")
            for tc in out['tool_calls']:
                print(f\"    - {tc.get('name','')}({json.dumps(tc.get('args', {}))})\")
        elif out.get('content'):
            print(f\"  output: {str(out['content'])[:300]}\")
        else:
            print(f'  output: {json.dumps(out)[:300]}')
    elif isinstance(out, str) and out:
        print(f'  output: {out[:300]}')
    print()
"
}

_v4_observations() {
  local trace_id="$1" type_filter="$2"
  local url="traceId=${trace_id}&limit=100&fields=${_V4_FIELDS_LIST}"
  [[ -n "$type_filter" ]] && url="${url}&type=${type_filter}"
  _v4_obs "$url" | python3 -c "
import json, sys
${_V4_COERCE}
obs_list = _load()
print(f'Observations ({len(obs_list)}):')
for obs in sorted(obs_list, key=lambda o: o.get('startTime','')):
    model = obs.get('model') or ''
    model_str = f'  model={model}' if model else ''
    parent = obs.get('parentObservationId') or ''
    parent_str = f'  parent={parent}' if parent else ''
    print(f\"  [{obs.get('type','?')}] {obs.get('name','unnamed')}{model_str}  latency={obs.get('latency','?')}s  id={obs.get('id')}{parent_str}\")
print()
"
}

# v4 dropped /observations/{id}; the structured filter param is the
# supported way to fetch one by id.
_v4_observation() {
  local obs_id="$1"
  local filter
  filter="$(python3 -c "
import json, sys, urllib.parse
print(urllib.parse.quote(json.dumps([{'column':'id','operator':'=','value':sys.argv[1],'type':'string'}])))
" "$obs_id")"
  _v4_obs "limit=1&fields=${_V4_FIELDS_FULL}&filter=${filter}" 1 | python3 -c "
import json, sys
${_V4_COERCE}
rows = _load()
if not rows:
    print('Observation not found.'); sys.exit(1)
print(json.dumps(rows[0], indent=2))
"
}

# DERIVED. v4 has no session read entity; group observations by sessionId.
_v4_sessions() {
  local limit="$1"
  _v4_obs "limit=100&fields=${_V4_FIELDS_LIST}" | python3 -c "
import json, sys, collections
${_V4_COERCE}
limit = int(sys.argv[1])
rows = _load()
sess = collections.OrderedDict()
for o in sorted(rows, key=lambda r: r.get('startTime',''), reverse=True):
    sid = o.get('sessionId')
    if not sid: continue
    s = sess.setdefault(sid, {'traces': set(), 'start': o.get('startTime','')})
    s['traces'].add(o.get('traceId'))
    if o.get('startTime','') < s['start']: s['start'] = o.get('startTime','')
if not sess:
    print('No sessions found (no observation carried a sessionId).')
else:
    for i, (sid, s) in enumerate(sess.items()):
        if i >= limit: break
        print(f\"{s['start'][:19]}  {sid}  traces={len(s['traces'])}\")
print()
print('(derived: v4 has no session entity — grouped from observations)')
" "$limit"
}

_v4_scores() {
  local limit="$1" trace_id="$2"
  local url="${API}/v3/scores?limit=${limit}"
  [[ -n "$trace_id" ]] && url="${url}&traceId=${trace_id}"
  _curl "$url" | python3 -c "
import json, sys
${_V4_COERCE}
rows = _load()
if not rows:
    print('No scores found.')
for s in rows:
    ts = (s.get('timestamp') or s.get('createdAt') or '')[:19]
    print(f\"{ts}  {s.get('name','')}={s.get('value','')}  trace={s.get('traceId','')}\")
print()
"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_traces() {
  local limit=5 name="" session_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit)  limit="$2"; shift 2 ;;
      --name)   name="$2"; shift 2 ;;
      --session-id) session_id="$2"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  if [[ "$(_api_gen)" == "v4" ]]; then
    _v4_traces "$limit" "$name" "$session_id"; return
  fi

  local url="${API}/traces?limit=${limit}"
  [[ -n "$name" ]] && url="${url}&name=${name}"
  [[ -n "$session_id" ]] && url="${url}&sessionId=${session_id}"

  _curl "$url" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data.get('data', []):
    ts = t.get('timestamp','')[:19]
    name = t.get('name','unnamed')
    sid = t.get('sessionId','')
    tid = t['id']
    lat = t.get('latency','?')
    obs = len(t.get('observations', []))
    cost = t.get('totalCost', 0)
    print(f'{ts}  {name}')
    print(f'  id: {tid}')
    print(f'  session: {sid}  latency: {lat}s  observations: {obs}  cost: {cost}')
    # show input summary if present
    inp = t.get('input')
    if isinstance(inp, dict):
        msgs = inp.get('messages', [])
        if msgs:
            last = msgs[-1]
            content = last.get('content','')[:120]
            print(f'  last input: {content}')
    print()
"
}

cmd_trace() {
  local trace_id="${1:?Usage: trace <trace-id>}"
  if [[ "$(_api_gen)" == "v4" ]]; then _v4_trace "$trace_id"; return; fi
  _curl "${API}/traces/${trace_id}" | python3 -c "
import json, sys
t = json.load(sys.stdin)
print(f\"Trace: {t.get('name','unnamed')}\")
print(f\"  ID:        {t['id']}\")
print(f\"  Session:   {t.get('sessionId','')}\")
print(f\"  Timestamp: {t.get('timestamp','')[:19]}\")
print(f\"  Latency:   {t.get('latency','?')}s\")
print(f\"  Cost:      {t.get('totalCost', 0)}\")
print(f\"  Tags:      {', '.join(t.get('tags', []))}\")

# Show input (last user message)
inp = t.get('input')
if isinstance(inp, dict):
    msgs = inp.get('messages', [])
    if msgs:
        last = msgs[-1]
        print(f\"  Last input ({last.get('type','?')}): {last.get('content','')[:200]}\")

# Show observations summary
obs_list = t.get('observations', [])
print(f\"\nObservations ({len(obs_list)}):\")
for obs in sorted(obs_list, key=lambda o: o.get('startTime','')):
    name = obs.get('name','unnamed')
    otype = obs.get('type','?')
    model = obs.get('model','')
    lat = obs.get('latency','?')
    model_str = f' model={model}' if model else ''
    print(f\"  [{otype}] {name}{model_str}  latency={lat}s  id={obs['id']}\")

    # Show tool calls if present in output
    out = obs.get('output')
    if isinstance(out, dict) and 'tool_calls' in out:
        for tc in out['tool_calls']:
            args = json.dumps(tc.get('args', {}))
            print(f\"    -> {tc.get('name','')}({args})\")
    # Show text output for non-tool generations
    elif isinstance(out, dict) and out.get('content'):
        content = out['content'][:150]
        print(f\"    output: {content}\")

    # Show usage
    usage = obs.get('usageDetails') or {}
    if usage:
        inp_tok = usage.get('input', usage.get('promptTokens', ''))
        out_tok = usage.get('output', usage.get('completionTokens', ''))
        if inp_tok or out_tok:
            print(f\"    tokens: in={inp_tok} out={out_tok}\")
print()
"
}

cmd_generations() {
  local trace_id="${1:?Usage: generations <trace-id>}"
  if [[ "$(_api_gen)" == "v4" ]]; then _v4_generations "$trace_id"; return; fi
  _curl "${API}/observations?traceId=${trace_id}&type=GENERATION&limit=50" | python3 -c "
import json, sys
data = json.load(sys.stdin)
gens = data.get('data', [])
if not gens:
    print('No generations found for this trace.')
    sys.exit(0)

for g in sorted(gens, key=lambda o: o.get('startTime','')):
    name = g.get('name','unnamed')
    model = g.get('model','?')
    lat = g.get('latency','?')
    print(f'Generation: {name}  model={model}  latency={lat}s')
    print(f'  id: {g[\"id\"]}')

    # Token usage
    usage = g.get('usageDetails') or {}
    inp_tok = usage.get('input', usage.get('promptTokens', ''))
    out_tok = usage.get('output', usage.get('completionTokens', ''))
    if inp_tok or out_tok:
        print(f'  tokens: in={inp_tok} out={out_tok}')

    # System prompt (from input messages)
    inp = g.get('input')
    if isinstance(inp, dict):
        msgs = inp.get('messages', [])
        for m in msgs:
            if m.get('role') == 'user' or m.get('type') == 'human':
                content = m.get('content','')[:200]
                print(f'  user input: {content}')
                break

    # Output: tool calls or text
    out = g.get('output')
    if isinstance(out, dict):
        if 'tool_calls' in out:
            print(f'  tool_calls ({len(out[\"tool_calls\"])}):')
            for tc in out['tool_calls']:
                args = json.dumps(tc.get('args', {}))
                print(f'    - {tc.get(\"name\",\"\")}({args})')
        elif out.get('content'):
            print(f'  output: {out[\"content\"][:300]}')
    elif isinstance(out, str):
        print(f'  output: {out[:300]}')

    # Finish reason
    meta = g.get('metadata') or {}
    resp = {}
    if isinstance(out, dict):
        resp = out.get('response_metadata', {})
    finish = resp.get('finish_reason', '')
    if finish:
        print(f'  finish_reason: {finish}')

    print()
"
}

cmd_observations() {
  local trace_id="${1:?Usage: observations <trace-id> [--type TYPE]}"
  shift
  local type_filter=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type) type_filter="$2"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  if [[ "$(_api_gen)" == "v4" ]]; then
    _v4_observations "$trace_id" "$type_filter"; return
  fi

  local url="${API}/observations?traceId=${trace_id}&limit=50"
  [[ -n "$type_filter" ]] && url="${url}&type=${type_filter}"

  _curl "$url" | python3 -c "
import json, sys
data = json.load(sys.stdin)
obs_list = data.get('data', [])
print(f'Observations ({len(obs_list)}):')
for obs in sorted(obs_list, key=lambda o: o.get('startTime','')):
    name = obs.get('name','unnamed')
    otype = obs.get('type','?')
    model = obs.get('model','')
    lat = obs.get('latency','?')
    parent = obs.get('parentObservationId','')
    model_str = f'  model={model}' if model else ''
    parent_str = f'  parent={parent}' if parent else ''
    print(f'  [{otype}] {name}{model_str}  latency={lat}s  id={obs[\"id\"]}{parent_str}')
print()
"
}

cmd_observation() {
  local obs_id="${1:?Usage: observation <obs-id>}"
  if [[ "$(_api_gen)" == "v4" ]]; then _v4_observation "$obs_id"; return; fi
  _curl "${API}/observations/${obs_id}" | _fmt
}

cmd_sessions() {
  local limit=5
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  if [[ "$(_api_gen)" == "v4" ]]; then _v4_sessions "$limit"; return; fi

  _curl "${API}/sessions?limit=${limit}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for s in data.get('data', []):
    sid = s.get('id','')
    created = s.get('createdAt','')[:19]
    traces = len(s.get('traces', []))
    print(f'{created}  {sid}  traces={traces}')
print()
"
}

cmd_scores() {
  local limit=10 trace_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit)    limit="$2"; shift 2 ;;
      --trace-id) trace_id="$2"; shift 2 ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  if [[ "$(_api_gen)" == "v4" ]]; then
    _v4_scores "$limit" "$trace_id"; return
  fi

  local url="${API}/scores?limit=${limit}"
  [[ -n "$trace_id" ]] && url="${url}&traceId=${trace_id}"

  _curl "$url" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for s in data.get('data', []):
    name = s.get('name','')
    value = s.get('value','')
    trace = s.get('traceId','')
    ts = s.get('timestamp','')[:19]
    print(f'{ts}  {name}={value}  trace={trace}')
print()
"
}

cmd_prompts() {
  _curl "${API}/v2/prompts" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for p in data.get('data', []):
    name = p.get('name','')
    ptype = p.get('type','')
    labels = p.get('labels', [])
    versions = p.get('versions', [])
    latest = max(versions) if versions else '?'
    print(f'{name}  type={ptype}  labels={labels}  latest_version={latest}')
print()
"
}

# ---------------------------------------------------------------------------
# Router
# ---------------------------------------------------------------------------
case "${1:-}" in
  traces)       shift; cmd_traces "$@" ;;
  trace)        shift; cmd_trace "$@" ;;
  generations)  shift; cmd_generations "$@" ;;
  observations) shift; cmd_observations "$@" ;;
  observation)  shift; cmd_observation "$@" ;;
  sessions)     shift; cmd_sessions "$@" ;;
  scores)       shift; cmd_scores "$@" ;;
  prompts)      shift; cmd_prompts "$@" ;;
  apigen)       _api_gen ;;
  *)            _usage ;;
esac