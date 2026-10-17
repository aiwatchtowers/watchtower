# Settings

Seven tabs, in this order: **General**, **Connections**, **Features**, **Meetings**, **System**, **Mobile**, **Profile**. Settings opens on **Connections**. Tabs that edit configuration share one bottom **Save** bar (⌘S); the **Mobile** switch and the **Skills** card apply at once. This page lists only what the screen does not explain.

## General

- **Assistant language** — the language of Catch Up, briefings, tracks and digests. A new install starts from your Mac's first preferred language, otherwise English. In chat the assistant answers in the language you write. See [AI providers and cost](../concepts/ai-providers-and-cost.md).

## Connections

A list of services (Slack, Google, Email, Calendar, Jira, Quick Connections) with a status dot: green connected, red when an account has an error or needs re-login, gray not set up. You never type an account name: Watchtower names the account after what it connected to, and **Rename…** changes it. See [Sources and accounts](../concepts/sources-and-accounts.md).

- **Remove** stops syncing and deletes the sign-in. Slack and Jira keep their synced data; Google, Email and Calendar delete the mail and events synced from that account, although the dialog says they are kept (see [Known issues](../troubleshooting/known-issues.md)). A disabled account (**Enabled** off, Slack and Jira only) stops syncing and keeps its data.
- After you connect a source, a **Turn on related features?** sheet may offer features that source can feed. Nothing turns on unless you press **Turn on**. See [Features on and off](../concepts/features-on-and-off.md).
- **Slack** — **Reconnect** also grants a newly needed permission, such as sending messages from chat. The **Reaction commands** list edits the emoji-to-action dictionary used by the [Inbox](../features/inbox.md) action strip.
- **Google** — **Add Google Account** grants Calendar and/or Gmail per account. **Sync days ahead** for Calendar: 2, 3, 5, 7 or 14. See [Calendar](../features/calendar-and-meeting-prep.md) and [Mail](../features/mail.md).
- **Jira** — **Manage Boards** selects boards, shows board profiles and user mapping. See [Jira and Linear](../features/jira-and-linear.md).
- **Confluence** (under each Jira site) — pick spaces to sync into search. **Grant Confluence access** and **Allow editing** are extra sign-ins; switching a space off removes its synced content. See [Search and knowledge](../features/search-and-knowledge.md).
- **Quick Connections** — outside tool servers the assistant may read from; write tools never reach the chat. See [Quick Connections](../features/quick-connections.md).

## Features

- The feature list turns each feature on or off; turning one off asks first if others depend on it. **Keep ML engines in memory** keeps the speech models loaded. **Save** restarts the background sync once. See [Features on and off](../concepts/features-on-and-off.md).
- Tuning sections appear only while their feature is on:
  - **Digest**: minimum messages.
  - **Briefing**: **Briefing Hour**. See [Briefings](../features/briefings.md).
  - **Day Plan**: **Generate at hour**, **Working hours:**, **Max timeblocks**, and **Backlog min** / **Backlog max** (saved, but not used by the plan today). See [Day plan](../features/day-plan.md).
  - **Ideas**: **Mining interval (hours)**, 1–48. See [Ideas and decisions](../features/ideas-and-decisions.md).
- Notifications:
  - One **Notifications** section holds every switch: **Pause notifications**, **Decision notifications**, **Briefing notifications**, **Workbench notifications**, **Claude plan limits**, **Notify about unknown voices** and **Meeting reminders** with **Remind before meeting** (0–60 minutes; 0 is **Off**).
  - **Pause notifications** (off by default) silences every notice, including the "still recording" alert, which no other switch affects. When you turn it off, new decisions and briefings, plan-limit warnings and reminders for meetings still ahead are sent; an update is announced on a later check; the rest are dropped.
  - **Send Test Notification** works even while paused.
- **Automations** off hides the tab and **Run Automation…**, and the daemon runs no recipe. See [Automations](../features/automations.md).

## Meetings

- Four groups: **Engine** (engine, model, **Dictation model**, language set), **Recording** (**Auto-record on join**, **Live transcription**, **Preload model before meetings**, **Mic auto-gain (experimental)**), **Speakers** (**Speaker roles**, **Voice recognition**) and **Advanced**. See [Meeting recording](../features/meeting-recording.md) and [Voice dictation](../features/voice-dictation.md).

## System

- **AI** — provider (Claude, Codex, Ollama / Local), **Light Model** and **Strong Model** (empty = the provider's default), CLI paths (auto-detected when empty), **Test Connection**. See [AI providers and cost](../concepts/ai-providers-and-cost.md).
- **Workbench** — **Default Agent** (Claude Code or Codex) for new sessions and the **Work on It** button (the menu offers **Work on It with …** the other agent). See [Workbench](../features/workbench/README.md).
- **Sync** — **Poll Interval** (default `15m`), **Workers**, **Initial History Days** (bounds the first Slack sync to a few days; the month of history comes from [history backfill](../concepts/history-backfill.md)), **Sync Threads**.
- **Daemon** — read-only status. The app starts and stops the daemon itself. **Open Logs** opens the live log window.
- **Data** — storage, **Reset AI-Generated Data** (deletes what the AI made, then rebuilds it) and, under Danger Zone, **Reset All Data**.
- **Update** — checks on launch and every 6 hours; nothing downloads until you press **Download** here or **Update Now** in the Software Update window. See [Menu bar and updates](../features/menu-bar-and-updates.md).

## Mobile

- **Sync with iPhone** makes this Mac the hub for the iPhone app, through your own iCloud. Off by default. On a build without iCloud signing it says **Needs a signed build**. **Use Watchtower on iPhone** shows a QR code valid for 10 minutes. See [iPhone](../features/iphone.md).
- Each linked phone shows **Same Apple ID** or **Shared** and one line per permission, each with **Allow…** or **Revoke**: typing into your sessions, starting sessions (allowed only once typing is: **Starting sessions needs typing**) and answering permission prompts. **Remove…** unlinks it.

## Profile

- Your role, team, manager, reports, peers and starred channels and people. **Run Setup Again** repeats [setup](../start/setup.md).
- **Skills** — turn skills on or off, edit them, or add **New Skill**. Built-in skills can be disabled but not deleted.
- **Assistant tools** — per write tool, **Run without approval in:** checkboxes for **Chat**, **Target chat**, **Slack reactions** and **Automations**. Tools that write outside this Mac (tagged *external*) always need approval, on every surface. See [AI chat](../features/ai-chat.md).
