# Briefings

A briefing is one morning read written for you: what needs your attention, what your day holds, what happened in your channels and how your people are doing. It rolls up the work the other pipelines have already done, so it is quick and cheap to produce.

## Why use it

You sit down at 09:00 with coffee. Instead of opening Slack, mail and Jira in turn, you open today's briefing and see the two threads waiting on you, the tasks due today, yesterday's decision in a channel you don't follow, and a note that a colleague's activity dropped. Each line links to the digest, track, target or person it came from.

## How it works

One briefing is made per calendar day, by the background sync. It is generated at or after the briefing hour (default **08:00**), not at that exact minute: if the Mac was asleep at 08:00, it comes on the first sync cycle after you wake it. Sync cycles run every 15 minutes by default.

| Condition | Why |
|---|---|
| **Daily Briefing** is on in Settings → Features | The switch for the whole feature |
| An account that tells Watchtower who you are | Slack account #1, else your first Google account, else the first Jira site with a known owner, else the first Linear workspace |
| Something to summarise | Channel digests or the daily rollup, tracks, your targets, attention items, Workbench activity or automation notes |
| Fewer than three failed attempts today | After three failures it gives up until tomorrow |

The very first briefing on a new install skips the hour and comes in the first cycle that has something to summarise. If there is nothing yet, nothing is stored and the next cycle tries again.

A briefing has up to five sections, plus today's calendar:

- **Needs Attention**: unanswered mentions, DMs and mail to you, updated tracks, overdue or blocked targets, new red flags. Workbench activity (a blocked target, open asks, unread agent comments) can appear here, labelled *Workbench*.
- **Your Day**: your targets and tracks for today.
- **What Happened**: notable events from recent channel digests. Notes your automations left for the briefing are folded in here, labelled with a gear and the automation's name.
- **Team Pulse**: people signals such as activity spikes or drops and new red flags.
- **Coaching Corner**: communication and process tips.

Rules you teach through [Catch Up](catch-up.md) feedback are applied to the briefing too.

## Using it

- Click a briefing in the list to read it. Opening it marks it read; unread ones have a blue dot.
- Click an item to jump to its track, digest, target or person. Items that suggest new work show **Create target**.
- Click **Day Plan** in the header to open that day's plan, when one exists.
- Change the time in Settings → Features → **Briefing Hour**. The section shows only while the feature is on.

## When it's empty or wrong

The empty tab says "No briefings yet" and "Generated once a day at or after 08:00" (your hour), then a status line.

- **Connect Slack, Google, Jira, Linear or an email account so Watchtower knows who you are.** There is no owner yet. Click **Open Connections** and connect one. A freshly connected Jira site can show this for a moment while your identity is read.
- **Off — Turn on.** Click **Turn on**.
- **Connect a source to get this.** Connect any one source.
- **Preparing now.** The briefing is being written; wait a minute.
- **Starts after the first sync / Within ~15 min / After this sync / Today at 08:00 / Tomorrow at 08:00.** It is on its way; the line says when.
- **Didn't work yet — retries automatically.** The last attempt failed, with the reason in the line. After three failures it waits until tomorrow.
- **No briefing today though the hour passed.** The sync may not have run (the Mac was off or the daemon isn't running), or there was nothing to summarise. See [Day Plan](day-plan.md) for the same gate.
- **Generate manually.** With no briefings yet, **Generate Briefing** in the empty tab builds one now; a failure shows its reason in red under the button. Once a briefing exists, run `watchtower briefing generate` in a terminal. Today's briefing is never rebuilt, so the command returns the existing one.

No briefing today? See [No briefing or day plan today](../troubleshooting/no-briefing-or-day-plan.md).

## Related

[Day Plan](day-plan.md), [Catch Up](catch-up.md), [Home](home.md).

For developers: [docs/features/strong-tier-cost-fixes.md](../../features/strong-tier-cost-fixes.md)
