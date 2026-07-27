---
name: daily-summary
description: Generate a markdown daily-activity summary from dev tooling (github, slack, linear; calendar later). Use when the user says "daily summary", "what did I do today", "what's happened since I last checked", or invokes `/daily-summary`.
user-invocable: true
---

# Daily Summary

Generate a markdown summary of activity since the last checkpoint, using parallel adapters plus freeform follow-up queries. You drive — the adapters give you a map, not the final answer.

## Steps

1. **Determine the window.**
   - Capture `NOW` once at run start: `NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)`. Reuse this value for `--until` and the new checkpoint — don't re-query later.
   - Read `~/.local/state/daily-summary/checkpoint.json`. If absent or unreadable, fall back to 24h ago: `SINCE=$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ)`.
   - Tell the user the window in one line before running adapters.

2. **Fan out adapters in parallel.**
   ```bash
   TMP=$(mktemp -d)
   ADAPTERS=~/.agents/skills/daily-summary/adapters
   "$ADAPTERS/github.sh" --since "$SINCE" --until "$NOW" > "$TMP/github.json" 2> "$TMP/github.err" &
   "$ADAPTERS/slack.sh"  --since "$SINCE" --until "$NOW" > "$TMP/slack.json"  2> "$TMP/slack.err"  &
   "$ADAPTERS/linear.sh" --since "$SINCE" --until "$NOW" > "$TMP/linear.json" 2> "$TMP/linear.err" &
   wait
   ```
   If an adapter exits non-zero, note it to the user and continue with whatever succeeded. Do NOT advance the checkpoint if every adapter failed.

3. **Read each adapter's JSON.** This is your working memory — keep it loaded so you can answer follow-up questions without re-querying.

4. **Dig in.** The adapter output is a map. Use `gh pr view`, `gh pr diff`, `gh api`, `git log`, etc. to investigate anything that needs detail: draft→ready transitions, comment threads with back-and-forth, large diffs, unusual repos. The summary should reflect *understanding* of the work, not a transcription of event types.

5. **Write the summary** to `~/notes/daily-summaries/<YYYY-MM-DD>.md` (date = today, UTC; change this path to taste). `mkdir -p` the parent. If the file already exists, **append** a new section — don't overwrite. Section header:
   ```markdown
   ## Run at HH:MM UTC — covers SINCE → NOW
   ```

6. **Structure within a run section:**
   - Prose grouped by repo or project, not raw event bullets.
   - Lead with the most significant work (the thing you'd mention first if asked "what did you do today").
   - Link PRs/issues with full URLs so they're clickable.
   - If nothing happened in the window, say that explicitly in one line — don't pad.

7. **Advance the checkpoint** only after the summary file is successfully written:
   ```bash
   mkdir -p ~/.local/state/daily-summary
   printf '{"last_run": "%s"}\n' "$NOW" > ~/.local/state/daily-summary/checkpoint.json
   ```

8. Print the summary file path to the user.

## Adapters

- **github.sh** — your GitHub events + open PRs awaiting review (`gh` CLI).
- **linear.sh** — Linear issues assigned to you that changed in the window
  (`issues_updated`) plus the subset you created (`issues_created`), via the
  Linear **MCP** server over OAuth (works where orgs disable personal API keys).
  Auth is a one-time browser login: `npx -y mcp-remote https://mcp.linear.app/mcp`
  (complete login, then Ctrl+C). The token caches under `~/.mcp-auth` and the
  adapter refreshes it automatically. No long-lived agent holds the token, so
  Linear is reachable only while this adapter runs. Note: MCP's `list_issues` has no
  creator filter, so issues you created but assigned to others aren't captured,
  and comment history isn't included.
- **slack.sh** — Slack messages you sent and mentions of you, per channel/DM.
  Reuses the logged-in Slack **desktop app** session (no bot/admin approval):
  it extracts a fresh web token (`xoxc`) + `d` cookie (`xoxd`) on every run
  (they rotate), then queries `search.messages`. Requires the Slack desktop app
  installed and signed in. Token decryption uses the venv at
  `~/.local/share/daily-summary/venv` (has `cryptography`); recreate with
  `python3 -m venv <path> && <path>/bin/pip install cryptography` if missing.
  First run may trigger a one-time macOS keychain approval for "Slack Safe Storage".

## Adding new adapters

Each adapter is an executable in `adapters/` that:
- Accepts `--since <ISO8601>` and optional `--until <ISO8601>` (default: now).
- Writes JSON to stdout, logs to stderr.
- Exits non-zero on failure.
- Emits top-level shape: `{"source": "<name>", "since": "...", "until": "...", ...payload}`.

To wire a new adapter in, add a parallel-launch line in Step 2 — the read/dig-in/synthesis steps already handle arbitrary sources.

## Rules

- Capture `NOW` once at run start and reuse it. Never re-query the clock for `--until` or the checkpoint write.
- Advance the checkpoint ONLY after the summary file is written. A bail mid-run must leave the next run covering the same window.
- Append to the daily file if it exists. Never overwrite.
- Don't truncate adapter JSON before reading — you need the full payload for follow-up queries.
- Don't fabricate activity. Empty window → say so in one line.
- Don't use mock data. If `gh` isn't authenticated, stop and tell the user.
- All times in UTC. ISO8601 with `Z` suffix.
