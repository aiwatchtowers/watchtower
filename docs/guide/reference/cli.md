# Command line

The `watchtower` binary does everything the app does and a bit more. Add `--help` to any command for its subcommands and flags. The Desktop app shows the same data; use the CLI for scripts, headless boxes and quick checks. Commands that mutate data from an agent session usually need your approval, as they do in the app.

## Sync and status

| Command | What it does |
|---|---|
| `watchtower sync` | One sync pass. `--daemon --detach` runs the background daemon; `--now` asks a running daemon to sync at once; `--stop` stops it (`sync stop --force` escalates); `--full`, `--days N`, `--no-pipelines`, `--skip-dms` shape a run |
| `watchtower status` | Sync status and statistics |
| `watchtower logs` | Sync log output |
| `watchtower version` | Version |
| `watchtower workspace init` | Create the local workspace (data directory and database) |
| `watchtower db migrate` | Apply database migrations |
| `watchtower backfill status` | Progress of the [history backfill](../concepts/history-backfill.md) per source |
| `watchtower features list\|enable\|disable <id>` | [Feature switches](../concepts/features-on-and-off.md) |
| `watchtower config` | Read and change configuration |

## Accounts and sources

| Command | What it does |
|---|---|
| `watchtower slack`, `auth` | Slack workspaces (`slack add` connects another; `auth login` connects the first) |
| `watchtower google`, `gmail` | Google accounts and Gmail |
| `watchtower imap`, `outlook` | Other mailboxes |
| `watchtower calendar`, `caldav` | Calendar events and CalDAV/ICS feeds |
| `watchtower jira`, `linear`, `confluence` | Trackers and Confluence spaces |
| `watchtower connections` | [Quick Connections](../features/quick-connections.md) |

Account groups differ: Slack, Google, Jira and Linear list with `accounts`, the others with `list`; `rename <id> <name>` exists on Slack, Jira, Google, IMAP, Outlook and CalDAV; `remove` exists on most (Outlook uses `logout`); `enable` / `disable` exist on Slack, Jira and Linear but not on Google, IMAP or CalDAV. Run `--help` on the group. See [Sources and accounts](../concepts/sources-and-accounts.md).

## Reading what Watchtower made

| Command | What it does |
|---|---|
| `watchtower catchup` | Run, list, show and acknowledge [Catch Up](../features/catch-up.md) recaps |
| `watchtower briefing` | Today's [briefing](../features/briefings.md) |
| `watchtower day-plan` | The [day plan](../features/day-plan.md) |
| `watchtower inbox`, `remind <text>` | [Inbox](../features/inbox.md) and reminders |
| `watchtower digest`, `decisions`, `ideas` | [Digests](../features/digests.md), decisions, [ideas](../features/ideas-and-decisions.md) |
| `watchtower targets`, `tracks` | [Targets](../features/targets.md) and [tracks](../features/tracks.md) |
| `watchtower people`, `trends`, `users`, `channels` | [People](../features/people.md), trends (no weekly digest is generated today), synced users and channels |
| `watchtower meeting-prep [event-id\|next]` | Meeting preparation |
| `watchtower ask "<question>"` | Ask the assistant a question from the terminal |
| `watchtower kb search <query>`, `kb status`, `kb reindex` | The [knowledge index](../features/search-and-knowledge.md) |
| `watchtower memory` | The [assistant memory](../features/memory.md) vault |
| `watchtower feedback <good\|bad> <type> <id>` | Rate generated content |

## Automations and actions

| Command | What it does |
|---|---|
| `watchtower automations` | [Automations](../features/automations.md): list, validate, run, enable, templates |
| `watchtower actions` | Proposed assistant actions: list, approve, reject, tool trust |
| `watchtower reaction-commands` | Slack emoji reactions that drive the assistant |

### Why the app asks you to confirm a command

Some commands are yours alone: `actions approve` and `apply`, `actions trust … execute`, `automations confirm`, `enable`, `delete` and `auto … on`, and the ask guard and finish check of `workbench methodology`. Run one from a terminal and Watchtower shows a **Confirm in Watchtower** window with the exact command; the command waits up to 100 seconds for your **Confirm** and stops on **Deny**. The same click is what stops a coding agent from approving its own proposal.

- The buttons in the app never ask: the app confirms its own commands.
- With the app closed, the terminal prints a six-digit code; type it back to go ahead.
- A coding agent's shell with the app closed is refused outright.
- One window at a time: a second command is refused with **another confirmation is already open**.

## Workbench and coding agents

| Command | What it does |
|---|---|
| `watchtower workbench` | [Workbenches](../features/workbench/README.md): board, comments, sessions, asks, review, cleanup |
| `watchtower integrate claude-code\|codex\|status\|remove` | Wire Watchtower into [Claude Code or Codex](../features/claude-code-integration.md) |
| `watchtower mcp` | Run the MCP server over stdio |
| `watchtower tools` | Call the read-only data tools from the console |
| `watchtower agents enable\|disable\|scan\|stats` | [Agent analytics](../features/agent-analytics.md) |
| `watchtower code index\|search` | Symbol index and text search for a workbench folder |

## AI and usage

| Command | What it does |
|---|---|
| `watchtower ai models` | Models per provider and tier |
| `watchtower usage plan` | Claude plan limits (5-hour, weekly) |
| `watchtower prompts`, `tune` | Prompt templates and feedback-based tuning |
| `--provider claude\|codex\|ollama` | Per-command provider override |

`terminal`, `dictate` and `chat` are helpers the Desktop app calls; `ai` is too, apart from `ai models`.
