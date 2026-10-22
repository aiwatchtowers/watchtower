# Known issues

Places where Watchtower does something other than what its own screen says. Each has a workaround. Nothing here is a setting you got wrong.

## Removing an account deletes its mail or events

**Known issue.** The confirmation for removing an Email or Calendar (CalDAV, ICS) account says already-synced messages or events are kept. The mail and events synced from that account are deleted from your Mac. Digests, briefings and other results built from them stay. (Google's confirmation says its mail and events are deleted; Slack and Jira removal really keeps its data.)

Workaround: before removing, read or export what you need. Slack and Jira rows have an **Enabled** switch that stops syncing an account without removing it (turning it back on does not resume a month of history that was still loading); Email and Calendar rows have none, so leave the account connected if you want to keep its data. After you add the account again, recent mail and events sync back and older mail returns through [history backfill](../concepts/history-backfill.md). See [Sources and accounts](../concepts/sources-and-accounts.md).

## Morning brief at 00:00 runs at 08:00

**Known issue.** **Time** on the **Morning brief** card (Automations → **Built in**) lists 00:00, but the briefing and the day plan are then made at 08:00, as if the time was not set.

Workaround: pick 01:00 or later. See [No briefing or day plan today](no-briefing-or-day-plan.md).

## An idea parked with "Not now" does not return on its date

**Known issue.** **Not now** offers **1 week**, **1 month** and **No date**, but nothing reads the date. The idea comes back to **For review** only when a new mention of it appears.

Workaround: filter the registry by **Not now** and press **Activate** when you want it back. See [Ideas & Decisions](../features/ideas-and-decisions.md).

## No Weekly digest ever appears

**Known issue.** The app has a "Weekly" digest type, and `watchtower trends` reads it, but no process generates one today. Only channel digests and the daily rollup are made.

Workaround: use the **Daily** digest and [Tracks](../features/tracks.md). See [Digests](../features/digests.md).

## Day plan counts change nothing

**Known issue.** **Time blocks at most**, **Backlog items at least** and **Backlog items at most** on the **Morning brief** card (Automations → **Built in**) are saved but the plan ignores them. **Time** and the working hours do work.

Workaround: press **Regenerate with feedback…** and say how many blocks or backlog items you want. See [Day Plan](../features/day-plan.md).

## People Connections shows no interaction scores

**Known issue.** On **My Card**, the **Connections** tab has no interaction scores, because nothing computes them yet. **Edit Connections** still sets who your manager, reports and peers are.

Workaround: none for the scores; the people cards and the briefing use the connections you set. See [People](../features/people.md).

## Related

- [Troubleshooting index](README.md)
