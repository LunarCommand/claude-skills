#!/usr/bin/env bash
# HyperDX CLI Log Query Tool (bash version)
# Dependencies: curl, jq, docker (local mode only)
# --------------------------------------------------------------------------
# Usage:
#     # Query all services for errors in the last 5 minutes (cloud)
#     hdx_query.sh --query "level:err"
#
#     # Multiple --query terms are OR'd together
#     hdx_query.sh --service "web-api" \
#         --query "request completed" \
#         --query "job finished" \
#         --query "status:500"
#
#     # Query local HyperDX instance (via ClickHouse in Docker)
#     hdx_query.sh --local --query "level:error"
#     hdx_query.sh --local --service worker --query "TraceId:abc123"
#
#     # Query local traces
#     hdx_query.sh --local --table traces --query "SpanName:call_model"
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
QUERIES=()
SERVICE=""
API_KEY=""
MINUTES=5
LIMIT=10
BASE_URL="https://api.hyperdx.io"
LOCAL=false
CONTAINER="hdx-local"
TABLE="logs"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --query|-q)    QUERIES+=("$2"); shift 2 ;;
    --service|-s)  SERVICE="$2"; shift 2 ;;
    --api-key|-k)  API_KEY="$2"; shift 2 ;;
    --minutes|-t)  MINUTES="$2"; shift 2 ;;
    --limit|-l)    LIMIT="$2"; shift 2 ;;
    --url)         BASE_URL="$2"; shift 2 ;;
    --local)       LOCAL=true; shift ;;
    --container)   CONTAINER="$2"; shift 2 ;;
    --table)       TABLE="$2"; shift 2 ;;
    *)             echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ ${#QUERIES[@]} -eq 0 ]]; then
  echo "Error: at least one --query is required" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build query string: OR multiple terms together
# ---------------------------------------------------------------------------
build_query_string() {
  if [[ ${#QUERIES[@]} -eq 1 ]]; then
    echo "${QUERIES[0]}"
    return
  fi
  local parts=()
  for t in "${QUERIES[@]}"; do
    if [[ "$t" == *" "* && "$t" != \"* ]]; then
      parts+=("\"$t\"")
    else
      parts+=("$t")
    fi
  done
  # Join with a literal " OR ". NOTE: `local IFS=" OR "; "${parts[*]}"` does NOT
  # work — array-star join uses only the FIRST character of IFS (a space), so the
  # "OR" is dropped and the terms collapse into one blob that matches nothing.
  local out="${parts[0]}"
  local i
  for ((i = 1; i < ${#parts[@]}; i++)); do
    out+=" OR ${parts[i]}"
  done
  echo "$out"
}

QUERY_STRING=$(build_query_string)

# ---------------------------------------------------------------------------
# Cloud mode: HyperDX REST API via curl + jq
# ---------------------------------------------------------------------------
query_cloud() {
  local final_query="$QUERY_STRING"
  if [[ -n "$SERVICE" ]]; then
    if [[ -n "$final_query" && "$final_query" != "*" ]]; then
      final_query="service:\"$SERVICE\" AND ($final_query)"
    else
      final_query="service:\"$SERVICE\""
    fi
  fi

  local now_ms
  now_ms=$(( $(date +%s) * 1000 ))
  local start_ms=$(( now_ms - MINUTES * 60 * 1000 ))

  local payload
  payload=$(cat <<EOJSON
{
  "series": [
    {
      "dataSource": "events",
      "where": $(printf '%s' "$final_query" | jq -Rs .),
      "aggFn": "count",
      "limit": $LIMIT
    }
  ],
  "startTime": $start_ms,
  "endTime": $now_ms,
  "granularity": "1 minute"
}
EOJSON
)

  local url="${BASE_URL%/}/api/v1/charts/series"

  local http_response
  http_response=$(curl -sf -w "\n%{http_code}" \
    -X POST "$url" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>&1) || true

  local http_code
  http_code=$(echo "$http_response" | tail -1)
  local body
  body=$(echo "$http_response" | sed '$d')

  if [[ "$http_code" == "401" ]]; then
    echo "Error: Unauthorized. Check your HYPERDX_LOCAL_API_KEY in .agent.env."
    return
  fi
  if [[ "$http_code" != "200" ]]; then
    echo "HTTP Error ($http_code): $body"
    return
  fi

  local events
  events=$(echo "$body" | jq -r '.data[0].samples // []')
  if [[ "$events" == "[]" || "$events" == "null" ]]; then
    echo "No logs found matching: '$QUERY_STRING' in the last ${MINUTES}m."
    return
  fi

  echo "$events" | jq -r '
    .[] |
    (.["_timestamp"] // .timestamp // "N/A") as $ts |
    (.service // "unknown-svc") as $svc |
    ((.level // "INFO") | ascii_upcase) as $lvl |
    (.body // .message // (. | tostring)) as $raw_body |
    (
      try (
        ($raw_body | fromjson) as $parsed |
        ($parsed.event // $parsed.message // $raw_body) as $msg |
        ($parsed | to_entries | map(
          select(.key != "event" and .key != "message" and .key != "timestamp"
                 and .key != "level" and .key != "logger")
          | "\(.key)=\(if .value == null then "null" elif .value == "" then "\"\"" else .value end)"
        ) | join(" ")) as $extras |
        if ($extras | length) > 0 then "\($msg) | \($extras)" else $msg end
      ) catch $raw_body
    ) as $msg |
    "[\($ts)] [\($svc)] \($lvl): \($msg)"
  '
}

# ---------------------------------------------------------------------------
# Local mode: ClickHouse via docker exec
# ---------------------------------------------------------------------------
clickhouse_query() {
  local sql="$1"
  docker exec -i "$CONTAINER" \
    curl -sf "http://localhost:8123/" --data-binary @- <<< "$sql" 2>&1 || {
    echo "ClickHouse error: docker exec failed" >&2
    return 1
  }
}

build_time_filter() {
  local ts_col="${1:-Timestamp}"
  # Compute the window with ClickHouse's OWN clock (now()) rather than the host
  # clock: the two can drift (e.g. after the Docker VM sleeps/resumes), and a
  # host-computed window then silently excludes rows the container timestamped on
  # its own clock. No upper bound — "last N minutes" means "since then", and a
  # second-precision upper bound would drop the newest sub-second rows.
  echo "$ts_col >= now() - INTERVAL $MINUTES MINUTE"
}

# Build a single ClickHouse WHERE clause for one term — either `field:value`
# (mapped to a column or an attribute-map lookup) or free text (a Body/SpanName
# ILIKE). Echoes nothing for an empty term.
build_term_clause() {
  local part="$1"
  local tbl="$2"
  local body_col="$3"

  part=$(echo "$part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -z "$part" ]] && return

  if [[ "$part" == *":"* && "$part" != \"* ]]; then
    local field="${part%%:*}"
    local value="${part#*:}"
    value=$(echo "$value" | sed "s/^[\"']//;s/[\"']$//")

    local ch_col=""
    local field_lower
    field_lower=$(echo "$field" | tr '[:upper:]' '[:lower:]')

    if [[ "$tbl" == "logs" ]]; then
      case "$field_lower" in
        level|severity) ch_col="SeverityText" ;;
        service)        ch_col="ServiceName" ;;
        traceid)        ch_col="TraceId" ;;
        spanid)         ch_col="SpanId" ;;
        body|message)   ch_col="Body" ;;
      esac
    else
      case "$field_lower" in
        service)      ch_col="ServiceName" ;;
        traceid)      ch_col="TraceId" ;;
        spanid)       ch_col="SpanId" ;;
        parentspanid) ch_col="ParentSpanId" ;;
        spanname)     ch_col="SpanName" ;;
        spankind)     ch_col="SpanKind" ;;
        statuscode)   ch_col="StatusCode" ;;
      esac
    fi

    if [[ -n "$ch_col" ]]; then
      echo "$ch_col = '$value'"
    else
      local attr_col
      [[ "$tbl" == "logs" ]] && attr_col="LogAttributes" || attr_col="SpanAttributes"
      echo "${attr_col}['$field'] = '$value'"
    fi
  else
    local term
    term=$(echo "$part" | sed "s/^[\"']//;s/[\"']$//")
    echo "$body_col ILIKE '%${term}%'"
  fi
}

# Convert a simple Lucene-style query to a ClickHouse WHERE fragment. Grammar is
# a disjunction of conjunctions: `a AND b OR c` → `(a AND b) OR (c)`. Multiple
# --query terms arrive already OR-joined by build_query_string.
parse_lucene_to_where() {
  local query="$1"
  local tbl="$2"

  if [[ -z "$query" || "$query" == "*" ]]; then
    echo "1=1"
    return
  fi

  local body_col
  [[ "$tbl" == "logs" ]] && body_col="Body" || body_col="SpanName"

  local IFS_OLD="$IFS"

  # Split on OR (case-insensitive) into groups; \x02 is just a private delimiter.
  local or_normalized
  or_normalized=$(echo "$query" | sed -E 's/ [Oo][Rr] /\x02/g')
  local or_groups=()
  IFS=$'\x02' read -ra or_groups <<< "$or_normalized"
  IFS="$IFS_OLD"

  local group_sql=()
  local group
  for group in "${or_groups[@]}"; do
    # Within a group, split on AND (\x01 private delimiter) and AND the clauses.
    local and_normalized
    and_normalized=$(echo "$group" | sed -E 's/ [Aa][Nn][Dd] /\x01/g')
    local and_parts=()
    IFS=$'\x01' read -ra and_parts <<< "$and_normalized"
    IFS="$IFS_OLD"

    local clauses=()
    local part clause
    for part in "${and_parts[@]}"; do
      clause=$(build_term_clause "$part" "$tbl" "$body_col")
      [[ -n "$clause" ]] && clauses+=("$clause")
    done

    if [[ ${#clauses[@]} -gt 0 ]]; then
      # Manual " AND " join — the IFS-star trick joins on IFS's first char only.
      local joined="${clauses[0]}"
      local j
      for ((j = 1; j < ${#clauses[@]}; j++)); do
        joined+=" AND ${clauses[j]}"
      done
      group_sql+=("($joined)")
    fi
  done

  if [[ ${#group_sql[@]} -eq 0 ]]; then
    echo "1=1"
    return
  fi

  # Manual " OR " join across groups.
  local out="${group_sql[0]}"
  local k
  for ((k = 1; k < ${#group_sql[@]}; k++)); do
    out+=" OR ${group_sql[k]}"
  done
  echo "$out"
}

query_local_logs() {
  local time_filter
  time_filter=$(build_time_filter "Timestamp")
  local lucene_filter
  lucene_filter=$(parse_lucene_to_where "$QUERY_STRING" "logs")

  # Parenthesize: the filter may be an OR of groups, and SQL AND binds tighter
  # than OR — without parens the time/service constraints would only apply to the
  # first/last OR arm, letting the middle terms match every service and all time.
  local where="$time_filter AND ($lucene_filter)"
  [[ -n "$SERVICE" ]] && where="$where AND ServiceName = '$SERVICE'"

  local sql="SELECT Timestamp, ServiceName, SeverityText, Body FROM otel_logs WHERE $where ORDER BY Timestamp DESC LIMIT $LIMIT FORMAT JSONEachRow"

  local raw
  raw=$(clickhouse_query "$sql") || return 1

  if [[ -z "${raw// /}" ]]; then
    echo "No logs found matching: '$QUERY_STRING' in the last ${MINUTES}m."
    return
  fi

  echo "$raw" | jq -r '
    (.Timestamp // "N/A") as $ts |
    (.ServiceName // "unknown-svc") as $svc |
    ((.SeverityText // "INFO") | ascii_upcase) as $lvl |
    (.Body // "") as $raw_body |
    (
      try (
        ($raw_body | fromjson) as $parsed |
        ($parsed.event // $parsed.message // $raw_body) as $msg |
        ($parsed | to_entries | map(
          select(.key != "event" and .key != "message" and .key != "timestamp"
                 and .key != "level" and .key != "logger")
          | "\(.key)=\(if .value == null then "null" elif .value == "" then "\"\"" else .value end)"
        ) | join(" ")) as $extras |
        if ($extras | length) > 0 then "\($msg) | \($extras)" else $msg end
      ) catch $raw_body
    ) as $msg |
    "[\($ts)] [\($svc)] \($lvl): \($msg)"
  '
}

query_local_traces() {
  local time_filter
  time_filter=$(build_time_filter "Timestamp")
  local lucene_filter
  lucene_filter=$(parse_lucene_to_where "$QUERY_STRING" "traces")

  # Parenthesize — see query_local_logs: AND binds tighter than OR, so an
  # unparenthesized OR filter would let middle arms escape the time/service scope.
  local where="$time_filter AND ($lucene_filter)"
  [[ -n "$SERVICE" ]] && where="$where AND ServiceName = '$SERVICE'"

  local sql="SELECT Timestamp, SpanName, SpanKind, ServiceName, Duration, StatusCode, SpanAttributes FROM otel_traces WHERE $where ORDER BY Timestamp DESC LIMIT $LIMIT FORMAT JSONEachRow"

  local raw
  raw=$(clickhouse_query "$sql") || return 1

  if [[ -z "${raw// /}" ]]; then
    echo "No traces found matching: '$QUERY_STRING' in the last ${MINUTES}m."
    return
  fi

  echo "$raw" | jq -r '
    (.Timestamp // "N/A") as $ts |
    (.ServiceName // "unknown-svc") as $svc |
    (.SpanName // "?") as $span |
    (.SpanKind // "?") as $kind |
    ((.Duration // 0) / 1000000) as $dur_ms |
    (.StatusCode // "") as $status |
    "[\($ts)] [\($svc)] \($span) (\($kind)) \($dur_ms | floor)ms \($status)"
  '
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [[ "$LOCAL" == true ]]; then
  if [[ "$TABLE" == "traces" ]]; then
    query_local_traces
  else
    query_local_logs
  fi
else
  if [[ -z "$API_KEY" ]]; then
    API_KEY="${HYPERDX_LOCAL_API_KEY:-}"
  fi
  if [[ -z "$API_KEY" ]]; then
    echo "Error: No API key found. Set HYPERDX_LOCAL_API_KEY in .agent.env or pass --api-key."
    exit 1
  fi
  query_cloud
fi
