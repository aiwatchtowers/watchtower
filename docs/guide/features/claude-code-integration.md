# Claude Code integration

Watchtower can serve its data to your coding agent. A read-only MCP server and three small skills let Claude Code, Cursor or Codex look up a ticket's background, find who to ask, or find why something was decided, using what Watchtower already knows from Slack, Jira and meetings.

## Why use it

You pick up a ticket in your own terminal. Instead of reading threads yourself, the agent calls Watchtower, and tells you that the requirement was narrowed in a channel last week and who made the call. Your agent asks Watchtower; it does not search your sources itself, so what it sees is what you already synced.

This page is about your own agent outside Workbench. A Workbench session gets a writable, board-bound server of its own; see the Workbench pages.

## How it works

`watchtower mcp` is a Model Context Protocol server over stdio. It reads the same database as the app (the active workspace, or the one named by `--workspace`) and can only read: only read tools are registered, and the database connection runs in `query_only` mode. It makes no AI call; it returns rows, with references you can check.

The tools cover these areas:

- **Work items and briefings:** targets, today's briefing, tracks and track counts, ideas.
- **People and calendar:** people cards, `find_experts`, upcoming events.
- **Slack and meetings:** digests, messages, transcripts.
- **Jira:** issues, projects, status history, time in status, and `get_task_context`, which bundles one ticket with its comments, linked threads, meeting mentions, decisions and people.
- **Knowledge and memory:** `search_knowledge`, `get_knowledge_document`, the memory tools and `load_skill`.

The three skills tell the agent when to use which tool:

| Skill | Fires when you |
|-------|----------------|
| `watchtower-task-context` | start on a ticket or name a Jira key |
| `watchtower-who-to-ask` | are blocked or don't know who owns something |
| `watchtower-why-decision` | ask why code is the way it is |

Skills are plain files in your skills folder, marked as Watchtower's. Running the install again upgrades them. If you edited one, your copy is left alone and `integrate status` reports it as drifted.

## Using it

### Install for Claude Code

Run in a terminal:

```bash
watchtower integrate claude-code
```

This copies the skills into `~/.claude/skills` and runs `claude mcp add watchtower -- <path to watchtower> mcp`. If the `claude` CLI is not found, it prints that command for you to run. If `claude mcp add` fails, it prints the error, names "already registered" as the most common cause, points to `claude mcp list`, and exits normally.

Options:

- `--scope project` installs the skills into `./.claude/skills` instead. A narrowed scope or `--path DIR` does not touch the global MCP registration. `--mcp-only` reaches it, but then skips the skills.
- `--skills-only` or `--mcp-only` does just one half.

`watchtower integrate status` shows each skill as installed, drifted or missing, plus the binary path. `watchtower integrate remove` deletes only skills carrying Watchtower's marker and unregisters the server.

### Install for another client

For Cursor or any client that reads a `.mcp.json`, add the server by hand (the **MCP Server** screen shows both this block and the `claude mcp add` command, each with **Copy config**; it runs nothing):

```json
{
  "mcpServers": {
    "watchtower": { "command": "watchtower", "args": ["mcp"] }
  }
}
```

If `watchtower` is not on your `PATH`, use its absolute path as `command`. For Codex, put the same command in `~/.codex/config.toml`:

```toml
[mcp_servers.watchtower]
command = "watchtower"
args = ["mcp"]
```

### Workbench folders

You do not run these for a Workbench folder; Watchtower sets the folder up itself. For Codex, `watchtower integrate codex --workbench N` installs the workbench skill into the folder's `.agents/skills` and trusts the workbench hooks. `--remove` takes it back out. The command refuses to run without `--workbench`.

## When it's empty or wrong

- **A tool returns nothing.** The server only returns what Watchtower has synced. Check that the source is connected and has synced; a Jira key unknown to Watchtower gives an empty dossier.
- **The agent never uses a skill.** Run `watchtower integrate status`. A missing skill means the install did not run in that scope; a drifted one is yours and is not updated.
- **`claude CLI not found`.** The skills are still installed. Run the printed `claude mcp add` command yourself.
- **The agent talks to the wrong workspace.** Add `--workspace <name>` to the server's args.
- **You want to write through it.** You cannot. The server never writes; writes happen in the app's chat and in Workbench.

## Related

- [Menu bar and updates](menu-bar-and-updates.md): the app keeps the data fresh.

For developers: [docs/features/developer-surface.md](../../features/developer-surface.md), [docs/mcp-server.md](../../mcp-server.md)
