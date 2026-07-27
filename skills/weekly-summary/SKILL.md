---
name: weekly-summary
description: Generate a weekly work summary (Mon–Sun) from GitHub + Linear + Slack and write it into your work-log Notion page as a week toggle nested in the year toggle. Use when the user says "weekly summary", "weekly update", "team sync update", "what did I do this week", or invokes `/weekly-summary`.
user-invocable: true
---

# Weekly Summary

Generate a Mon–Sun weekly summary and append it to your work-log Notion page as a
`M/D-M/D` toggle nested inside the current year's toggle — matching the existing entries'
format. You drive the synthesis; the adapters give you a map, not the final answer.

Auth goes through adapters that need no admin approval (Linear MCP-OAuth, Slack desktop
session), since many orgs disable Linear personal API keys.

## Config — `~/.config/skills/weekly-summary.json` (or `~/.claude/weekly-summary.json`)

```json
{
  "notion_page_id": "<page-uuid>",
  "page_title": "my work"
}
```

`notion_page_id` is the page holding the year toggles; `page_title` is only used when
reporting back to the user. Read whichever of the two paths exists, preferring the first,
before step 1 — `PAGE_ID` below refers to it. **First run** (config missing): ask the user
for the page URL or ID, derive the UUID, write
`~/.config/skills/weekly-summary.json`, then continue.

## Steps

1. **Determine the week window.**
   - Default: the **current** Mon–Sun week. To backfill instead, set `ARG` below to any `YYYY-MM-DD` inside the week you want.
   ```bash
   ARG=""   # set to any YYYY-MM-DD inside a past week to backfill that week
   if [[ -n "$ARG" ]]; then
     DOW=$(date -j -f %Y-%m-%d "$ARG" +%u)
     MON=$(date -j -v-$((DOW-1))d -f %Y-%m-%d "$ARG" +%Y-%m-%d)   # macOS: -v BEFORE -f
   else
     DOW=$(date +%u)                              # 1=Mon .. 7=Sun
     MON=$(date -v-$((DOW-1))d +%Y-%m-%d)
   fi
   SUN=$(date -j -v+6d -f %Y-%m-%d "$MON" +%Y-%m-%d)               # macOS: -v BEFORE -f
   SINCE="${MON}T00:00:00Z"
   UNTIL="${SUN}T23:59:59Z"
   MM=$(date -j -f %Y-%m-%d "$MON" +%m); MD=$(date -j -f %Y-%m-%d "$MON" +%d)
   SM=$(date -j -f %Y-%m-%d "$SUN" +%m); SD=$(date -j -f %Y-%m-%d "$SUN" +%d)
   PERIOD="$((10#$MM))/$((10#$MD))-$((10#$SM))/$((10#$SD))"        # e.g. 6/15-6/21
   YEAR=$(date -j -f %Y-%m-%d "$MON" +%Y)        # e.g. 2026
   echo "Week: $PERIOD ($YEAR)  window $SINCE → $UNTIL"
   ```
   - Tell the user the week + window in one line before running adapters.

2. **Fan out adapters in parallel.** Reuse daily-summary's Slack + Linear adapters; only GitHub is weekly-specific.
   ```bash
   TMP=$(mktemp -d)
   WK=~/.agents/skills/weekly-summary/adapters
   DS=~/.agents/skills/daily-summary/adapters
   "$WK/github-prs.sh" --since "$SINCE" --until "$UNTIL" > "$TMP/github.json" 2> "$TMP/github.err" &
   "$DS/linear.sh"     --since "$SINCE" --until "$UNTIL" > "$TMP/linear.json" 2> "$TMP/linear.err" &
   "$DS/slack.sh"      --since "$SINCE" --until "$UNTIL" > "$TMP/slack.json"  2> "$TMP/slack.err"  &
   wait
   ```
   If an adapter exits non-zero, note it to the user and continue with what succeeded. **Do NOT write a Notion entry if every adapter failed** (an empty week from a rate-limit ≠ a quiet week). `github-prs.sh` fails loudly on GitHub rate limits — if it errors, wait a few minutes and retry rather than recording an empty PR list.

3. **Read each adapter's JSON** as working memory:
   - `github.json` → `.merged[]` and `.open[]` (each `{repo,title,url,additions,deletions,mergedAt,open}`).
   - `linear.json` → `.issues_updated[]`; keep those whose `status`/`statusType` is Done/completed **and** `completedAt` falls in the window — those are the week's completed tickets.
   - `slack.json` → `.messages_sent` / `.mentions` for color (notable threads, decisions).

4. **Dig in.** Use `gh pr view`/`gh pr diff`/`gh api` on anything that needs understanding (big diffs, draft→ready, threads). The summary should reflect understanding, not transcription.

