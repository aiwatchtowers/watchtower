# Settings

Seven tabs, in this order: **General**, **Connections**, **Features**, **Meetings**, **System**, **Mobile**, **Profile**. Settings opens on **Connections**. Tabs that edit configuration share one **Save** bar (⌘S); the **Mobile** switch and the **Skills** card apply at once. This page lists only what the screen does not explain.

## General

- **Assistant language** — the language of Catch Up, briefings, tracks and digests. A new install starts from your Mac's first preferred language, else English. In chat the assistant answers in the language you write. See [AI providers and cost](../concepts/ai-providers-and-cost.md).

## Connections

A list of services (Slack, Google, Email, Calendar, Jira, Linear, Quick Connections) with a status dot: green connected, red when an account has an error or needs re-login, gray not set up. You never type an account name: Watchtower names each after what it connected to; **Rename…** changes it (Linear has no **Rename…**). See [Sources and accounts](../concepts/sources-and-accounts.md).

- **Remove** stops syncing and deletes the sign-in. Slack, Jira and Linear keep their synced data (with [revoked-access deletion](../concepts/revoked-access.md) on, until 30 days without access); Google deletes its synced mail and events; Email and Calendar do too, although their dialogs say they are kept (see [Known issues](../troubleshooting/known-issues.md)). A disabled account (**Enabled** off, Slack, Jira and Linear only) stops syncing and keeps its data.
- After you connect a source, a **Turn on related features?** sheet may offer features that source can feed. Nothing turns on unless you press **Turn on**. See [Features on and off](../concepts/features-on-and-off.md).
- **Slack** — **Reconnect** also grants a newly needed permission, such as sending messages from chat. The emoji-to-action list used by the [Inbox](../features/inbox.md) action strip is edited on the **Reactions** card in **Automations** → **Built in** ([Reactions and tracks in Automations](../features/automations-rules.md)); here **Open** takes you there.
- **Google** — **Add Google Account** grants Calendar and/or Gmail per account. **Sync days ahead** for Calendar: 2, 3, 5, 7 or 14. See [Calendar](../features/calendar-and-meeting-prep.md) and [Mail](../features/mail.md).
- **Jira** — **Manage Boards** selects boards, shows board profiles and user mapping. See [Jira and Linear](../features/jira-and-linear.md).
- **Linear** — workspaces (browser sign-in or API key), **Enabled**, **Re-login**, **Remove**, and the **Teams** to sync per workspace. See [Linear](../features/linear.md).
- **Confluence** (under each Jira site) — pick spaces to sync into search. **Grant Confluence access** and **Allow editing** are extra sign-ins; switching a space off removes its synced content. See [Search and knowledge](../features/search-and-knowledge.md).
- **Quick Connections** — outside tool servers the assistant may read from; write tools never reach the chat. See [Quick Connections](../features/quick-connections.md).

## Features

- The list turns each feature on or off, asking first if others depend on the one turned off. **Keep ML engines in memory** keeps the speech models loaded. **Save** restarts the background sync once. See [Features on and off](../concepts/features-on-and-off.md).
- **Briefing, Day Plan, Tracks, Ideas and Reaction commands** have no switch here: "These now live in Automations → Built in", and **Open Automations** leads there. See [Built-in automations](../features/automations-built-in.md).
- Tuning sections appear only while their feature is on:
  - **Digest**: minimum messages.
- Notifications:
  - One **Notifications** section holds every switch: **Pause notifications**, **Decision notifications**, **Briefing notifications**, **Workbench notifications**, **Claude plan limits**, **Notify about unknown voices** and **Meeting reminders** with **Remind before meeting** (0–60 minutes; 0 is **Off**).
  - **Pause notifications** (off by default) silences every notice, including the "still recording" alert, which no other switch affects. When you turn it off, new decisions and briefings, plan-limit warnings and reminders for meetings still ahead are sent; an update is announced on a later check; the rest are dropped.
  - **Send Test Notification** works even while paused.

## Meetings

- Four groups: **Engine** (engine, model, **Dictation model**, language set), **Recording** (**Auto-record on join**, **Live transcription**, **Preload model before meetings**, **Mic auto-gain (experimental)**), **Speakers** (**Speaker roles**, **Voice recognition**) and **Advanced**. See [Meeting recording](../features/meeting-recording.md) and [Voice dictation](../features/voice-dictation.md).

## System

- **AI** — provider (Claude, Codex, Ollama / Local), **Light Model** and **Strong Model** (empty = the provider's default), CLI paths (empty = auto-detected), **Test Connection**. See [AI providers and cost](../concepts/ai-providers-and-cost.md).
- **Workbench** — **Default Agent** (Claude Code or Codex) for new sessions and the **Work on It** button (the menu offers **Work on It with …** the other agent). Your standing directions moved to **Profile → Instructions**; this tab keeps a pointer. See [Your instructions](../features/workbench/instructions.md).
- **Sync** — **Poll Interval** (default `15m`), **Workers**, **Initial History Days** (bounds the first Slack sync to a few days; the month of history comes from [history backfill](../concepts/history-backfill.md)), **Sync Threads**.
- **Daemon** — read-only status; the app starts and stops it. **Open Logs** opens the live log window.
- **Data** — storage, **Reset AI-Generated Data** (deletes what the AI made, then rebuilds it), and **Reset All Data** under Danger Zone.
- **Privacy** — **Delete an account's data when its access is revoked** (off by default, on in the corporate build), and **Organization policy** when your company manages the Mac. See [Revoked access](../concepts/revoked-access.md) and [Managed by your organization](../concepts/managed-by-your-organization.md).
- **Update** — checks on launch and every 6 hours; nothing downloads until you press **Download** here or **Update Now** in the Software Update window. See [Menu bar and updates](../features/menu-bar-and-updates.md).

## Mobile

- **Sync with iPhone** (off by default) makes this Mac the hub for the iPhone app, through your own iCloud. On a build without iCloud signing it says **Needs a signed build**. **Use Watchtower on iPhone** shows a QR code valid for 10 minutes. See [iPhone](../features/iphone.md).
- Each linked phone shows **Same Apple ID** or **Shared** and one line per permission, each with **Allow…** or **Revoke**: typing into your sessions, starting sessions (allowed only once typing is: **Starting sessions needs typing**) and answering permission prompts. **Remove…** unlinks it.

## Profile

- **Instructions** — **For chats and agents**, **Only in chats** and **Target procedure**, each with its own **Save**, and **Preview what the agent gets…**. See [Your instructions](../features/workbench/instructions.md).
- Your role, team, manager, reports, peers and starred channels and people. **Run Setup Again** repeats [setup](../start/setup.md).
- **Skills** — turn skills on or off, edit them, or add **New Skill**. Built-in skills can be disabled but not deleted.
- **Assistant tools** — per write tool, **Run without approval in:** checkboxes for **Chat**, **Target chat**, **Slack reactions** and **Automations**. Tools that write outside this Mac (tagged *external*) always need approval, everywhere. See [AI chat](../features/ai-chat.md).
- **claude.ai tools** — the connectors of your claude.ai account the main chat can use on the Claude provider (all on by default). **Connectors** switches them all off or on; each connector has its own switch and shows its status and tools, marked *read-only* or *destructive* when the connector says so. A connector shown **Not connected** has a **Connect on claude.ai** link. Switches apply to new chat turns: idle chats restart, a reply already running keeps its tools. Embedded chats never get these tools. See [Writing and changing things from the AI Chat](../features/ai-chat-actions.md#claudeai-connectors).
