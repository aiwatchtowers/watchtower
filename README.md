<p align="center">
  <img src="assets/banner.png" alt="Watchtower" width="400" />
</p>

<h3 align="center">Your work, your agents, one local Mac app.</h3>

<p align="center">
  Watchtower reads your Slack, mail, calendar and Jira, tells you what needs you, and gives your Claude Code or Codex sessions a board to work from.<br/>
  For developers who run coding agents, and for anyone drowning in work chat. Everything is stored on your Mac.
</p>

<p align="center">
  <a href="https://github.com/aiwatchtowers/watchtower/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/aiwatchtowers/watchtower?sort=semver"></a>
  <img alt="macOS 14+ on Apple Silicon" src="https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20Silicon-black?logo=apple">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/github/license/aiwatchtowers/watchtower"></a>
</p>

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/aiwatchtowers/watchtower/main/scripts/install.sh | bash
```

This puts **Watchtower.app** in `/Applications` and the `watchtower` CLI on your PATH. Prefer a download? Get the latest build from [Releases](https://github.com/aiwatchtowers/watchtower/releases/latest).

**You need:**

- A Mac with Apple Silicon (arm64) on macOS 14 or later.
- An AI provider. Watchtower has no AI of its own and no API key to paste: it runs through [Claude Code](https://docs.anthropic.com/en/docs/claude-code) or the Codex CLI, installed and signed in, or through a local Ollama-compatible server you set up from the CLI first (`watchtower config set ai.provider ollama`). See [AI providers, models and cost](docs/guide/concepts/ai-providers-and-cost.md).

Open the app and setup takes two screens: pick your goals, connect your sources (or skip them all and use only Workbench). Details are in [Set up Watchtower](docs/guide/start/setup.md).

## For you if you work with coding agents

You run Claude Code or Codex every day and want to stay in charge of what they do.

- **Keep the plan when the session ends.** A workbench binds a folder to a board of targets; each session picks up a task and the board outlives every session. → [Workbench](docs/guide/features/workbench/README.md)
- **Answer the agent only when it needs you.** It files an ask for a decision or a review and keeps working on what does not depend on you. You see one stack of what is waiting. → [Asks](docs/guide/features/workbench/asks.md)
- **Review the change before it is committed.** Comment on lines of a session's diff and send them back as one round; the next round shows only what moved. Specs and plans get an independent AI reviewer first. → [Branch review](docs/guide/features/workbench/diff-review.md), [Spec review](docs/guide/features/workbench/spec-review.md)
- **Know what your agents cost and fix the habit behind it.** Analytics totals tokens, cost, tools and errors per workbench; the coach proposes edits to your own agent setup and changes nothing until you accept. → [Agent analytics](docs/guide/features/agent-analytics.md), [Agent coach](docs/guide/features/agent-coach.md)
- **Stay in one window.** Sessions run in an embedded terminal next to a code viewer with git marks, and they keep running through an app update or a **Keep Sessions and Quit**. → [Sessions](docs/guide/features/workbench/sessions.md), [Code viewer](docs/guide/features/workbench/code-viewer.md)

## For you if work chat is eating your day

You come back to hundreds of Slack messages, a full mailbox and back-to-back meetings.

- **Start the day with one read.** A morning briefing and a day plan cover what needs you, your meetings and what happened in your channels. → [Briefings](docs/guide/features/briefings.md), [Day Plan](docs/guide/features/day-plan.md)
- **Come back from time off without scrolling.** Catch Up recaps the stretch you were away: what happened and what is waiting on you. → [Catch Up](docs/guide/features/catch-up.md)
- **See every decision waiting on you in one list.** The Inbox gathers your day, messages to answer, tracked requests, ideas and reminders; react to a Slack message with an emoji and a track, an idea or a draft issue comes back as a card. → [Inbox](docs/guide/features/inbox.md)
- **Ask about your work, and act on it safely.** The AI chat knows your Slack, mail, Jira, Confluence and meetings. It can draft a Slack message, comment on a Jira issue or edit a Confluence page, and nothing is sent until you press Approve. → [AI chat](docs/guide/features/ai-chat.md), [Writing and changing things](docs/guide/features/ai-chat-actions.md)
- **Leave meetings with a recap you did not write.** Record a call and get a transcript with speakers and a recap with action items; audio is transcribed on your Mac and never leaves it (macOS 14.4+). → [Meeting recording](docs/guide/features/meeting-recording.md)

## Works with

Slack (several workspaces), Gmail and Google Calendar (several accounts), Outlook and IMAP mail, Jira, Linear and Confluence. You can also add your own MCP servers as Quick Connections, and `watchtower mcp` serves your data to any MCP client. See [Sources and accounts](docs/guide/concepts/sources-and-accounts.md).

## Privacy

Watchtower has no account, no cloud service and no analytics of its own. Synced data, AI results, sign-ins, the search index and meeting transcription stay on your Mac. Data leaves it only:

- as prompts to the AI provider you pick (none at all with a local Ollama-compatible server);
- as writes you approve: a Slack message, a Jira change, a Confluence edit;
- as calls to the sources you connect and to external MCP servers you add yourself.

Nothing is posted to Slack, Jira or Confluence without your Approve. The full picture is in [Privacy](docs/guide/concepts/privacy.md).

## How it works

```
[Slack · Mail · Calendar · Jira · Linear · Confluence] → [Local SQLite] → [AI pipelines] → [Desktop app]
                                                                                ↓
                                     Briefings · Catch Up · Inbox · Digests · People · Memory · Search
```

A background daemon syncs your sources into a local SQLite database, then runs its AI and indexing steps after each sync. The desktop app reads the same database and updates as data arrives. Each background feature can be switched off in **Settings → Features** or with `watchtower features`. More in [How Watchtower works](docs/guide/concepts/how-watchtower-works.md).

## Documentation

The [user guide](docs/guide/README.md) covers setup, every feature and troubleshooting. Reference pages:

- [CLI reference](docs/guide/reference/cli.md): everything the app does is also a `watchtower` command, including headless use (`watchtower slack add`, `watchtower sync --daemon --detach`).
- [Settings](docs/guide/reference/settings.md): what each Settings tab controls. The same settings live in `~/.config/watchtower/config.yaml` and can be changed with `watchtower config set <key> <value>`.
- [Keyboard shortcuts](docs/guide/reference/keyboard-shortcuts.md) and the [glossary](docs/guide/reference/glossary.md).

Your data lives in `~/.local/share/watchtower/<workspace>/` (database, logs, sign-ins); meeting recordings are in `~/Library/Application Support/Watchtower/recordings`.

## Building from source

Requires Go 1.26+, a Swift 6+ toolchain (Xcode 16+) and macOS 14+.

```bash
git clone https://github.com/aiwatchtowers/watchtower.git
cd watchtower
make app-dev      # fast dev build (CLI + desktop) → build/Watchtower.app
make app          # release build with notarization
```

Other targets:

```bash
make build        # Go CLI only
make test         # Go tests
make test-swift   # Swift tests
make lint-all     # Go + Swift linting
make app-swap     # finish a deferred swap (see below)
make app-install  # copy build/Watchtower.app to /Applications (INSTALL_DIR=...)
```

To contribute, start with [CONTRIBUTING.md](CONTRIBUTING.md). Developer notes for each feature are in [docs/features/](docs/features/), and the repo conventions are in [CLAUDE.md](CLAUDE.md).

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
