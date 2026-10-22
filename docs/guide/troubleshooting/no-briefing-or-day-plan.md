# No briefing or day plan today

The Inbox has no **Your day** card for today, or today's card has a brief but no plan, though yesterday's was there. Both halves are written once a day by the background sync, not when you open the Inbox.

## What you see

The **Day** filter says "No briefings yet" with a status line, or its newest card is yesterday's. Today's card may say "No plan for this day yet." under **Plan**.

## Why

A daily job runs at or after its hour (08:00 unless you changed it) and only when all of these hold:

- The feature is on (**Settings → Features**: **Daily Briefing**, **Day Plan**).
- Watchtower knows who you are: a connected Slack, Google, Jira, Linear or email account. Without one the Inbox says "Connect Slack, Google, Jira, Linear or an email account so Watchtower knows who you are".
- The sync ran after the hour. A Mac that slept or was off at 08:00 produces it on the first cycle after waking.
- It has not failed three times today. After three failures it waits until tomorrow.

On a new install the first briefing and the first day plan do not wait for the hour.

## Fix

1. Read the status line on the empty **Day** filter ("Today at 08:00", "Tomorrow at 08:00", "Didn't work yet — retries automatically", **Off — Turn on**). The meanings are in [Turning features on and off](../concepts/features-on-and-off.md).
2. **Open Connections** appears when there is no owner: connect any one source.
3. **Turn on** when the feature is off.
4. **No brief:** run `watchtower briefing generate` in a terminal. Today's briefing is never rebuilt, so once one exists the command returns it.
5. **A brief but no plan:** press **Make today's plan** on today's card. With no card for today at all, run `watchtower day-plan generate`.
6. **A plan you dislike:** **Regenerate with feedback…** on today's card rewrites it, and **Reset plan…** deletes it so **Make today's plan** comes back.
7. A reason that names the Claude or Codex tool: [The Claude or Codex tool is not found or not signed in](ai-tool-not-found-or-not-signed-in.md).
8. Wanted midnight? **Known issue:** the Briefing Hour list offers 00:00, but the briefing is made at 08:00. Pick 01:00 or later; see [Known issues](known-issues.md).

## How to check

Today's **Your day** card is first under **Today** in the Inbox. The empty-state line, when you see one again, reads "Tomorrow at 08:00" (your hour).

## If it did not help

Run `watchtower logs` and look for the briefing or day plan step. See [Sync is stuck or slow](sync-stuck-or-slow.md) if no cycle ran. The pages are [Briefings](../features/briefings.md) and [Day Plan](../features/day-plan.md).
