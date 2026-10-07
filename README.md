<p align="center">
  <img src="assets/banner.png" alt="Watchtower" width="400" />
</p>

<p align="center">
  A local AI assistant for your work on macOS.<br/>
  Syncs Slack, Gmail, Calendar, Jira and Confluence locally, tells you what needs your attention, and works your tasks with you.
</p>

## What is Watchtower?

Watchtower is a native macOS app that turns your work sources into an actionable, searchable knowledge base. A background daemon syncs Slack, Gmail, Google Calendar, Jira and Confluence into a local SQLite database, then AI pipelines distill them into briefings, digests, tracks, people cards and a memory the assistant draws on — all without leaving your desktop.

```
[Slack · Gmail · Calendar · Jira · Confluence] → [Local SQLite] → [AI Pipelines] → [Desktop App]
                                                                        ↓
                                                    Briefings · Catch-Up · Digests · Tracks
                                                    People · Ideas · Memory · Knowledge search
```

**Key principles:** your data is stored locally in SQLite; it leaves your machine only as AI prompts to the provider you pick (the Claude Code or Codex CLI, or none with a local Ollama-compatible server), as writes you approve (Slack messages, Jira, Confluence), and as calls to external MCP servers you add yourself. Nothing is posted to Slack, Jira or Confluence without your Approve.

## Features

- **Daily Briefings** — a morning overview: what needs attention, your day, what happened
- **Catch-Up** — a recap of the window you were away for
- **Inbox** — a queue of decisions waiting on you: proposals from the chats and from Slack reaction commands (react with an emoji to turn a message into a task, idea or reminder)
- **Targets** — your tasks, with an AI chat per target that proposes or applies changes
- **Tracks** — narrative tracks of what is going on across conversations
- **Digests** — channel summaries, daily rollups and weekly trends
- **AI Chat** — ask about your work in natural language; it can draft and, after your Approve, send Slack messages or edit Confluence pages
- **Workbench** — a folder-bound board that a Claude Code session works in an embedded terminal, with asks back to you and a code viewer
- **Meetings** — recording, live transcription with speaker diarization, notes and meeting prep
- **Ideas & Decisions** — ideas and decisions mined from your sources
- **Memory** — a local vault of what the assistant has learned about your people, projects and work
- **Knowledge search** — full-text search across messages, mail, Jira, Confluence pages, meetings and more
- **Jira** — boards, workload, blockers, project map and releases
- **People** — communication styles, roles and activity patterns
- **Voice dictation** — dictate into the app's text fields, or capture a voice idea from anywhere with ⌃⌥D
- **MCP server** — `watchtower mcp` exposes your data to any MCP client (read-only). See [docs/mcp-server.md](docs/mcp-server.md).

## Install

### One-liner (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/aiwatchtowers/watchtower/main/scripts/install.sh | bash
```

Installs the desktop app to `/Applications` and the `watchtower` CLI to your PATH.

### From source

Requires Go 1.25+, a Swift 6+ toolchain (Xcode 16+), macOS 14+.

```bash
git clone https://github.com/aiwatchtowers/watchtower.git
cd watchtower
make app          # Full release build → build/Watchtower.app (see "Rebuilding while the app runs")
# or
make app-dev      # Fast dev build
```

### Pre-built binaries

Download from [Releases](https://github.com/aiwatchtowers/watchtower/releases) (macOS Apple Silicon).

## Getting Started

1. Open **Watchtower.app**. Setup takes three steps; everything in them can be skipped except the AI check in the first:
   - **Goals** — pick what you want Watchtower for (work communication, tasks & Jira, meetings, development in Workbench). Continue unlocks once the AI check passes.
   - **Connect** — connect Slack, Google (Gmail + Calendar) and Jira, or skip and do it later from Settings → Connections.
   - **About you** — your role, manager, reports and peers (shown once Slack is connected).
2. The app starts the background daemon itself; data appears as the first sync runs.

**Prerequisites:** an AI provider that `watchtower ai test` accepts — [Claude Code](https://docs.anthropic.com/en/docs/claude-code) or the Codex CLI, installed and signed in (setup checks for these), or a local Ollama-compatible server set up beforehand from the CLI (`watchtower config set ai.provider ollama`, then `watchtower config set ai.models.strong <model>`).

### Headless / CLI only

```bash
watchtower slack add                   # Connect a Slack workspace (OAuth in the browser)
watchtower sync --daemon --detach      # Start the background daemon
watchtower sync --stop                 # Stop it
```

## How It Works

The daemon (`watchtower sync --daemon`) polls Slack and the other connected sources, then runs its AI and indexing phases after each sync: channel digests, tracks and rollups, people cards, inbox detection, reaction commands, ideas, memory, the knowledge index, and the daily briefing (once per day). Each phase can be switched off from Settings → Features or `watchtower features`.

The desktop app reads the same SQLite database via GRDB and updates in real time.

## Configuration

Config file: `~/.config/watchtower/config.yaml`

```yaml
sync:
  poll_interval: "15m"
  workers: 5
  initial_history_days: 30
