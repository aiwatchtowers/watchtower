# Command line

The `watchtower` binary does everything the app does and a bit more. Add `--help` to any command for its subcommands and flags. The Desktop app shows the same data; use the CLI for scripts, headless boxes and quick checks. Commands that mutate data from an agent session usually need your approval, as they do in the app.

## Sync and status

| Command | What it does |
|---|---|
| `watchtower sync` | One sync pass. `--daemon --detach` runs the background daemon; `--now` asks a running daemon to sync at once; `--stop` stops it (`sync stop --force` escalates); `--full`, `--days N`, `--no-pipelines`, `--skip-dms` shape a run |
| `watchtower status` | Sync status and statistics |
| `watchtower logs` | Sync log output |
| `watchtower version` | Version |
| `watchtower guide learn` | The Learn cards Home shows, read from this guide and checked; `--json` for scripts |
| `watchtower workspace init` | Create the local workspace (data directory and database) |
| `watchtower db migrate` | Apply database migrations |
| `watchtower db compact` | Shrink the database file after an update freed space, first finishing a pending search index rebuild (the app does this at launch). `--check` only reports; `--if-due` compacts only when due; refuses while the daemon runs or disk is short (twice the file's size for compacting, 64 MiB for the rebuild) unless `--force` |
| `watchtower backfill status` | Progress of the [history backfill](../concepts/history-backfill.md) per source |
| `watchtower features list\|enable\|disable <id>` | [Feature switches](../concepts/features-on-and-off.md) |
| `watchtower config` | Read and change configuration |

## Accounts and sources

| Command | What it does |
|---|---|
| `watchtower slack`, `auth` | Slack workspaces (`slack add` connects another; `auth login` connects the first; `slack backfill --account N --from D --to D` fetches up to 31 past days of one account again, with digests for channel days that had none; on a day that already has a digest for a channel, the fetched messages are saved and searchable but not digested; `slack live probe [--provider claude\|codex] [--json]` checks that your Claude or ChatGPT Slack connector can read, for [Live Slack](../concepts/sources-and-accounts.md#live-slack-through-your-claude-or-chatgpt-account); `slack connect --code T…:1234.5678` connects through your workspace's app while the app is not running; `slack app create\|adopt\|link\|pending\|status` runs [the company setup](../features/slack-full.md#set-up-slack-for-your-company), the configuration token read from standard input) |
| `watchtower google`, `gmail` | Google accounts and Gmail |
| `watchtower imap`, `outlook` | Other mailboxes |
| `watchtower calendar`, `caldav` | Calendar events and CalDAV/ICS feeds |
| `watchtower jira`, `linear`, `confluence` | Trackers and Confluence spaces |
| `watchtower accounts purges` | Scheduled and finished deletions of a revoked or unreached account's data, newest first; `--json` for scripts. See [Revoked access](../concepts/revoked-access.md) |
| `watchtower policy show` | The organization policy forced on this Mac; `--json` for scripts. See [Organization policy](organization-policy.md) |
| `watchtower policy keys` | Every key an organization can force, with type, default and effect; `--json` for scripts |
| `watchtower connections` | [Quick Connections](../features/quick-connections.md); `connections import` brings in your codex and Claude Code MCP servers |
| `watchtower jira add --api-token-stdin --email <email> --site <site>` | Connects a Jira Cloud site with your own Atlassian API token instead of signing in through an app. Pipe the token in on stdin; it is never an argument. Add `--with-confluence` for Confluence. When the token expires or is revoked, the site shows an error and keeps its data: paste a new one with `jira login --account <id> --api-token-stdin` |
| `watchtower company list`, `inspect`, `confirm` | Your stored [company setups](../start/company-setup.md) (`list`; one set by your organization is marked). `inspect` shows what a link or code on standard input, or a stored company (`--slug`), would connect without storing it; `confirm` stores one (`--source link\|code\|mdm`, `--replace` to accept changed apps) |
| `watchtower company connect --slug <slug> [--vendors slack,google,…]` | Signs in to a stored company's services one after another, by default those without a working account. While the app runs it holds Slack's port, so connect from **Connections** instead |
| `watchtower company check`, `draft`, `publish`, `profile --slug <slug>` | What **Set up for my company** runs: a check of one company app, the wizard's draft (`show`, `save`, `discard`, `discover` lists the company apps this Mac knows), publishing the link to the Slack app, and a `.mobileconfig` for IT |
| `watchtower google add`, `jira add`, `linear add`, `outlook login` with `--company <slug>` | Signs in through that stored company's app and ties the account to the company |
| `watchtower google add --gmail --calendar --client-id <id> --client-secret-stdin` | Connects Gmail and Calendar through your own Google project; the secret comes on standard input |

Account groups differ: Slack, Google, Jira and Linear list with `accounts`, the others with `list`; `rename <id> <name>` exists on Slack, Jira, Google, IMAP, Outlook and CalDAV; `remove` exists on most (Outlook uses `logout`); `enable` / `disable` exist on Slack, Jira and Linear but not on Google, IMAP or CalDAV. Run `--help` on the group. See [Sources and accounts](../concepts/sources-and-accounts.md).

## Reading what Watchtower made

| Command | What it does |
|---|---|
| `watchtower catchup` | Run, list, show and acknowledge [Catch Up](../features/catch-up.md) recaps |
| `watchtower briefing` | Today's [briefing](../features/briefings.md); `briefing generate` makes today's now, if there is none yet, through the Morning brief's current recipe, even with the feature off |
| `watchtower day-plan` | The [day plan](../features/day-plan.md); `day-plan generate [--feedback <text>]` makes or redoes it the same way |
| `watchtower inbox`, `remind <text>` | [Inbox](../features/inbox.md) and reminders |
| `watchtower inbox folders` | The Inbox menu: `list`, and `create`, `update`, `move`, `delete`, `route <automation-id>`, each with `--expect-revision` from `list`; a stale one changes nothing ("the Inbox menu changed"). Refused in a coding agent's shell |
| `watchtower digest`, `decisions`, `ideas` | [Digests](../features/digests.md), decisions, [ideas](../features/ideas-and-decisions.md) |
| `watchtower targets`, `tracks` | [Targets](../features/targets.md) and [tracks](../features/tracks.md); `tracks start <id>` makes a track's watch, `tracks instruction <id> --text <t>` edits it |
| `watchtower people` (`people exclude --user <id>` and `people include --user <id>` stop and restore a person's card, as in the app), `trends`, `users`, `channels` | [People](../features/people.md), trends (no weekly digest is generated today), synced users and channels |
| `watchtower channels exclude <name>`, `channels include <name>` | **Stop syncing** and **Sync again** on a Slack channel from the terminal, as in [Statistics](../features/statistics.md); a name (`#` optional) or `--id <id>`, `--json` for scripts |
| `watchtower meeting-prep [event-id\|next]` | Meeting preparation |
| `watchtower ask "<question>"` | Ask the assistant a question from the terminal |
| `watchtower kb search <query>`, `kb status`, `kb reindex` | The [knowledge index](../features/search-and-knowledge.md) |
| `watchtower memory` | The [assistant memory](../features/memory.md) vault |
| `watchtower feedback <good\|bad> <type> <id>` | Rate generated content |

## Automations and actions

| Command | What it does |
|---|---|
| `watchtower automations` | [Automations](../features/automations.md): list, validate, run, enable, templates |
| `watchtower automations run morning-brief` | A [built-in automation](../features/automations-built-in.md) runs at the next sync, which starts at once; on a watch, `--since <date>` sets where the scan starts; `enable`, `disable`, `delete` and `auto` refuse a built-in and say what to use instead |
| `watchtower automations reset <id>` | Put a built-in back on its shipped version, deleting your edited copy (asks you to confirm) |
| `watchtower automations upgrade-builtins` | Retry moving your old settings and prompt edits into the built-ins and watches (the Inbox's **Retry**); refused in a coding agent's shell. Restart the daemon after "moved" |
| `watchtower automations reply --output <id> --action <n>` | An Inbox card's Reply press: records it and queues one run; [Buttons on automation cards](../features/automations-inbox-buttons.md) |
| `watchtower actions` | Proposed assistant actions: list, approve, reject, tool trust; `propose --approve` is the Inbox's own Apply press on a track's change; a row's **Reply…** proposes without it, into Needs approval |
| `watchtower reaction-commands` | Slack emoji reactions that drive the assistant |

### Why the app asks you to confirm a command

Some commands are yours alone: `actions approve`, `dismiss`, `apply` and `propose --approve`, `actions trust … execute`, `tracks start`, `tracks watch`, `tracks instruction` and `tracks enable` of a watch, `automations confirm`, `enable`, `delete`, `reset`, `reply`, `auto … on` and `dry-run` of a recipe not confirmed yet, review Undo, lessons, send and approve, and the ask guard and finish check of `workbench methodology`. Run one from a terminal and Watchtower shows a **Confirm in Watchtower** window with the whole command and what it changes (the action's args, the recipe, the hunk). The command waits up to 100 seconds; **Confirm** turns on after a second, and **Deny**, Return and Escape refuse it.

- The buttons in the app never ask: the app confirms its own commands.
- With the app closed, the command is refused with **open Watchtower to confirm this**.
- A coding agent's shell (Claude Code, Codex, a workbench terminal) is refused outright, without a window.
- One window at a time: a second command is refused with **another confirmation is already open**.
- Only a properly signed Watchtower app is trusted to confirm. An unsigned or self-built app is refused, its own buttons included, unless both it and the CLI are development builds started with `WATCHTOWER_DEV_TRUST_UNSIGNED_DESKTOP=1`; even then the app must carry the identifier `com.watchtower.desktop`.

This keeps an agent that was talked into running such a command from going ahead on its own. It does not stop a malicious program running as you, which could change Watchtower's data directly.

## Workbench and coding agents

| Command | What it does |
|---|---|
| `watchtower workbench` | [Workbenches](../features/workbench/README.md): board, comments, sessions, asks, review, cleanup |
| `watchtower integrate claude-code\|codex\|status\|remove` | Wire Watchtower into [Claude Code or Codex](../features/claude-code-integration.md) |
| `watchtower mcp` | Run the MCP server over stdio |
| `watchtower mcp --connect <service>` | The [connect assistant](../features/connect-with-an-agent.md)'s tools for one service; runs only inside a connect run the app started, and alone (no other `mcp` flag) |
| `watchtower tools` | Call the read-only data tools from the console |
| `watchtower agents enable\|disable\|scan\|stats\|report` | [Agent analytics](../features/agent-analytics.md) |
| `watchtower coach status\|proposals\|accept\|decline\|rollback\|run` | [Agent coach](../features/agent-coach.md) |
| `watchtower code index\|search` | Symbol index and text search for a workbench folder |

## Headless host

Commands for a [headless host](../features/headless-host.md): a Linux box or a Mac without the app. On a Mac with the Watchtower app the `hub` commands work on the app's hub too; while an older version's iPhone sync still waits to be moved over, the ones that change something refuse with **Mobile on this Mac is run by the Watchtower app.** Add `--json` for scripts.

| Command | What it does |
|---|---|
| `watchtower workspace init --headless` | Create the workspace with every non-core feature off, so only the workbenches run. An existing config keeps its features (**Kept your feature settings.**) |
| `watchtower service install` | Create the workspace (as `--headless`), turn the hub on and install and start the daemon as a systemd user unit (`watchtower.service`) or a LaunchAgent; prints the linger hint when needed. Safe to run again |
| `watchtower service uninstall` | Stop and remove the service; your data and running sessions stay |
| `watchtower service status` | Whether the service is installed and running, and on Linux whether linger is on |
| `watchtower hub status` | The hub's state and reason, its host kind and mode, and the number of phones |
| `watchtower hub pair` | Link a phone from this terminal: a QR code, a link, then **Confirm code 1234 on your phone? [y/N]**. Scripts use `--json --stream` |
| `watchtower hub phones` | Linked phones with their device ids and grants |
| `watchtower hub diagnostics [--days N]` | How long the hub took to apply phone actions and save what they changed, p50 and p90 per step and transport (and per kind of action) over the last 1–7 days (7 by default), and how many alerts were dropped because too many were waiting. Timings only, kept on this machine; works without a running hub |
| `watchtower hub allow <device> typing\|permissions\|start_sessions` | Let a phone type into sessions, answer permission prompts or start sessions; `--revoke` takes it back |
| `watchtower hub unlink <device>` | Unlink a phone |
| `watchtower hub name <name>` | The name phones show for this host (the hostname by default) |
| `watchtower hub enable\|disable` | Turn the hub on or off |
| `watchtower hub recordings on\|off` | Phone recordings for this hub; `on` is refused with **this host has no transcriber** where no Watchtower app ever ran, so a Linux host stays off |
| `watchtower config set hub.relay_origin <origin>` | Point the hub at another relay (`https://host[:port]`); empty goes back to the build's own |

`service install|uninstall` and the `hub` commands that change something are yours alone: a coding agent's shell is refused, and the terminal is the confirmation. The Desktop's **Confirm in Watchtower** commands above stay refused on Linux, where there is no app to confirm them.

## AI and usage

| Command | What it does |
|---|---|
| `watchtower ai models` | Models per provider and tier |
| `watchtower ai background status [--json]` | Whether [background AI](../concepts/features-on-and-off.md#paused-is-not-off-background-ai) may run and who decided: you, nobody yet, or your organization (`effective`, `reason`, `answer`, `policy`) |
| `watchtower ai background allow [--yes]` | Let Watchtower run AI on its own. On a terminal it shows what runs and asks **Allow background AI? [y/N]**; without a terminal it needs `--yes`. Refused when your organization turned background AI off. Wakes the running daemon |
| `watchtower ai background pause` | Pause it; sync and everything you start yourself keep running |
| `watchtower ai which --provider claude\|codex --json` | The claude or codex executable Watchtower would run (`provider`, `path`, `found`); the Desktop app asks it, and offers **Connect with Claude** or **Codex** only for one it finds |
| `watchtower ai query --tools connect --connect-service <service> --connect-mode browser\|words\|probe` | One turn of the [connect assistant](../features/connect-with-an-agent.md), run by the app: only that service's connect tools (and Claude in Chrome in `browser` mode, limited to the playbook's sites); refused for a provider that can't guide a connection or that your organization blocks |
| `watchtower usage plan` | Claude plan limits (5-hour, weekly) |
| `watchtower usage plans --json [--now] [--provider all\|claude\|codex]` | Separate subscription snapshots; `--now` refreshes selected sources, with partial results on failure |
| `watchtower usage llm [--since today\|7d\|30d] [--json]` | AI calls, tokens and cost: Watchtower, your automations, chats, workbenches ([AI providers, models and cost](../concepts/ai-providers-and-cost.md)) |
| `watchtower prompts`, `tune` | Prompt templates and feedback-based tuning |
| `--provider claude\|codex\|ollama` | Per-command provider override |

`terminal`, `dictate` and `chat` are helpers the Desktop app calls; `ai` is too, apart from `ai models` and `ai background`.

A daemon started without the app (a [headless host](../features/headless-host.md) included) keeps background AI paused until you run `watchtower ai background allow`; `watchtower status` prints a **Background AI:** line. `config set ai.background_runs` is refused: use `ai background`.

For `usage plans`, `--provider` selects subscriptions, independently of the AI backend. Read-only calls return saved data without creating or migrating a database. Refresh exits 3 when **Subscription plan limits** is off; source/read failures exit 1 with partial JSON, and SIGINT/SIGTERM use 130/143 when a partial response can be written.
