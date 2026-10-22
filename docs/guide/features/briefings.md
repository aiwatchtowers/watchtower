# Briefings

A briefing is one morning read written for you: what needs your attention, what your day holds, what happened in your channels and how your people are doing. It is the lower half of the **Your day** card in the [Inbox](inbox.md), under today's plan. It rolls up the work the other pipelines have already done, so it is quick and cheap to produce.

## Why use it

You sit down at 09:00 with coffee. Instead of opening Slack, mail and Jira in turn, you open the Inbox and read today's **Your day** card: the two threads waiting on you, the tasks due today, yesterday's decision in a channel you don't follow, and a note that a colleague's activity dropped. Each line links to the digest, track, target or person it came from.

## How it works

One briefing is made per calendar day by **Morning brief**, a [built-in automation](automations-built-in.md) the background sync runs; the day plan is made right after it in the same run. It is generated at or after the briefing hour (default **08:00**), not at that exact minute: if the Mac was asleep at 08:00, it comes on the first sync cycle after you wake it. Sync cycles run every 15 minutes by default.

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

### Read and Done are separate

Opening a day card marks its briefing read, the same mark **I'm caught up** in [Catch Up](catch-up.md) sets. **Done** only lets today's card leave the top of the list: it then sorts by its time like any other card. The sidebar badge counts one while the latest briefing is unread.

## Using it

- In the Inbox, today's card is first under **Today** on **All**. The **Day** filter lists one card per date, the last 30 dates, and **Show older** adds 30 more. A briefing notification and Home's **Briefing** link open today's card.
- Click an item to jump to its track, digest, target or person. Items that suggest new work show **Make a Task**, which creates the target and opens it.
- The card's header has **Discuss in Chat** and **Done**.
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
