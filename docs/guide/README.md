# Watchtower user guide

Watchtower is a macOS app that mirrors your Slack, Google, Jira and meetings into a database on your Mac. It puts AI on top: briefings, a day plan, an inbox of what needs you, and a chat that knows your work. Its Workbench lets Claude Code or Codex work from a board of targets you control.

Every page of the guide is listed below, once, grouped by what it helps with.

## Start here

- [Your first week](start/first-week.md) — a short tour of what to try, in the order it pays off, from setup to your first automation
- [Set up Watchtower](start/setup.md) — pick your goals, connect sources and get through the two setup screens, and run setup again later

## How Watchtower works

- [How Watchtower works](concepts/how-watchtower-works.md) — the local database, the sync cycle and a table of what runs when, so you know why a tab is empty
- [Sources and accounts](concepts/sources-and-accounts.md) — what each connected source gives, several accounts of one kind, what removing one does, and why Watchtower needs to know who you are
- [History backfill](concepts/history-backfill.md) — how the first month of a new source loads in the background, and what it skips
- [Turning features on and off](concepts/features-on-and-off.md) — the switches, what feeds what, and how to read an empty tab's status line
- [AI providers, models and cost](concepts/ai-providers-and-cost.md) — Claude, Codex or Ollama, light and strong models, what costs tokens, and your Claude plan limits
- [Privacy](concepts/privacy.md) — what stays on your Mac, what goes to your AI provider, and what goes to iCloud

## Troubleshooting

- [Troubleshooting](troubleshooting/README.md) — find what you see on the screen and open the page that fixes it
- [A tab is empty](troubleshooting/tab-is-empty.md) — which switch and source each tab waits for, and what its status line wants
- [Sync is stuck or slow](troubleshooting/sync-stuck-or-slow.md) — "Sync daemon not running", a sync that never ends, data that stops arriving
- [No briefing or day plan today](troubleshooting/no-briefing-or-day-plan.md) — the gates a daily job waits behind, and how to generate one now
- [The Claude or Codex tool is not found or not signed in](troubleshooting/ai-tool-not-found-or-not-signed-in.md) — the red cross, "isn't signed in", and Test Connection
- [An account needs attention](troubleshooting/account-needs-attention.md) — red dots, Re-login, and which accounts you must remove and add again
- [Calendar events are missing](troubleshooting/calendar-events-missing.md) — a hidden Calendar tab, sync banners and unselected calendars
- [Recording or transcript problems](troubleshooting/recording-or-transcript-problems.md) — macOS permissions, no call audio, failed transcription and missing recaps
- [A Workbench session or ask is stuck](troubleshooting/workbench-session-or-ask-stuck.md) — an answer that did not reach the agent, a session with no state
- [The iPhone is not syncing](troubleshooting/iphone-not-syncing.md) — "Mac offline", pairing across builds, codes and iCloud
- [Plan limits and high cost](troubleshooting/plan-limits-or-high-cost.md) — Claude plan warnings, rate limits and how to spend fewer tokens
- [Known issues](troubleshooting/known-issues.md) — where the app does something other than its screen says, with workarounds

## Focus

- [Home](features/home.md) — what needs you right now, setup progress, and how the menu works
- [Catch Up](features/catch-up.md) — a recap of a stretch of time you were away: what happened and what needs you
- [Briefings](features/briefings.md) — one morning read of your attention items, day, channels and people
- [Day Plan](features/day-plan.md) — today as time blocks plus a backlog, with calendar conflicts flagged
- [Inbox](features/inbox.md) — reminders, proposals to approve, Slack reaction commands and attention detection
- [Ideas & Decisions](features/ideas-and-decisions.md) — proposals mined from chats, mail, Jira and meetings, for you to triage
- [Mail](features/mail.md) — what Gmail, Outlook and IMAP mail feeds into Catch Up, briefings, meeting prep and Ideas

## Execution

