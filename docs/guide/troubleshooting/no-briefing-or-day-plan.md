# No briefing or day plan today

**Briefings** or **Day Plan** has nothing for today, though yesterday's was there. Both are written once a day by the background sync, not when you open the tab.

## What you see

"No briefings yet" or "No day plan yet" with a status line, or the list simply lacks today's entry.

## Why

A daily job runs at or after its hour (08:00 unless you changed it) and only when all of these hold:

- The feature is on (**Settings → Features**: **Daily Briefing**, **Day Plan**).
- Watchtower knows who you are: a connected Slack, Google, Jira or Linear account. Without one the tab says "Connect Slack, Google, Jira or Linear so Watchtower knows who you are".
- The sync ran after the hour. A Mac that slept or was off at 08:00 produces it on the first cycle after waking.
- It has not failed three times today. After three failures it waits until tomorrow.

On a new install the first briefing and the first day plan do not wait for the hour.

## Fix

1. Read the status line ("Today at 08:00", "Tomorrow at 08:00", "Didn't work yet — retries automatically", **Off — Turn on**). The meanings are in [Turning features on and off](../concepts/features-on-and-off.md).
2. **Open Connections** appears when there is no owner: connect any one source.
3. **Turn on** when the feature is off.
4. **Briefings, none yet:** press **Generate Briefing** in the empty tab; a failure shows its reason in red below the button.
5. **Briefings, one exists:** you cannot rebuild today's briefing in the app; `watchtower briefing generate` returns the existing one.
6. **Day Plan:** press **Generate today's plan**. With a plan you dislike, **Regenerate with feedback…** rewrites it, and **Reset plan** deletes it so the footer offers **Generate today's plan** again.
7. A reason that names the Claude or Codex tool: [The Claude or Codex tool is not found or not signed in](ai-tool-not-found-or-not-signed-in.md).
8. Wanted midnight? **Known issue:** the Briefing Hour list offers 00:00, but the briefing is made at 08:00. Pick 01:00 or later; see [Known issues](known-issues.md).

## How to check

Today's entry appears in the tab. The status line then reads "Tomorrow at 08:00" (your hour).

## If it did not help

Run `watchtower logs` and look for the briefing or day plan step. See [Sync is stuck or slow](sync-stuck-or-slow.md) if no cycle ran. The pages are [Briefings](../features/briefings.md) and [Day Plan](../features/day-plan.md).