5. **Synthesize** in the exact format the page already uses (so it sits cleanly above the prior week):
   - 3–6 **italic** impact bullets, first person, each line `*- <what shipped / impact>*`. Fold notable Slack discussions/decisions into these bullets (don't dump raw messages — a week of Slack is noise).
   - Then `**Linear Tickets**` and one bullet per completed ticket: `- [ABC-123](url) Title`.
   - Then `**PRs**` (merged first, then open), one bullet each: `- \[owner/repo\] [title](url) +A/−D` with ` (open)` appended for unmerged. Use the unicode minus `−` to match existing entries. Escape the repo brackets as `\[…\]`.
   - Empty week → a single italic line saying so; still create the toggle.

6. **Write to Notion** (see next section), with a skip-if-exists guard.

7. Print the page URL: `https://www.notion.so/<PAGE_ID with dashes stripped>`.

## Writing the week toggle (Notion MCP)

Tool ids below assume the Notion MCP server is registered as `notion`; if yours has a
different name, the `mcp__<server>__…` prefix changes but the calls are the same.

**Page format (keep it this way):** under the year toggle, each **month header** toggle (`June`,
`May`, …) is followed by that month's **week** toggles, newest-first — all siblings at one tab:
```
2026
	June                 ← month header (top ships; from monthly-summary)
	6/15-6/21            ← June's weeks, newest first
	6/8-6/14
	6/1-6/7
	May
	5/25-5/31
	…
```
A new week is the **newest week of its month**, so it goes **directly under its month header**,
above that month's existing weeks. Tabs are significant (week `<details>`/`<summary>`/`</details>`
at one tab, its children at two).

1. `mcp__notion__notion-fetch` id `<PAGE_ID>` (from config).
2. **Skip-if-exists:** if `<summary>PERIOD</summary>` already appears under the year, stop and offer to replace.
3. **Locate the week's month header** (`<summary>MONTH</summary>`, e.g. `June`, where MONTH is `date -j -f %Y-%m-%d "$MON" +%B`).
   - If the month header is **missing** (first week of a new month), create it first — either by running a `monthly-summary` skill if you have one (it inserts the month header at the top of the year), or by inserting a bare `<summary>MONTH</summary>` toggle there yourself. Then continue. Don't place the week with no month header — that breaks the grouping.
4. **Insert the week directly under its month header** (becoming the month's newest week) via `mcp__notion__notion-update-page` `command:"update_content"`. The robust anchor is the **first existing week of that month** — insert the new week immediately *before* it:
   - `old_str`: `\t<details>\n\t<summary>6/15-6/21</summary>` (the current newest week of the month)
   - `new_str`: the new week block (`\t<details>…\t</details>`) + `\n` + that same `old_str`
   - If the month has **no weeks yet**, anchor instead on the month header's close (its last ship bullet line + the following `\n\t</details>`) and insert the week right after it.
   The week block (one tab; children two tabs):
   ```
   	<details>
   	<summary>6/22-6/28</summary>
   		*- Shipped X, cutting Y…*
   		*- Drove the Z discussion in #channel, aligning on…*
   		**Linear Tickets**
   		- [ABC-123](https://linear.app/<org>/issue/ABC-123/…) ticket title
   		**PRs**
   		- \[owner/repo\] [a merged PR title](https://github.com/owner/repo/pull/478) +303/−36
   		- \[owner/other-repo\] [an open PR title](https://github.com/owner/other-repo/pull/1213) +329/−19 (open)
   	</details>
   ```
5. If `update_content` can't place the nested block reliably, **don't write to the wrong spot** — print the rendered block and ask the user to paste it.

## Adapters

- **github-prs.sh** (weekly-specific) — PRs you authored that **merged** in the window (`is:merged merged:START..END`) plus **all your open** PRs, each enriched with `+additions/−deletions` via `gh pr view`. Fails loudly on GitHub search rate limits.
- **daily-summary/linear.sh** (reused) — Linear issues assigned to you, updated in the window, via Linear MCP-OAuth. Filter to completed-in-window for the weekly view.
- **daily-summary/slack.sh** (reused) — Slack messages you sent + mentions, from the desktop-app session.

## Rules

- Mon–Sun calendar week. Idempotent: the skip-if-exists guard means re-running a week never duplicates its toggle.
- Match the existing page format exactly (italic `*- …*` summary, **Linear Tickets**, **PRs** with `\[repo\]` + `+A/−D` + `(open)`). The week nests under its **month header**, as the month's newest week.
- Don't fabricate. A genuinely empty week → say so in one italic line. An adapter failure ≠ an empty week — never record an entry built from a failed fetch.
- Don't truncate adapter JSON before reading — you need the full payload for follow-up queries.
- All adapter times in UTC, ISO8601 with `Z`.
