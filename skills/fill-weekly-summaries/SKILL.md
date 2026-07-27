---
name: fill-weekly-summaries
description: Backfill missing weekly summaries into your work-log Notion page. Auto-detects gaps in the year toggle (or takes an explicit date range) and fills each missing Mon–Sun week. Use when the user says "fill in missing weeks", "backfill weekly summaries", "catch up the weekly log", or invokes `/fill-weekly-summaries`.
user-invocable: true
---

# Fill Missing Weekly Summaries

Backfill the gaps in your work-log Notion page. Same per-week flow as [[weekly-summary]],
run in a loop over every missing Mon–Sun week, keeping the page in ascending order.

The sibling per-week skill is `weekly-summary`; this skill is its batch/backfill companion.
It shares `weekly-summary`'s config at `~/.config/skills/weekly-summary.json` (or
`~/.claude/weekly-summary.json`) — read it first; `PAGE_ID` below refers to
`notion_page_id`.

## Steps

1. **Determine the weeks to fill.**
   - Default (no arg): **auto-detect the gap.** `notion-fetch` `<PAGE_ID>`, list the existing
     `<summary>M/D-M/D</summary>` labels under the current year toggle, and enumerate every
     Mon–Sun week from the **week after the latest existing entry** up to the **last completed
     week** (the Sunday before this week's Monday). The set to fill = enumerated weeks whose
     label is not already present.
   - Explicit range (`/fill-weekly-summaries 2026-05-01 2026-05-31`): enumerate Mon–Sun weeks
     intersecting that range; fill those not already present.
   - Compute each week's `MON`/`SUN` dates, ISO window, `M/D-M/D` label, and year (see
     `weekly-summary/SKILL.md` step 1 for the exact `date` snippet).
   - List the weeks you're about to fill, in one line, before starting.

2. **Fill each week, oldest → newest.** For each missing week, run the per-week flow:
   ```bash
   WK=~/.agents/skills/weekly-summary/adapters
   DS=~/.agents/skills/daily-summary/adapters
   TMP=$(mktemp -d)
   # Past weeks: omit currently-open PRs (--no-open). Merged + Linear + Slack only.
   "$WK/github-prs.sh" --since "$SINCE" --until "$UNTIL" --no-open > "$TMP/github.json" 2> "$TMP/github.err"
   "$DS/linear.sh"     --since "$SINCE" --until "$UNTIL"           > "$TMP/linear.json" 2> "$TMP/linear.err"
   "$DS/slack.sh"      --since "$SINCE" --until "$UNTIL"           > "$TMP/slack.json"  2> "$TMP/slack.err"
   ```
   - Read the JSON; keep Linear issues completed-in-window (`statusType`/`status` Done **and** `completedAt` in window).
   - **Synthesize** in the page format (italic `*- …*` summary → `**Linear Tickets**` → `**PRs**`, merged only, `\[repo\]` + `+A/−B`, escape `[ ]` in titles). A genuinely empty week → one italic line saying so; still create the toggle so the gap closes.
   - **Write** the week toggle into Notion in ascending position (next section).

3. **Pace & resume.** `github-prs.sh` fails loudly on GitHub rate limits. If a week's GitHub fetch errors, **stop**, tell the user which weeks were written and which remain, and suggest re-running — skip-if-exists makes the next run resume from the first unfilled week. Don't write a toggle built from a failed fetch.

4. Print the page URL when done, with a count of weeks filled.

## Writing each week toggle (grouped under its month, Notion MCP)

**Page format (keep it):** under the year toggle, each **month header** toggle (`June`, `May`, …)
is followed by that month's **week** toggles, newest-first — all siblings at one tab. Each
backfilled week must land **under its own month header**, in descending position among that
month's weeks. Tabs are significant (week `<details>` at 1 tab, children at 2).

- **Skip-if-exists:** before writing, confirm `<summary>M/D-M/D</summary>` isn't already present.
- **Ensure the month header exists.** For each week, its month is `date -j -v+3d -f %Y-%m-%d "$MON" +%B` (use any day inside the week; Thursday is always in the same month). If `<summary>MONTH</summary>` is absent under the year, create it first — via a `monthly-summary` skill if you have one, otherwise a bare month toggle — so the week has a parent group.
- **Place the week in descending position within its month.** Anchor `update_content` on the **week immediately newer than this one that already exists** (could be a later week of the same month, or — for the month's newest week — the month header's close), and insert this week right *after* it:
  - `old_str`: the anchor's last line **plus** its trailing `\n\t</details>`.
  - `new_str`: the same text, then `\n` + the new week block (`\t<details>` / `\t<summary>…</summary>` / 2-tab children / `\t</details>`).
  - If this is the **oldest** week of its month and an older month follows, you can equivalently anchor on the *next (older) month header* and insert before it.
- Filling a contiguous gap: insert weeks **newest-first within each month**, re-fetching (or reusing the latest fetch) so each anchor line is current. Process month-by-month.
- If an anchor can't be matched reliably, **don't write to the wrong place** — report the rendered blocks and ask the user to paste.

## Rules

- Mon–Sun weeks, grouped under their month header, newest-first within the month. Idempotent via skip-if-exists (safe to re-run; resumes).
- Past weeks omit open PRs (`--no-open`) — "currently open" is misleading for an old week.
- Don't fabricate. Empty week → one italic line; adapter failure ≠ empty week (never record a failed fetch).
- Match the page format exactly so backfilled weeks sit cleanly under their month.
- All adapter times UTC, ISO8601 `Z`.
