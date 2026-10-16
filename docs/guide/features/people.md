# People

People shows a card for each colleague: how they communicate, what role they play in decisions, what they got done, and how best to work with them. The card for you has two tabs and shows how Watchtower reads your own work. A **Team Summary** sits above the list.

## Why use it

Before a 1:1, a hard thread or a first message to someone new, a card gives you their style and your history together in a glance. The briefing and day plan read the same cards.

## How it works

**Cards are built from digests, once a day.** The daemon generates cards at most every 24 hours. Each run covers the last 7 days of Slack, ending at the start of today. The first run on a fresh install ends now, so cards do not wait for midnight.

**A person needs enough activity.** Anyone with at least 3 messages in the window gets a card. With 3 or more digest observations about them, or 10 or more messages, it is a full card. Otherwise it is a lighter one, and the screen says "Not enough data for full analysis." The run as a whole is skipped only when the digests hold no observations at all.

**The Team Summary comes with the run.** After the cards, one more AI call writes the team-level summary: **Needs Attention** and **Tips**.

**It depends on Digests.** People Cards read what [Digests](digests.md) record, so both **People Cards** and **Slack Digests** must be on. A run with no data (no digests yet, or nobody active) writes no run record and does not use up the day, so cards appear in the first cycle that has material. After 3 failed AI attempts in a day it waits until tomorrow.

**Bots and deleted accounts get no card.** Only accounts Slack itself flags as bots are excluded. A user you mute or hand-mark as a bot in [Statistics](statistics.md) still gets a card, although a muted user's messages are not read when digests are written.

## Using it

1. Open **People**. **My Card** is pinned first, then everyone else. Select **Team Summary** for the team view.
2. A card shows the summary, **Communication Guide**, **Decision Style**, **Tactics**, **Red Flags**, **Highlights**, **Accomplishments**, an activity-hours chart and a week-by-week history. When Jira is connected and the person has work there, a **Delivery** box adds closed issues, cycle time, velocity and open issues, plus **Expertise** tags.
3. On **My Card**, the **Connections** tab draws your manager, reports and peers around you with interaction scores. **Edit Connections** changes who they are; the briefing and other cards use that.
4. The box **How the system understands you** appears on your card when you wrote custom profile context.

## When it's empty or wrong

- **"No people cards yet"**: cards need digests first, then up to a day for the first run. On a new install expect them after the first cycle that produced digests.
- **A colleague has no card.** They had fewer than 3 messages in the last 7 days in non-DM channels, or they are a bot or a deleted account.
- **A card says "Not enough data."** It was built from thin signals and improves as messages accumulate.
- **The card is a day old.** Cards refresh at most daily.
- **Your reports or manager look wrong.** Fix them under **Edit Connections** on **My Card**.

## Related

[Digests](digests.md), [Statistics](statistics.md).
