---
name: pr-linear
description: Link GitHub pull requests to Linear tickets. Run before `gh pr create`; use quick mode when the user asks for a "quick PR" to create the PR first, then create and link its Linear ticket. Also handles existing PRs post-hoc when the user asks for a Linear ticket.
user-invocable: true
---

# PR → Linear Ticket

By default, every PR gets a Linear ticket tracking it, cross-linked both ways. Ticket
first, PR second: find or create the ticket before `gh pr create` so `Closes <ID>`
ships in the initial PR body — no follow-up `gh pr edit`, no window where the PR exists
unticketed. An existing ticket covering the work is always reused, never duplicated.
Quick mode is the explicit exception: it creates the PR first, then creates and links
the ticket afterward.

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

1. Create the PR immediately, without a `Closes` line. Do not search Linear, load
   config, or create a ticket before the PR URL exists.
2. After creating the PR, look only in the branch name, PR title, and conversation for
   a Linear identifier (`[A-Z][A-Z0-9]+-[0-9]+`) or a `linear.app` issue link. If one
   is present, reuse that ticket. Otherwise load config and create a ticket with the
   PR title, a 1–2 sentence summary, `assignee: "me"`, configured state and priority,
   and the PR link in `links`.
3. Append `Closes <ID>` to the PR body using the ticket identifier from step 2, with a
   real blank line before it. Use `gh pr edit --body-file` for the updated body; never
   pass literal `\\n` escape sequences to `--body`. For a reused ticket, do not make a
   link-only `save_issue` update; the closing reference provides the cross-link.
4. If ticket creation or linking fails, leave the PR open and report the failure with
   the re-auth hint; never claim the ticket was created.

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
5. **Rely on the closing reference for the cross-link.** Do not update an existing
   ticket with `save_issue` and `links` after PR creation; the GitHub integration
   attaches the PR from `Closes <ID>`.
6. **Report** one line per PR: `ABC-123 <ticket-url> ← <pr-url>`.

## Steps — existing PR (`/pr-linear [pr-url]`, or a PR that slipped through)

1. **PR context.** `gh pr view <ref> --json url,number,title,body,headRefName` and
   `gh repo view --json nameWithOwner -q .nameWithOwner`.
2. **Existing-ticket check** as above, against branch name, PR title, PR body, and a
   Linear search. On a match, ensure the body references it (append `Closes <ID>` if
   absent) and report "using existing: <ID>".
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
  mandatory, not optional). In quick mode, reuse only a ticket explicitly identified
  in context; otherwise create a new ticket after the PR. In either mode, never
  guess-attach: a wrong `Closes` line would auto-close an unrelated ticket on merge.
- Ticket failure never blocks the PR. In the default flow, if `save_issue` fails,
  create the PR anyway (without a `Closes` line). In quick mode, leave the already
  created PR unlinked. Report the failure explicitly with the re-auth hint and note it
  can be retried later with `/pr-linear <pr-url>`. Never claim success on a failed
  creation.
- PR bodies must use real line breaks. Never send a literal `\\n` sequence to GitHub;
  use `--body-file` when an existing body needs a closing line appended.
- Do not use `save_issue` solely to add a PR link to an existing ticket. New tickets
  may receive `links` during creation; otherwise the `Closes` reference cross-links.
- The only user interaction allowed is the first-run team pick.