- [Targets](features/targets.md) — your own to-do list, with a next step per target and an assistant that breaks work down on your instruction
- [Tracks](features/tracks.md) — the requests and decisions waiting on you, pulled out of Slack digests, plus custom watches on topics you describe
- [Jira and Linear](features/jira-and-linear.md) — see stuck, late and overloaded work across your Jira boards, and connect Linear

## Insights

- [Digests](features/digests.md) — per-channel, daily, mail, Jira and meeting summaries in one feed, with a journal of decisions
- [People](features/people.md) — a card per colleague with style, role and tips, plus a team summary
- [Statistics](features/statistics.md) — channel and user activity, and the mute switch that decides what the AI reads
- [Search and knowledge](features/search-and-knowledge.md) — find a Slack message, or let the assistant search everything you have synced

## Workbench

- [Workbench](features/workbench/README.md) — a folder, a board, agent sessions and asks: what a workbench is and how to start one
- [Board and targets](features/workbench/board-and-targets.md) — the plan the agent and you share: Kanban, grouping, archive and the git drift check
- [Sessions](features/workbench/sessions.md) — what each session's state means, and how to start, find, resume and clear them
- [Asks](features/workbench/asks.md) — reviews, checks and decisions the agent files for you, and how your answer gets back
- [Code viewer](features/workbench/code-viewer.md) — read and edit the folder's files, jump to definitions with Open Quickly, and ask about code
- [Worktrees and cleanup](features/workbench/worktrees-and-cleanup.md) — an own git worktree per parallel session, and safe removal of what a session leaves behind
- [Diff review](features/workbench/diff-review.md) — review what a session changed, comment on lines and send the round to the agent
- [Methodology](features/workbench/methodology.md) — the workflow file, **Agent Settings…** and the ask guard that shape how agents work
- [Codex](features/workbench/codex.md) — run Codex instead of Claude Code in a workbench
- [Agent analytics](features/agent-analytics.md) — tokens, cost and tool use of the agent sessions in a workbench, on the Analytics view or from the command line

## Automations & AI

- [AI Chat](features/ai-chat.md) — ask the assistant about your work, attach files, get documents back, organize chats into projects
- [Writing and changing things from the AI Chat](features/ai-chat-actions.md) — proposals you approve: tasks, Jira, Slack messages, Confluence edits, automation drafts
- [Quick Connections](features/quick-connections.md) — plug other tools' MCP servers into the chat as read-only sources
- [Memory](features/memory.md) — the assistant's long-term notebook of people, projects and beliefs, in plain files you can edit
- [Automations](features/automations.md) — recipes the daemon runs on a schedule, on sync events or on demand, with confirmation, budgets and auto grants
- [Automations: recipes and templates](features/automations-recipes.md) — the parts of a recipe, event triggers and the five ready-made templates

## Meetings & calendar

- [Calendar and meeting prep](features/calendar-and-meeting-prep.md) — one timeline of meetings and recordings, plus an AI brief on the people before you join
- [Meeting recording](features/meeting-recording.md) — record a call locally and get a transcript, recap, action items and named speakers
- [Voice dictation](features/voice-dictation.md) — speak instead of typing in chats, ideas and notes, or capture an idea from anywhere

## Apps & integration

- [iPhone](features/iphone.md) — answer asks, edit the Workbench board, start sessions and record meetings from your phone, through your own iCloud
- [Menu bar and updates](features/menu-bar-and-updates.md) — what the menu shows, what closing and quitting do, and how updates arrive
- [Claude Code integration](features/claude-code-integration.md) — let your coding agent query Watchtower through a read-only MCP server and three skills

## Reference

- [Settings](reference/settings.md) — what each Settings tab does that the screen doesn't say
- [Keyboard shortcuts](reference/keyboard-shortcuts.md) — every key equivalent, by area
- [Command line](reference/cli.md) — the `watchtower` commands, grouped
- [Glossary](reference/glossary.md) — the terms the guide uses, one line each
