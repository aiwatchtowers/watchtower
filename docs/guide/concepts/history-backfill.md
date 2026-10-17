# History backfill

When you connect a source, Watchtower first reads only a few days so the app is useful in minutes, then loads the rest of the last 30 days in the background. This page explains what arrives later, in what order, and what never does.

## Why the first day looks thin

The first sync is short on purpose: 3 days of Slack (setup's depth), 7 days of Gmail and IMAP mail. The first briefing, inbox and digests therefore describe today.

A last step of every sync cycle then walks each new source back toward 30 days (`sync.backfill_days`), newest first, one 2-day chunk per source per cycle. At the default 15-minute cycle a month takes a few hours, longer for a big workspace.

The step has a 5-minute budget per cycle. A chunk that does not finish is resumed next cycle. While you are offline, or a source's server or the AI connection is down or rate-limiting, the chunk waits and is tried again next cycle; the status bar shows "Loading history waits" and `watchtower backfill status` shows the row as `waiting: held` with the reason. A wait lasts at most 7 days; after that the chunk counts as failed. A chunk that fails three times (for example, an AI reply that cannot be read) is skipped. A source that has to wait does not hold up the others. Memory waits while history is still loading, so it starts later when a backfill waits.

## What each source loads

| Source | What is loaded for the older days |
|---|---|
| **Slack** | Messages, then channel digests and daily rollups for those days |
| **Gmail, IMAP** | Messages; Gmail also gets its mail digests, which feed Ideas |
| **Jira** | Nothing to fetch, because the first Jira sync is a full scan; the month is mined for Ideas |
| **Calendar** | Not needed: 30 days of events are re-synced every cycle |
| **Confluence, meetings** | Not needed |

Muted channels and one-to-one messages are not digested during backfill.

## What it does not do

- Briefings, day plans, next steps and Catch Up describe today and are never backfilled.
- Backfilled mail never reaches Attention detection, so old mail does not turn into inbox items.
- Memory waits. While any backfill is loading or paused, Memory extracts nothing, then starts from the oldest message.
- When all Slack days are in, a one-time step also looks for old mentions (with Attention detection on) and builds People cards over the window (with People Cards and Slack Digests on). Old mentions land in the inbox pipeline and its normal rules close the old ones.
- A source connected before this feature existed, or one whose first sync was started from the command line, gets no backfill. A source that is removed or turned off ends its backfill for good, and turning it back on does not resume it.

## Following it, pausing it

The menu bar and the status bar show "Loading history: N of M days". Two other lines mean it is waiting:

- "Loading history paused — Claude plan limit": a Claude 5-hour or weekly limit is projected to be hit, so backfill waits. This gate only works with the Claude provider; see [AI providers, models and cost](ai-providers-and-cost.md).
- "Loading history paused — reconnect the account": the account's sign-in was revoked. Reconnect it, or remove the account to release Memory.

`watchtower backfill status` prints the same per source.

To stop loading, run `watchtower config set sync.backfill_days 0`. Running ones pause and setting it back resumes them. 0 also means a source connected later starts none.

## Why numbers can look off

"N of M days" adds days across sources, so it is not one source's month. Digests of the older days appear in the Digests tab sorted by when they were created, so they can sit at the top for hours.

## Related

- [Sources and accounts](sources-and-accounts.md)
- [How Watchtower works](how-watchtower-works.md)

For developers: [docs/features/history-backfill.md](../../features/history-backfill.md)
