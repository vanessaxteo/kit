---
name: pr-linear
description: Link GitHub pull requests to Linear tickets. Run before `gh pr create`; use quick mode when the user asks for a "quick PR" to skip Linear lookups and ticket creation, linking only an explicitly identified ticket. Also handles existing PRs post-hoc when the user asks for a Linear ticket.
user-invocable: true
---

# PR → Linear Ticket

By default, every PR gets a Linear ticket tracking it, cross-linked both ways. Ticket
first, PR second: find or create the ticket before `gh pr create` so `Closes <ID>`
ships in the initial PR body — no follow-up `gh pr edit`, no window where the PR exists
unticketed. An existing ticket covering the work is always reused, never duplicated.
Quick mode is the explicit exception: it creates no ticket and makes no Linear calls.

## Linear access

Prefer in-session Linear MCP tools if already authenticated. Otherwise use the bundled
caller, which reuses the mcp-remote OAuth cache (`~/.mcp-auth`) and refreshes tokens
itself (many orgs disable Linear PATs, leaving MCP as the only path):

```bash
S=~/.agents/skills/pr-linear/scripts
"$S/linear-mcp.sh" list-tools              # tool names + arg schemas (issue/team related)
"$S/linear-mcp.sh" call <tool> '<json-args>'
```

If it reports no token: one-time `npx -y mcp-remote https://mcp.linear.app/mcp`
(complete the browser login, then Ctrl+C). Never fall back to browser automation.

## Quick mode

Use quick mode only when the user explicitly asks for a "quick PR", "quick pr", or
"quick pull request". It is an opt-in shortcut for small changes, not the default.

1. Look only in the branch name, proposed PR title, and conversation for a Linear
   identifier (`[A-Z][A-Z0-9]+-[0-9]+`) or a `linear.app` issue link. Do not call
   Linear, read config, search tickets, create tickets, or attach links.
2. If an identifier is present, create the PR with `Closes <ID>` as the last line of
   its initial body. If no identifier is present, create the PR without a `Closes`
   line. Do not create a ticket.
3. Report the PR URL and whether it was linked to an existing ticket or intentionally
   created without one.

Quick mode applies only while creating a new PR. `/pr-linear [pr-url]` always uses the
existing-PR flow below.

## Config — `~/.config/skills/pr-linear.json` (or `~/.claude/pr-linear.json`)

```json
{
  "default_team": "ABC",
  "repo_teams": { "owner/some-repo": "XYZ" },
  "teams": { "ABC": "<team-uuid>", "XYZ": "<team-uuid>" },
  "state": "In Review",
  "priority": 3
}
```

`default_team` is the Linear team key for new tickets; `repo_teams` optionally overrides
it per `owner/repo`; `teams` caches key→ID because `save_issue.team` takes a name or ID,
not a key; `priority` is 1=Urgent 2=High 3=Medium 4=Low.

Read whichever of the two paths exists, preferring the first.

**First run** (config missing): call `list_issues` with `{"assignee":"me","orderBy":"updatedAt","limit":50}`,
tally the team keys, and ask the user once which should be the default (most common keys
as options; via AskUserQuestion in Claude Code, a plain question elsewhere). Call
`list_teams` to resolve the chosen keys to IDs for the `teams` cache. Write the config
to `~/.config/skills/pr-linear.json` with the defaults above, then continue.

## Steps — creating a new PR (default)

Run this flow INSTEAD of a bare `gh pr create`, in this order:

1. **Use an existing ticket when there is one — never create a duplicate.**
   - If the branch name, the PR title you're about to use, or the conversation shows
     the work came from an existing ticket (a Linear identifier `[A-Z][A-Z0-9]+-[0-9]+`
     or a `linear.app` issue link), use that ID.
   - Otherwise search Linear before creating: `list_issues` with
     `{"assignee":"me","orderBy":"updatedAt","limit":50}` and, if the PR title has
     distinctive keywords, a second `list_issues` with a `query`. Reuse a ticket only
     when it clearly describes this same change; when in doubt, it's not a match.
   - On a match: put `Closes <ID>` as the last line of the PR body, create the PR,
     attach the PR link to that ticket (step 5), and report "using existing: <ID>" —
     skip steps 2-3.
2. **Load config** (first-run setup above). Team key = `repo_teams[owner/repo]` (from
   `gh repo view --json nameWithOwner -q .nameWithOwner`), else `default_team`; team ID
   from the `teams` cache (if the key isn't cached, `list_teams` and add it).
3. **Create the ticket** with `save_issue`, title = the PR title you're about to use:
   ```json
   {
     "title": "<PR title>",
     "team": "<team ID from config>",
     "assignee": "me",
     "state": "In Review",
     "priority": 3,
     "description": "<1-2 sentence summary of the change>"
   }
   ```
   (state/priority from config.) Capture the identifier (e.g. `ABC-123`), ticket URL,
   and ticket `id` from the response. If `save_issue` ever disappears, re-run
   `list-tools` to find the renamed issue-creation tool rather than guessing.
4. **Create the PR** with `Closes ABC-123` as the last line of the body passed to
   `gh pr create`. `Closes` is a Linear magic word: the GitHub integration attaches the
   PR and moves the ticket to Done on merge. Use the bare identifier instead if
   auto-close is ever unwanted for a given PR.
5. **Attach the PR link to the ticket** — `save_issue` again with the ticket `id` and
   `links: [{ "url": "<pr-url>", "title": "PR #<num>: <PR title>" }]`. Non-fatal if this
   fails: the magic word already attaches the PR via the GitHub integration.
6. **Report** one line per PR: `ABC-123 <ticket-url> ← <pr-url>`.

## Steps — existing PR (`/pr-linear [pr-url]`, or a PR that slipped through)

1. **PR context.** `gh pr view <ref> --json url,number,title,body,headRefName` and
   `gh repo view --json nameWithOwner -q .nameWithOwner`.
2. **Existing-ticket check** as above, against branch name, PR title, PR body, and a
   Linear search. On a match, ensure the body references it (append `Closes <ID>` if
   absent), attach the PR link to that ticket, and report "using existing: <ID>".
3. **Load config and create the ticket** as in the new-PR flow, but include the
   `links` attachment with the PR URL directly in the `save_issue` call.
4. **Cross-link the PR** — append to the body, preserving existing content:
   ```bash
   BODY="$(gh pr view "$NUM" --json body -q .body)"
   gh pr edit "$NUM" --body "${BODY}

   Closes ABC-123"
   ```
5. **Report** as above.

## Rules

- In the default flow, never create a duplicate ticket (the existing-ticket check is
  mandatory, not optional). In either mode, never guess-attach: a wrong `Closes` line
  would auto-close an unrelated ticket on merge.
- Ticket failure never blocks the PR. In the new-PR flow, if `save_issue` fails, create
  the PR anyway (without a `Closes` line), report the failure explicitly with the
  re-auth hint, and note it can be retried later with `/pr-linear <pr-url>`. Never
  claim success on a failed creation.
- The only user interaction allowed is the first-run team pick.
