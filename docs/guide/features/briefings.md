# Briefings

A briefing is one morning read written for you: what needs your attention, what your day holds, what happened in your channels and how your people are doing. You read it as today's **Morning brief** in the [Inbox](inbox.md), together with today's plan. It rolls up the work the other pipelines have already done, so it is quick and cheap to produce.

## Why use it

You sit down at 09:00 with coffee. Instead of opening Slack, mail and Jira in turn, you open the Inbox and read today's **Morning brief**: the two threads waiting on you, the tasks due today, yesterday's decision in a channel you don't follow, and a note that a colleague's activity dropped. Each line links to the digest, track, target or person it came from.

## How it works

One briefing is made per calendar day by **Morning brief**, a [built-in automation](automations-built-in.md) the background sync runs; the day plan is made right after it in the same run. It is generated at or after the Morning brief's **Time** (default **08:00**), not at that exact minute: if the Mac was asleep at 08:00, it comes on the first sync cycle after you wake it. Sync cycles run every 15 minutes by default.

| Condition | Why |
|---|---|
| **Morning brief** is on in Automations → **Built in** | Its **Turn On** / **Turn Off** is the switch for the briefing and the day plan |
| An account that tells Watchtower who you are | Slack account #1, else your first Google account, else the first Jira site with a known owner, else the first Linear workspace, else the address of your first email (IMAP or Outlook) account |
| Something to summarise | Channel digests or the daily rollup, tracks, your targets, attention items, Workbench activity or automation notes |
| Fewer than three failed attempts today | After three failures it gives up until tomorrow |

The very first briefing on a new install skips the hour and comes in the first cycle that has something to summarise. If there is nothing yet, nothing is stored and the next cycle tries again.

A briefing has up to five sections, plus today's calendar:

- **Needs you**: unanswered mentions, DMs and mail to you, updated tracks, overdue or blocked targets, new red flags. Workbench activity (a blocked target, open asks, unread agent comments on targets still open) can appear here, labelled *Workbench*.
- **Your day**: your targets and tracks for today.
- **What happened**: notable events from recent channel digests. Notes your automations left for the briefing are folded in here, labelled with a gear and the automation's name.
- **Team pulse**: people signals such as activity spikes or drops and new red flags.
- **Coaching**: communication and process tips.

Your Jira and Linear issues feed these sections when that tracker is switched on: issues assigned to you, open issues you reported, blocked, stale (in progress for more than 7 days) and overdue ones, and sprint or cycle progress. The **Jira Features** switches decide which of these the briefing reads, for both trackers.

Rules you teach through [Catch Up](catch-up.md) feedback are applied to the briefing too.

### How the Inbox shows it

The **Morning brief** pane reads top down: the lead line and **Start here** (the first three items that need you), **Your day** with today's plan, **Waiting on you** (the three newest messages from people), **Moved overnight** (up to three tracks with news), then the rest of **Needs you** under **More for today**, **What happened**, **Team pulse** and **Coaching**. **Waiting on you** and **Moved overnight** show on today's brief only.

### When a day's brief is read

Opening a day's brief marks its briefing read, the same mark **I'm caught up** in [Catch Up](catch-up.md) sets. The Inbox lists only today's **Morning brief**; earlier days live inside it, under **‹ ›** and **History** in its header ([read an earlier brief](inbox.md#read-an-earlier-brief)). Nothing marks a past brief read for you, and the sidebar badge never counts a brief.

## Using it

<!-- learn
id: briefings-morning-brief
title: Read your morning brief
text: Open **Morning brief** in the Inbox at the start of the day: today's brief and plan, with earlier days inside.
area: planning
level: basics
kind: feature
since: next
action: nav:briefings
replaces: [briefings-read]
changed: One Morning brief row holds today's brief; past days moved inside it.
-->

<!-- learn
id: briefings-make-task
title: Make a task from the brief
text: Press **Make a Task** on a brief item that suggests new work; the target is created and opens.
area: planning
level: next
kind: tip
since: 0.24.0
action: nav:briefings
-->

<!-- learn
id: briefings-time
title: Change when the brief arrives
text: Set **Time** under **When** on the **Morning brief** card in Automations → **Built in**.
area: planning
level: next
kind: tip
since: 0.24.0
action: nav:automations
-->

- In the Inbox, the root lists one **Morning brief**, today's. Press **‹** or **History** in its header for an earlier day; a briefing notification and Home's **Briefing** link open their day too.
- Click an item to jump to its track, digest, target or person. Items that suggest new work show **Make a Task**, which creates the target and opens it.
- The pane's header has **Discuss in Chat**.
- Change the time with **Time** under **When** on the **Morning brief** card (Automations → **Built in**). To change what the briefing says, use **Edit in Chat** there; see [Built-in automations](automations-built-in.md).

## When it's empty or wrong

Before today's brief exists, today's card says "No briefings yet" and "Generated once a day at or after 08:00" (your hour), then a status line; once briefings have run before it says "Today's brief at or after 08:00".

- **Connect Slack, Google, Jira, Linear or an email account so Watchtower knows who you are.** There is no owner yet. Click **Open Connections** and connect one. A freshly connected Jira site or Linear workspace can show this for a moment while your identity is read; Home then says "Waiting for your Jira identity…" (or Linear).
- **Off — Turn on.** Click **Turn on**.
- **Connect a source to get this.** Connect any one source.
- **Preparing now.** The briefing is being written; wait a minute.
- **Starts after the first sync / Within ~15 min / After this sync / Today at 08:00 / Tomorrow at 08:00.** It is on its way; the line says when.
- **Didn't work yet — retries automatically.** The last attempt failed, with the reason in the line. After three failures it waits until tomorrow.
- **No briefing today though the hour passed.** The sync may not have run (the Mac was off or the daemon isn't running), or there was nothing to summarise. See [Day Plan](day-plan.md) for the same gate.
- **Make it now.** Press **Make today's brief and plan** on today's card, or **Make today's brief** when the card has only a plan or Day Plan is off. A refusal shows in red on the card.

No briefing today? See [No briefing or day plan today](../troubleshooting/no-briefing-or-day-plan.md).

## Related

[Inbox](inbox.md), [Day Plan](day-plan.md), [Built-in automations](automations-built-in.md), [Catch Up](catch-up.md), [Home](home.md).

For developers: [docs/features/built-in-automations.md](../../features/built-in-automations.md), [docs/features/strong-tier-cost-fixes.md](../../features/strong-tier-cost-fixes.md)
