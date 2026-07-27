#!/usr/bin/env bash
# Authenticated caller for Linear's MCP server, reusing the mcp-remote OAuth cache.
# Usage: linear-mcp.sh list-tools | call <tool-name> '<json-arguments>'
#
# Why MCP and not the GraphQL API: many orgs disable personal API keys (PATs).
# One-time setup (opens a browser for consent):
#   npx -y mcp-remote https://mcp.linear.app/mcp
#   ...complete the login, then Ctrl+C. The token is cached under ~/.mcp-auth.

set -euo pipefail

MCP_URL="https://mcp.linear.app/mcp"
TOKEN_URL="https://mcp.linear.app/token"

MODE="${1:-}"
TOOL=""
ARGS=""
case "$MODE" in
  list-tools) ;;
  call)
    TOOL="${2:-}"
    ARGS="${3:-}"
    [[ -n "$TOOL" ]] || { echo "usage: linear-mcp.sh call <tool> '<json-args>'" >&2; exit 2; }
    [[ -n "$ARGS" ]] || ARGS='{}'
    ;;
  *) echo "usage: linear-mcp.sh list-tools | call <tool> '<json-args>'" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1   || { echo "linear-mcp.sh: jq not found" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "linear-mcp.sh: curl not found" >&2; exit 1; }

# mcp-remote derives its token cache dir from md5(url)
if command -v md5 >/dev/null 2>&1; then
  URL_HASH="$(printf '%s' "$MCP_URL" | md5)"
else
  URL_HASH="$(printf '%s' "$MCP_URL" | md5sum | awk '{print $1}')"
fi

TOKENS_FILE="$(ls -t "$HOME"/.mcp-auth/mcp-remote-*/"${URL_HASH}_tokens.json" 2>/dev/null | head -1 || true)"
if [[ -z "$TOKENS_FILE" || ! -f "$TOKENS_FILE" ]]; then
  echo "linear-mcp.sh: no Linear MCP token found. Authorize once with:" >&2
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
  echo "linear-mcp.sh: access token rejected, refreshing..." >&2
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

# rpc <method> <params-json> -> prints the JSON-RPC .result on stdout.
rpc() {
  local method="$1" params="$2" body tmp code raw attempt payload
  body="$(jq -n --arg m "$method" --argjson p "$params" \
    '{jsonrpc:"2.0",id:1,method:$m,params:$p}')"
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
        echo "linear-mcp.sh: refresh failed. Re-authorize: npx -y mcp-remote $MCP_URL" >&2
        return 1
      }
      continue
    fi
    if [[ "$code" != "200" ]]; then
      echo "linear-mcp.sh: '$method' failed (HTTP $code)" >&2
      return 1
    fi
    # streamable-HTTP responses are SSE `data:` lines; plain JSON also possible
    payload="$(printf '%s' "$raw" | sed -n 's/^data: //p' | jq -c 'select(.id==1)' 2>/dev/null | tail -1)"
    [[ -n "$payload" ]] || payload="$raw"
    if printf '%s' "$payload" | jq -e '.error' >/dev/null 2>&1; then
      printf '%s' "$payload" | jq -r '"linear-mcp.sh: \(.error.message // .error)"' >&2
      return 1
    fi
    printf '%s' "$payload" | jq '.result'
    return 0
  done
}

if [[ "$MODE" == "list-tools" ]]; then
  rpc tools/list '{}' | jq '[.tools[]
    | select(.name | test("issue|team|status|label|user|save"; "i"))
    | {name, description: ((.description // "") | split("\n")[0]), input: .inputSchema}]'
else
  RESULT="$(rpc tools/call "$(jq -n --arg n "$TOOL" --argjson a "$ARGS" '{name:$n,arguments:$a}')")" || exit 1
  if printf '%s' "$RESULT" | jq -e '.isError == true' >/dev/null 2>&1; then
    printf '%s' "$RESULT" | jq -r '.content[0].text // "tool error"' >&2
    exit 1
  fi
  TEXT="$(printf '%s' "$RESULT" | jq -r '.content[0].text // empty')"
  if [[ -n "$TEXT" ]]; then printf '%s\n' "$TEXT"; else printf '%s\n' "$RESULT"; fi
fi
