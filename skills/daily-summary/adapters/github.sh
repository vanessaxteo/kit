#!/usr/bin/env bash
# github adapter for daily-summary skill.
# Usage: github.sh --since <ISO8601> [--until <ISO8601>]
# Emits JSON on stdout, logs on stderr. Exits non-zero on failure.

set -euo pipefail

SINCE=""
UNTIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --until) UNTIL="$2"; shift 2 ;;
    *) echo "github.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SINCE" ]]; then
  echo "github.sh: --since is required" >&2
  exit 2
fi

if [[ -z "$UNTIL" ]]; then
  UNTIL="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "github.sh: gh CLI not found" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "github.sh: jq not found" >&2
  exit 1
fi

USER="$(gh api user --jq .login 2>/dev/null)" || {
  echo "github.sh: gh not authenticated (run: gh auth login)" >&2
  exit 1
}

echo "github.sh: user=$USER since=$SINCE until=$UNTIL" >&2

# /users/{user}/events returns up to ~300 events / 90 days, newest first.
# --paginate emits one JSON array per page; jq -s 'add' concatenates them.
EVENTS_RAW="$(gh api --paginate "/users/$USER/events?per_page=100" 2>/dev/null || echo '[]')"
EVENTS="$(echo "$EVENTS_RAW" | jq -s --arg since "$SINCE" --arg until "$UNTIL" '
  (if length == 0 then [] else add end)
  | map(select(.created_at >= $since and .created_at < $until))
')"

EVENT_COUNT="$(echo "$EVENTS" | jq 'length')"
echo "github.sh: $EVENT_COUNT events in window" >&2

# Review-requested PRs (don't show in your own events feed).
# gh search updated filter takes date or ISO8601; date prefix is the safe form.
SINCE_DATE="${SINCE%%T*}"
REVIEW_REQUESTED="$(gh search prs \
  --review-requested "@me" \
  --updated ">=${SINCE_DATE}" \
  --state open \
  --json url,title,repository,updatedAt,author,isDraft,number \
  2>/dev/null || echo '[]')"

RR_COUNT="$(echo "$REVIEW_REQUESTED" | jq 'length')"
echo "github.sh: $RR_COUNT open PRs awaiting your review" >&2

jq -n \
  --arg source "github" \
  --arg since "$SINCE" \
  --arg until "$UNTIL" \
  --arg user "$USER" \
  --argjson events "$EVENTS" \
  --argjson review_requested "$REVIEW_REQUESTED" \
  '{
    source: $source,
    since: $since,
    until: $until,
    user: $user,
    events: $events,
    review_requested: $review_requested
  }'
