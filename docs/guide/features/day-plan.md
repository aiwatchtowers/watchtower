# Day Plan

The Day Plan turns your calendar, targets and briefing into a schedule for today: a timeline of time blocks plus a short backlog for whatever fits if time allows. It is for people whose day is more than a list of meetings.

## Why use it

Your calendar says you have three meetings and nothing else. The Day Plan fits two focused blocks between them for the targets that are due, adds a backlog of smaller items, and warns you when two events overlap. You tick items off as the day goes.

## How it works

The plan is made by the background sync, once a day, right after the briefing step. Like the briefing it runs at or after the plan hour (default **08:00**), on the first sync cycle that finds it due.

It reads your calendar, targets, today's briefing, Jira issues, people context and, when Memory's Day Plan surface is on, open loops. It also reads yesterday's plan and the items you added by hand.

| Condition | Why |
|---|---|
| **Day Plan** is on in Settings → Features | The switch for the feature |
| An account that tells Watchtower who you are | Slack, Google, Jira or Linear; see [Briefings](briefings.md) |
| No plan for today yet | One plan per day |
| Fewer than three failed attempts today | After three failures it gives up until tomorrow |

The first plan on a new install skips the hour and comes in the first cycle that can make it.

Every sync cycle after that, calendar events are synced into today's plan and conflicts are re-detected. A red **Calendar conflicts detected** banner appears when events overlap.

## Using it

### Generate the plan

If there is no plan yet, click **Generate today's plan** in the footer. A failure shows a red banner with the reason; **Dismiss** hides it.

### Rebuild with feedback

Click **Regenerate with feedback…**, say what to change under "Tell me what to change:" and click **Regenerate**. Items you added by hand are kept.

### Start over

**Reset plan** deletes today's plan. Your targets are not touched, and the footer offers **Generate today's plan** again.

### Work the plan

- Click **Add** in the Backlog to create your own item (a time block or a backlog entry).
- On an item: **Mark Done** or **Mark Pending**, **Open source** (the target, event or issue behind it) and **Delete**.
- The header shows the date and how many items are done. **Briefing** opens that day's briefing.
- On the conflict banner, **Regenerate** opens the same feedback sheet as above and **Check again** re-runs detection.

### Tune it

Settings → Features → **Day Plan** sets **Generate at hour** (05:00 to 12:00), **Working hours** (default 09:00 to 19:00), **Max timeblocks** (1 to 5, default 3) and the **Backlog min** and **Backlog max** (defaults 3 and 8).

## When it's empty or wrong

The empty tab says "No day plan yet" with a status line, or "Today's plan at or after 08:00" once you've had plans before.

- **Connect Slack, Google, Jira or Linear so Watchtower knows who you are.** There is no owner. Click **Open Connections**. Without one, the footer has no Generate, Regenerate or Reset, but an existing plan stays readable.
- **Off — Turn on.** Click **Turn on**.
- **Starts after the first sync, Within ~15 min, Today at 08:00.** It is on its way; the line says when.
- **Didn't work yet — retries automatically.** The last attempt failed; the line shows why. After three failures it waits until tomorrow.
- **Plan missing though the hour passed.** The daemon may not have run (Mac off or asleep), or no connected account identifies you. Click **Generate today's plan**.

## Related

[Briefings](briefings.md), [Home](home.md).

For developers: [docs/features/strong-tier-cost-fixes.md](../../features/strong-tier-cost-fixes.md)
