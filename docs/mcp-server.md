# Watchtower MCP Server

`watchtower mcp` runs a read-only [Model Context Protocol](https://modelcontextprotocol.io)
server over stdio. It exposes your Watchtower data — targets, briefings,
digests, people, tracks, calendar, and Jira — as tools any MCP client can use
for work context.

It is **read-only**: no tool can modify your data.

## Tools

| Tool | What it returns |
|------|-----------------|
| `list_targets` | Your action items, filterable by status/priority/level/ownership |
| `get_target` | One target by id |
| `get_today_briefing` | Your latest daily briefing |
| `list_digests` | Channel/daily/weekly Slack digests |
| `get_digest` | One digest by id |
| `list_people` | People cards |
| `get_person` | One person card by Slack user id |
| `list_tracks` | Narrative tracks |
| `get_track` | One track by id |
| `list_upcoming_events` | Calendar events in the next N hours |
| `list_jira_issues` | Synced Jira issues, filterable by project/status/assignee |
| `get_jira_issue` | One Jira issue by key |

## Add to Claude Code

```bash
claude mcp add watchtower -- watchtower mcp
```

## Add to a `.mcp.json` (Cursor, Claude Code project config, etc.)

```json
{
  "mcpServers": {
    "watchtower": {
      "command": "watchtower",
      "args": ["mcp"]
    }
  }
}
```

If `watchtower` is not on your `PATH`, use its absolute path as `command`.

## Add to Codex (`~/.codex/config.toml`)

```toml
[mcp_servers.watchtower]
command = "watchtower"
args = ["mcp"]
```

The server reads the same SQLite database the CLI uses (the active workspace's
`watchtower.db`); pass `--workspace <name>` after `mcp` to target a specific
workspace.
