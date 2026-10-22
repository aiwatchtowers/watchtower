# Day Plan

The Day Plan turns your calendar, targets and briefing into a schedule for today: time blocks plus a short backlog for whatever fits if time allows. It is the top half of the **Your day** card in the [Inbox](inbox.md), above the briefing. It is for people whose day is more than a list of meetings.

## Why use it

Your calendar says you have three meetings and nothing else. The Day Plan fits two focused blocks between them for the targets that are due, adds a backlog of smaller items, and warns you when two events overlap. You tick items off as the day goes.

## How it works

The plan is made once a day by **Morning brief**, a [built-in automation](automations-built-in.md) the background sync runs: right after the briefing, in the same run. It has no hour of its own: it comes at or after the briefing's **Time** (default **08:00**), on the first sync cycle that finds it due.

It reads your calendar, targets, today's briefing, your open Jira issues (and Linear issues when Linear is switched on), people context and, when Memory's Day Plan surface is on, open loops. It also reads yesterday's plan and the items you added by hand.

| Condition | Why |
|---|---|
| **Morning brief** is on in Automations → **Built in** | Its **Turn On** / **Turn Off** is the switch for the plan and the briefing |
| An account that tells Watchtower who you are | Slack, Google, Jira, Linear or an email account; see [Briefings](briefings.md) |
| No plan for today yet | One plan per day |
| Fewer than three failed attempts today | After three failures it gives up until tomorrow |

The first plan on a new install skips the hour and comes in the first cycle that can make it.

Every sync cycle after that, calendar events are synced into today's plan and conflicts are re-detected. A red **Calendar conflicts detected** banner appears when events overlap, and the day's row in the Inbox list gets a red dot.

## Using it

### Find the plan

In the Inbox, today's **Your day** card is first under **Today** until you press **Done**, which only lets it sort by time. The **Day** filter lists one card per date, the last 30 dates, and **Show older** at the end adds 30 more; Home's **Day plan** link opens today's card. The plan lists all-day events, then time blocks in time order ("09:00–09:30"), then the backlog, with "3/5" done in the **Plan** header.

### Work the plan

- Click an item's circle to mark it done, or use its **⋯**: **Mark Done** or **Mark Pending**, **Open source** (the target, event or issue behind it) and **Delete**. The source badge opens the source too.
- A red **Calendar conflicts detected** banner appears when events overlap: **Regenerate** opens the feedback row below, **Check again** re-runs detection.

### Change today's plan

These show on today's card only; an older day's plan is read-only. Each opens an inline row under the plan.

- **+** (**Add to the plan**): a title, **Time block** or **Backlog**, and for a time block its **Start** and **End**, then **Add**.
- **Regenerate with feedback…**: say what should change and press **Regenerate**. Items you added by hand are kept.
- **Reset plan…**: **Reset** deletes today's plan with the items you added. Your targets are not touched.
- With a brief but no plan yet, the card says "No plan for this day yet." and offers **Make today's plan**. A failure shows the reason in red.
- With neither yet, today's card says "Nothing is ready for today yet.", when each comes ("Today's plan at or after 08:00" once the plan has run before), and offers **Make today's brief and plan**: it writes the brief, then the plan, with progress and any refusal on the card. With Daily Briefing off it offers **Make today's plan** only; with both features off there is no card for today.

### Tune it

The **Morning brief** card in Automations → **Built in** holds the plan's settings under **When**: **Time** (shared with the briefing), **Working hours from** and **to** (default 09:00 to 19:00), and three counts, **Time blocks at most**, **Backlog items at least** and **Backlog items at most**, that are saved but do not change the plan today (see [Known issues](../troubleshooting/known-issues.md)). **Edit in Chat** there changes how the plan is written.

## When it's empty or wrong

Before today's brief and plan exist, today's card shows each one's status line.

- **Connect Slack, Google, Jira, Linear or an email account so Watchtower knows who you are.** There is no owner. Click **Open Connections**. Without one, the card has no Make, Regenerate or Reset, but an existing plan stays readable.
- **Off — Turn on.** Click **Turn on**, or **Turn On** on the **Morning brief** card.
- **Preparing now / Within ~15 min / Today at 08:00.** It is on its way.
- **Didn't work yet — retries automatically.** The last attempt failed. After three failures it waits until tomorrow.
- **Plan missing though the hour passed.** The daemon may not have run (Mac off or asleep), or no connected account identifies you. Press **Make today's plan** on today's card, or **Make today's brief and plan** when it has neither.

No plan today? See [No briefing or day plan today](../troubleshooting/no-briefing-or-day-plan.md).

## Related

[Inbox](inbox.md), [Briefings](briefings.md), [Built-in automations](automations-built-in.md), [Home](home.md).

For developers: [docs/features/built-in-automations.md](../../features/built-in-automations.md), [docs/features/strong-tier-cost-fixes.md](../../features/strong-tier-cost-fixes.md)
