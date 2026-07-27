# skills

Personal agent skills for keeping a work log and linking pull requests to Linear
tickets. They run in both [Claude Code](https://claude.com/claude-code) and
[Codex](https://developers.openai.com/codex) — one checkout, symlinked into each host's
skills directory. The `SKILL.md` files and the adapters they shell out to are the same
in both.

| Skill | What it does |
| --- | --- |
| [`pr-linear`](pr-linear/) | Finds or files a Linear ticket *before* `gh pr create`, so `Closes <ID>` is in the PR body from the moment it exists. |
| [`daily-summary`](daily-summary/) | Writes a daily activity summary from GitHub + Linear + Slack, resuming from a checkpoint. |
| [`weekly-summary`](weekly-summary/) | Synthesizes a Mon–Sun summary and appends it to a Notion work-log page as a nested week toggle. |
| [`fill-weekly-summaries`](fill-weekly-summaries/) | Batch companion to `weekly-summary` — auto-detects gaps in the Notion page and backfills them. |

## Install

```bash
npx github:vanessaxteo/skills                       # all four
npx github:vanessaxteo/skills pr-linear             # or name the ones you want
npx github:vanessaxteo/skills --list                # what's available, and what each needs
```

Copies to `~/.agents/skills/`, symlinks into `~/.claude/skills/` (Claude Code) and
`$CODEX_HOME/skills/` (Codex, default `~/.codex/`), whichever exist. Re-run to update;
anything that isn't one of these symlinks is left alone. `weekly-summary` needs
`daily-summary`'s adapters and `fill-weekly-summaries` needs both — pulled in automatically.

Manual install does the same thing:

```bash
git clone https://github.com/vanessaxteo/skills.git ~/.agents/skills
chmod +x ~/.agents/skills/*/adapters/* ~/.agents/skills/*/scripts/*

for s in pr-linear daily-summary weekly-summary fill-weekly-summaries; do
  ln -s ~/.agents/skills/$s ~/.claude/skills/$s   # Claude Code
  ln -s ~/.agents/skills/$s ~/.codex/skills/$s    # Codex ($CODEX_HOME/skills)
done
```

The skills reference each other by absolute path, so installing elsewhere means updating those
paths in the `SKILL.md` adapter blocks. `user-invocable: true` is what makes
`/weekly-summary` a slash command; Codex's `quick_validate.py` flags it as unknown, but the
runtime documents it — ignore that.

`pr-linear` only pays off *before* `gh pr create`, so make it a standing rule in
`~/.claude/CLAUDE.md` and/or `~/.codex/AGENTS.md`:

> BEFORE every `gh pr create` (draft or ready, any repo), run the `pr-linear` skill first.
> Never create the PR and then run the skill.

## Requirements

- `gh` (authenticated), `jq`, `curl`
- **Linear** — MCP over OAuth, since many orgs disable personal API keys. One-time
  `npx -y mcp-remote https://mcp.linear.app/mcp` (finish the browser login, then Ctrl+C);
  tokens cache in `~/.mcp-auth`.
- **Slack** — the signed-in desktop app on macOS; no bot, no admin approval. Needs a venv
  with `cryptography`:
  ```bash
  python3 -m venv ~/.local/share/daily-summary/venv
  ~/.local/share/daily-summary/venv/bin/pip install cryptography
  ```
- **Notion** — weekly skills only. Register it as `notion` so tool ids match the
  `mcp__notion__…` calls; in Codex, add to `~/.codex/config.toml` and `codex mcp login notion`:
  ```toml
  [mcp_servers.notion]
  url = "https://mcp.notion.com/mcp"
  ```
- **Codex sandbox** — `workspace-write` blocks the network the adapters need. Approve the
  escalation when prompted, or:
  ```toml
  [sandbox_workspace_write]
  network_access = true
  ```

## Config

Written on first run to `~/.config/skills/` (`~/.claude/` is also read, so an existing Claude
Code setup keeps working).

`pr-linear.json` — Linear team routing:

```json
{
  "default_team": "ABC",
  "repo_teams": { "owner/some-repo": "XYZ" },
  "teams": { "ABC": "<team-uuid>", "XYZ": "<team-uuid>" },
  "state": "In Review",
  "priority": 3
}
```

`weekly-summary.json` — the Notion page holding the year toggles, shared with
`fill-weekly-summaries`:

```json
{
  "notion_page_id": "<page-uuid>",
  "page_title": "my work"
}
```

`daily-summary`'s checkpoint at `~/.local/state/daily-summary/checkpoint.json` is shared too,
so a run from either host advances the same window.

## Credentials

Nothing here stores a secret: the Linear OAuth cache in `~/.mcp-auth`, a fresh Slack session
token read from the desktop app each run, and whatever `gh` is already authenticated as.
