#!/usr/bin/env bash
# slack adapter for daily-summary skill.
# Usage: slack.sh --since <ISO8601> [--until <ISO8601>]
# Emits JSON on stdout, logs on stderr. Exits non-zero on failure.
#
# Reuses the logged-in Slack DESKTOP app session (no bot/admin approval):
# extracts a fresh web token (xoxc) + 'd' cookie (xoxd) on every run, since
# they rotate, then queries search.messages for what you sent / were tagged in.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HOME/.local/share/daily-summary/venv/bin/python"
[[ -x "$PY" ]] || PY="python3"

SINCE=""
UNTIL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --until) UNTIL="$2"; shift 2 ;;
    *) echo "slack.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$SINCE" ]] || { echo "slack.sh: --since is required" >&2; exit 2; }
[[ -n "$UNTIL" ]] || UNTIL="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "slack.sh: extracting live session token from Slack desktop app" >&2
TOKENS_JSON="$("$PY" "$DIR/slack-tokens.py")" || {
  echo "slack.sh: could not read Slack session (open the Slack desktop app and sign in)" >&2
  exit 1
}

USER_NAME="$(echo "$TOKENS_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("user",""))')"
echo "slack.sh: user=$USER_NAME since=$SINCE until=$UNTIL" >&2

OUT="$(echo "$TOKENS_JSON" | "$PY" "$DIR/slack-query.py" --since "$SINCE" --until "$UNTIL")" || {
  echo "slack.sh: query failed" >&2
  exit 1
}

SENT="$(echo "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["messages_sent_count"])')"
echo "slack.sh: $SENT messages sent in window" >&2
echo "$OUT"
