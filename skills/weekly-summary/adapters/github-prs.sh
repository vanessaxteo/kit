#!/usr/bin/env bash
# github-prs adapter for weekly-summary skill.
# Usage: github-prs.sh --since <ISO8601|date> [--until <ISO8601|date>]
# Emits JSON on stdout, logs on stderr. Exits non-zero on failure.
#
# Author-centric view (unlike daily-summary's event-based github.sh): the PRs
# *you authored* that merged in the window, plus all your currently-open PRs,
# each enriched with +additions/-deletions.
#
# Uses the raw search API (gh api search/issues):
#   `author:X type:pr is:merged merged:START..END`.
# NB: `gh search prs --merged "A..B"` silently returns nothing — don't use it.

set -euo pipefail

SINCE=""
UNTIL=""
INCLUDE_OPEN=1   # --no-open omits currently-open PRs (use for historical backfill)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --until) UNTIL="$2"; shift 2 ;;
    --no-open) INCLUDE_OPEN=0; shift ;;
    *) echo "github-prs.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$SINCE" ]] || { echo "github-prs.sh: --since is required" >&2; exit 2; }
[[ -n "$UNTIL" ]] || UNTIL="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

command -v gh >/dev/null 2>&1 || { echo "github-prs.sh: gh CLI not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "github-prs.sh: jq not found" >&2; exit 1; }

USER="$(gh api user --jq .login 2>/dev/null)" || {
  echo "github-prs.sh: gh not authenticated (run: gh auth login)" >&2
  exit 1
}

# GitHub's merged: qualifier takes calendar dates (YYYY-MM-DD).
START="${SINCE%%T*}"
END="${UNTIL%%T*}"
echo "github-prs.sh: user=$USER merged:${START}..${END}" >&2

# Run a raw issues search and fail loudly (rather than emit an empty array,
# which would fabricate a quiet week) on rate limits / auth errors.
# Prints a normalized array: [{number, repo, url, title, createdAt, closedAt}]
search_issues() {
  local desc="$1" q="$2" out
  if ! out="$(gh api -X GET search/issues --raw-field q="$q" --raw-field per_page=100 2>&1)"; then
    echo "github-prs.sh: $desc search failed: $out" >&2
    return 1
  fi
  if ! printf '%s' "$out" | jq -e 'has("items")' >/dev/null 2>&1; then
    echo "github-prs.sh: $desc search returned no items: $out" >&2
    return 1
  fi
  printf '%s' "$out" | jq '[.items[] | {
    number,
    repo: (.repository_url | sub("https://api.github.com/repos/";"")),
    url: .html_url,
    title,
    createdAt: .created_at,
    closedAt: .closed_at
  }]'
}

MERGED_LIST="$(search_issues merged "author:${USER} type:pr is:merged merged:${START}..${END}")" || exit 1
if [[ "$INCLUDE_OPEN" -eq 1 ]]; then
  OPEN_LIST="$(search_issues open "author:${USER} type:pr is:open")" || exit 1
else
  OPEN_LIST='[]'
fi

# Enrich the normalized search array with +additions/-deletions (and mergedAt)
# from `gh pr view`. $1 = array, $2 = "true"|"false" open flag.
enrich() {
  local list="$1" is_open="$2" count i base repo num stats first
  count="$(printf '%s' "$list" | jq 'length')"
  printf '['
  first=1
  for ((i = 0; i < count; i++)); do
    base="$(printf '%s' "$list" | jq -c ".[$i]")"
    repo="$(printf '%s' "$base" | jq -r '.repo')"
    num="$(printf '%s' "$base" | jq -r '.number')"
    stats="$(gh pr view "$num" --repo "$repo" --json additions,deletions,mergedAt 2>/dev/null || echo '{}')"
    [[ $first -eq 1 ]] && first=0 || printf ','
    jq -cn --argjson b "$base" --argjson s "$stats" --argjson open "$is_open" '{
      repo: $b.repo,
      title: $b.title,
      url: $b.url,
      additions: ($s.additions // 0),
      deletions: ($s.deletions // 0),
      createdAt: $b.createdAt,
      mergedAt: ($s.mergedAt // $b.closedAt),
      open: $open
    }'
  done
  printf ']'
}

MERGED="$(enrich "$MERGED_LIST" false | jq '.')"
OPEN="$(enrich "$OPEN_LIST" true | jq '.')"

MERGED_N="$(printf '%s' "$MERGED" | jq 'length')"
OPEN_N="$(printf '%s' "$OPEN" | jq 'length')"
echo "github-prs.sh: merged=${MERGED_N} open=${OPEN_N}" >&2

jq -n \
  --arg source "github-prs" \
  --arg since "$SINCE" \
  --arg until "$UNTIL" \
  --arg user "$USER" \
  --argjson merged "$MERGED" \
  --argjson open "$OPEN" \
  '{source:$source, since:$since, until:$until, user:$user, merged:$merged, open:$open}'
