# Day Plan

The Day Plan turns your calendar, targets and briefing into a schedule for today: time blocks plus a short backlog for whatever fits if time allows. It is the top half of the **Your day** card in the [Inbox](inbox.md), above the briefing. It is for people whose day is more than a list of meetings.

## Why use it

Your calendar says you have three meetings and nothing else. The Day Plan fits two focused blocks between them for the targets that are due, adds a backlog of smaller items, and warns you when two events overlap. You tick items off as the day goes.

## How it works

The plan is made by the background sync, once a day, right after the briefing step. Like the briefing it runs at or after the plan hour (default **08:00**), on the first sync cycle that finds it due.

It reads your calendar, targets, today's briefing, your open Jira issues (and Linear issues when Linear is switched on), people context and, when Memory's Day Plan surface is on, open loops. It also reads yesterday's plan and the items you added by hand.

| Condition | Why |
|---|---|
| **Day Plan** is on in Settings → Features | The switch for the feature |
| An account that tells Watchtower who you are | Slack, Google, Jira, Linear or an email account; see [Briefings](briefings.md) |
| No plan for today yet | One plan per day |
| Fewer than three failed attempts today | After three failures it gives up until tomorrow |

The first plan on a new install skips the hour and comes in the first cycle that can make it.

Every sync cycle after that, calendar events are synced into today's plan and conflicts are re-detected. A red **Calendar conflicts detected** banner appears when events overlap.

## Using it

### Find the plan

In the Inbox, today's **Your day** card is first under **Today** until you press **Done**, which only lets it sort by time. The **Day** filter lists one card per date, the last 30 dates; Home's **Day plan** link opens today's card. The plan lists all-day events, then time blocks in time order ("09:00–09:30"), then the backlog, with "3/5" done in the **Plan** header.

### Work the plan

- Click an item's circle to mark it done, or use its **⋯**: **Mark Done** or **Mark Pending**, **Open source** (the target, event or issue behind it) and **Delete**. The source badge opens the source too.
- A red **Calendar conflicts detected** banner appears when events overlap: **Regenerate** opens the feedback row below, **Check again** re-runs detection.

### Change today's plan

These show on today's card only; an older day's plan is read-only. Each opens an inline row under the plan.

- **+** (**Add to the plan**): a title, **Time block** or **Backlog**, and for a time block its **Start** and **End**, then **Add**.
- **Regenerate with feedback…**: say what should change and press **Regenerate**. Items you added by hand are kept.
- **Reset plan…**: **Reset** deletes today's plan with the items you added. Your targets are not touched.
- With a brief but no plan yet, the card says "No plan for this day yet." and offers **Make today's plan**. A failure shows the reason in red.

### Tune it

Settings → Features → **Day Plan** sets **Generate at hour** (05:00 to 12:00), **Working hours** (default 09:00 to 19:00), and three steppers, **Max timeblocks**, **Backlog min** and **Backlog max**, that are saved but do not change the plan today (see [Known issues](../troubleshooting/known-issues.md)).

## When it's empty or wrong

With no day card yet, the empty **Day** filter shows the briefing's status line; the plan follows the same gate.

- **Connect Slack, Google, Jira, Linear or an email account so Watchtower knows who you are.** There is no owner. Click **Open Connections**. Without one, the card has no Make, Regenerate or Reset, but an existing plan stays readable.
- **Off — Turn on.** Turn **Day Plan** on in Settings → Features.
- **Preparing now / Within ~15 min / Today at 08:00.** It is on its way.
- **Didn't work yet — retries automatically.** The last attempt failed. After three failures it waits until tomorrow.
- **Plan missing though the hour passed.** The daemon may not have run (Mac off or asleep), or no connected account identifies you. Press **Make today's plan** on today's card, or run `watchtower day-plan generate` when there is no card for today.

No plan today? See [No briefing or day plan today](../troubleshooting/no-briefing-or-day-plan.md).

## Related

[Inbox](inbox.md), [Briefings](briefings.md), [Home](home.md).

For developers: [docs/features/strong-tier-cost-fixes.md](../../features/strong-tier-cost-fixes.md)