ai:
  provider: "claude"      # claude | codex | ollama
  models:
    light: "haiku"        # optional per-tier overrides
    strong: "opus"
digest:
  enabled: true
  language: "English"
briefing:
  enabled: true
  hour: 8
```

Settings are also editable from the desktop app (Settings window).

## Data Storage

| What | Where |
|------|-------|
| Database | `~/.local/share/watchtower/<workspace>/watchtower.db` |
| Config | `~/.config/watchtower/config.yaml` |
| Logs | `~/.local/share/watchtower/<workspace>/watchtower.log` |

All data is local. SQLite with WAL mode for concurrent access. The desktop app and daemon share the same database.

## CLI Reference

The CLI provides access to most features and is required for the daemon:

```bash
watchtower slack add                  # Connect a Slack workspace
watchtower sync [--daemon|--full]     # Sync data
watchtower ask "<question>"           # AI query
watchtower briefing                   # View daily briefing
watchtower catchup                    # Recap a window you were away for
watchtower inbox                      # Messages awaiting your response
watchtower targets                    # Your tasks
watchtower tracks                     # Narrative tracks
watchtower digest                     # View digests
watchtower people                     # People analytics
watchtower ideas                      # Ideas & decisions registry
watchtower memory                     # Inspect the assistant memory vault
watchtower jira                       # Jira sites and boards
watchtower workbench                  # Folder-bound workbench boards
watchtower features                   # Turn features on and off
watchtower ai test                    # Check the AI provider
watchtower mcp                        # Read-only MCP server over stdio
watchtower config set <key> <val>     # Configure
watchtower feedback <good|bad> ...    # Rate AI output
watchtower tune [--apply]             # Improve prompts from your ratings
```

## Development

```bash
make build        # Build Go CLI only
make test         # Go tests
make test-swift   # Swift tests
make lint-all     # Go + Swift linting
make app-dev      # Fast dev build (CLI + desktop)
make app          # Release build with notarization
make app-swap     # Finish a deferred swap (see below)
make app-install  # Copy build/Watchtower.app to /Applications (INSTALL_DIR=...)
```

### Rebuilding while the app runs

`make app` / `make app-dev` build into `build.next/` and swap it into `build/`
only at the end, so there is no need to quit Watchtower for the build. If the
app is running from `build/`, the swap is deferred: quit Watchtower, then run
`make app-swap` (`WAIT=1 make app-swap` waits for
the quit and swaps right after). A deferred release build exits 3 (built, swap
deferred; its DMG/ZIP are still in `build.next/`), a deferred `make app-dev`
exits 0. Recommended habit: run the installed copy via
`make app-install`, which leaves `build/` free so the swap never waits. If the
installed copy is running, `make app-install` asks you to quit it, waits, and
relaunches it after the copy. Neither script ever quits or kills the app.

### Build profiles

OAuth credentials come from `.env` (gitignored) and are baked in via ldflags.
An alternative credential profile can be selected per build with
`ENV_FILE=<file> make app`. A non-default profile must set `BUILD_FLAVOR`
(`[A-Za-z0-9._-]+`): the flavor is stamped into the binary
(`watchtower version`), the app bundle (`WTBuildFlavor` in Info.plist), and the
artifact names (`Watchtower-<flavor>-arm64.dmg`), keeping builds with different
credential sets distinguishable. Flavored builds are distributed out-of-band —
they never ship via the public release feed, `scripts/install.sh`, or the
in-app updater (which they deliberately skip).

## License

MIT — see [LICENSE](LICENSE).
