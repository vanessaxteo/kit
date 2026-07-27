#!/usr/bin/env bash
# linear adapter for daily-summary skill (Linear MCP over OAuth).
# Usage: linear.sh --since <ISO8601> [--until <ISO8601>]
# Emits JSON on stdout, logs on stderr. Exits non-zero on failure.
#
# Why MCP and not the GraphQL API: many orgs disable personal API keys (PATs).
# Linear's MCP server uses OAuth instead. We mint a token via the already-
# approved "MCP" OAuth app, talk JSON-RPC to https://mcp.linear.app/mcp, and
# refresh the token ourselves when it expires. No long-lived agent holds the
# token, so Linear is reachable ONLY when this adapter runs.
#
# One-time setup (opens a browser for consent):
#   npx -y mcp-remote https://mcp.linear.app/mcp
#   ...complete the login, then Ctrl+C. The token is cached under ~/.mcp-auth.

set -euo pipefail

MCP_URL="https://mcp.linear.app/mcp"
TOKEN_URL="https://mcp.linear.app/token"

SINCE=""
UNTIL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --until) UNTIL="$2"; shift 2 ;;
    *) echo "linear.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$SINCE" ]] || { echo "linear.sh: --since is required" >&2; exit 2; }
[[ -n "$UNTIL" ]] || UNTIL="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

command -v jq >/dev/null 2>&1   || { echo "linear.sh: jq not found" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "linear.sh: curl not found" >&2; exit 1; }

# --- locate the OAuth token cache (mcp-remote derives the dir from md5(url)) ---
if command -v md5 >/dev/null 2>&1; then
  URL_HASH="$(printf '%s' "$MCP_URL" | md5)"
else
  URL_HASH="$(printf '%s' "$MCP_URL" | md5sum | awk '{print $1}')"
fi

TOKENS_FILE="$(ls -t "$HOME"/.mcp-auth/mcp-remote-*/"${URL_HASH}_tokens.json" 2>/dev/null | head -1 || true)"
if [[ -z "$TOKENS_FILE" || ! -f "$TOKENS_FILE" ]]; then
  echo "linear.sh: no Linear MCP token found. Authorize once with:" >&2
  echo "  npx -y mcp-remote $MCP_URL" >&2
  echo "  (complete the browser login, then Ctrl+C)" >&2
  exit 1
fi
PREFIX="${TOKENS_FILE%_tokens.json}"
CLIENT_INFO="${PREFIX}_client_info.json"
ACCESS="$(jq -r '.access_token // ""' "$TOKENS_FILE")"

refresh_access_token() {
  local rt cid resp
  rt="$(jq -r '.refresh_token // ""' "$TOKENS_FILE")"
  cid="$(jq -r '.client_id // ""' "$CLIENT_INFO" 2>/dev/null)"
  [[ -n "$rt" && -n "$cid" ]] || return 1
  echo "linear.sh: access token rejected, refreshing..." >&2
  resp="$(curl -sS -X POST "$TOKEN_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "refresh_token=$rt" \
    --data-urlencode "client_id=$cid")" || return 1
  echo "$resp" | jq -e '.access_token' >/dev/null 2>&1 || return 1
  printf '%s' "$resp" > "$TOKENS_FILE"   # refresh token rotates; persist the new one
  ACCESS="$(echo "$resp" | jq -r '.access_token')"
  return 0
}

# mcp_tool <name> <arguments-json> -> prints the tool's text payload (JSON) on stdout.
# Retries once through a token refresh on HTTP 401.
mcp_tool() {
  local name="$1" args="$2" body tmp code raw attempt
  body="$(jq -n --arg n "$name" --argjson a "$args" \
    '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$n,arguments:$a}}')"
  for attempt in 1 2; do
    tmp="$(mktemp)"
    code="$(curl -sS -o "$tmp" -w '%{http_code}' -X POST "$MCP_URL" \
      -H "Authorization: Bearer $ACCESS" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json, text/event-stream" \
      -d "$body" 2>/dev/null || echo 000)"
    raw="$(cat "$tmp")"; rm -f "$tmp"
    if [[ "$code" == "401" && "$attempt" == "1" ]]; then
      refresh_access_token || {
        echo "linear.sh: refresh failed. Re-authorize: npx -y mcp-remote $MCP_URL" >&2
        return 1
      }
      continue
    fi
    if [[ "$code" != "200" ]]; then
      echo "linear.sh: MCP call '$name' failed (HTTP $code)" >&2
      return 1
    fi
    # streamable-HTTP responses are SSE: a `data: {json-rpc}` line.
    local payload
    payload="$(printf '%s' "$raw" | sed -n 's/^data: //p' | jq -r '.result.content[0].text // empty')"
    [[ -n "$payload" ]] || { echo "linear.sh: unexpected MCP response for '$name'" >&2; return 1; }
    printf '%s' "$payload"
    return 0
  done
}

echo "linear.sh: since=$SINCE until=$UNTIL" >&2

# Issues assigned to me, updated since the window start. list_issues' updatedAt
# is a lower bound only, so we trim the upper bound (UNTIL) client-side.
UPDATED_RAW="$(mcp_tool list_issues \
  "$(jq -n --arg s "$SINCE" '{assignee:"me",updatedAt:$s,orderBy:"updatedAt",limit:100}')")" || exit 1

ISSUES="$(echo "$UPDATED_RAW" | jq '.issues // []')"

# My user id = assigneeId on any of these (they're all assigned to me).
MYID="$(echo "$ISSUES" | jq -r '[.[].assigneeId] | (.[0] // "")')"

# Project a compact, useful shape and trim to the window's upper bound.
UPDATED="$(echo "$ISSUES" | jq --arg until "$UNTIL" '
  map(select(.updatedAt < $until))
  | map({
      identifier: .id, title, url,
      status, statusType,
      priority: (.priority.name // .priority),
      createdAt, updatedAt, startedAt, completedAt, canceledAt,
      project, team,
      createdBy, createdById, assignee
    })
')"

# Issues I created within the window (derived from the same set; the MCP
# list_issues tool has no creator filter, so issues I created but assigned to
# someone else are not captured here).
CREATED="$(echo "$UPDATED" | jq --arg since "$SINCE" --arg until "$UNTIL" --arg me "$MYID" '
  map(select(.createdById == $me and .createdAt >= $since and .createdAt < $until))
')"

UPDATED_N="$(echo "$UPDATED" | jq 'length')"
CREATED_N="$(echo "$CREATED" | jq 'length')"
echo "linear.sh: updated=$UPDATED_N created=$CREATED_N in window" >&2

jq -n \
  --arg source "linear" \
  --arg since "$SINCE" \
  --arg until "$UNTIL" \
  --argjson updated "$UPDATED" \
  --argjson created "$CREATED" \
  '{
    source: $source,
    since: $since,
    until: $until,
    issues_updated: $updated,
    issues_created: $created
  }'
