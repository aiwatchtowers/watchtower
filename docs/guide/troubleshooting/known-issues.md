# Known issues

Places where Watchtower does something other than what its own screen says. Each has a workaround. Nothing here is a setting you got wrong.

## Removing an account deletes its mail or events

**Known issue.** The confirmation for removing a Google, Email or Calendar (CalDAV, ICS) account says already-synced messages or events are kept. The mail and events synced from that account are deleted from your Mac (a Google account keeps events tied to a recording or recap). Digests, briefings and other results built from them stay. Slack and Jira removal really keeps its data.

Workaround: before removing, read or export what you need. Slack and Jira rows have an **Enabled** switch that pauses an account without removing it; Google, Email and Calendar rows have none, so leave the account connected if you want to keep its data. After you add the account again, recent mail and events sync back and older mail returns through [history backfill](../concepts/history-backfill.md). See [Sources and accounts](../concepts/sources-and-accounts.md).

## Briefing Hour 00:00 runs at 08:00

**Known issue.** **Briefing Hour** in **Settings → Features** lists 00:00, but the briefing is then made at 08:00, as if the hour was not set. **Generate at hour** for the Day Plan starts at 05:00 and is not affected.

Workaround: pick 01:00 or later. See [No briefing or day plan today](no-briefing-or-day-plan.md).

## An idea parked with "Not now" does not return on its date

**Known issue.** **Not now** offers **1 week**, **1 month** and **No date**, but nothing reads the date. The idea comes back to **For review** only when a new mention of it appears.

Workaround: filter the registry by **Not now** and press **Activate** when you want it back. See [Ideas & Decisions](../features/ideas-and-decisions.md).

## No Weekly digest ever appears

**Known issue.** The app has a "Weekly" digest type, and `watchtower trends` reads it, but no process generates one today. Only channel digests and the daily rollup are made.

Workaround: use the **Daily** digest and [Tracks](../features/tracks.md). See [Digests](../features/digests.md).

## Related

- [Troubleshooting index](README.md)
