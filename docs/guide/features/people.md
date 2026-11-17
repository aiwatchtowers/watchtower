# People

People shows a card for each colleague you work with: what they work on, what role they play in decisions, and how best to work with them. A card never scores, monitors or judges anyone: it holds no activity hours, message volume, red flags or comparison with the team. The card for you has two tabs and shows how Watchtower reads your own work. A **Team Summary** sits above the list.

## Why use it

Before a 1:1, a hard thread or a first message to someone new, a card gives you their style and your history together in a glance. The briefing and day plan read the same cards.

## How it works

**Cards are built from digests, once a day.** The daemon generates cards at most every 24 hours. Each run covers the last 7 days of Slack, ending at the start of today. The first run on a fresh install ends now, so cards do not wait for midnight.

**Only people you work with directly.** A colleague gets a card when you shared a DM or group DM, a thread or a mention with them in the window and they wrote at least 3 messages; people you only read in shared channels get none. Without a known owner identity there are no cards at all.

**Full or light.** With 3 or more digest observations about them, or 10 or more messages, it is a full card. Otherwise it is a lighter one, and the screen says "Not enough data for full analysis." The run as a whole is skipped only when the digests hold no observations at all.

**The Team Summary comes with the run.** After the cards, one more AI call writes the team-level summary: what the team worked on, and **Tips**. It never singles anyone out.

**It depends on Digests.** People Cards read what [Digests](digests.md) record, so both **People Cards** and **Slack Digests** must be on. A run with no data (no digests yet, or nobody active) writes no run record and does not use up the day, so cards appear in the first cycle that has material. After 3 failed AI attempts in a day it waits until tomorrow.

**Bots and deleted accounts get no card.** Only accounts Slack itself flags as bots are excluded. A user you mute or hand-mark as a bot in [Statistics](statistics.md) still gets a card, although a muted user's messages are not read when digests are written.

## Using it

<!-- learn
id: people-cards
title: Read a colleague's card before a 1:1
text: Open **People** for each colleague's work topics, decision role and how best to work with them.
area: communication
level: next
kind: feature
since: 0.24.0
action: nav:people
requires: feature:people-cards
-->

<!-- learn
id: people-team-summary
title: Check the Team Summary
text: Select **Team Summary** in **People** for what your team worked on, with tips.
area: communication
level: next
kind: tip
since: 0.24.0
action: nav:people
-->

<!-- learn
id: people-connections
title: Tell it who your manager is
text: Use **Edit Connections** on **My Card** to set your manager, reports and peers; the briefing uses them.
area: communication
level: power
kind: tip
since: 0.24.0
action: nav:people
-->

1. Open **People**. **My Card** is pinned first, then everyone else. Select **Team Summary** for the team view.
2. A card starts with what it is based on ("Based on 42 messages in 5 channels you share"), then the summary, **Decision role**, **Communication Guide**, **Tactics**, **Accomplishments**, **Highlights** and a week-by-week history. When Jira is connected and the person has work there, a **Delivery** box adds closed issues, cycle time, velocity and open issues, plus **Expertise** tags.
3. A colleague asked you not to keep a card? Press **Stop card for this person**, then **Stop card**. Their card is deleted and no new one is made; messages, digests, search and **Find experts** are not affected. Their view then offers **Make cards again**.
4. On **My Card**, the **Connections** tab lists **Your org links**: the manager, peers and reports you entered. **Edit Connections** changes them; the briefing and other cards use that.
5. The box **How the system understands you** appears on your card when you wrote custom profile context.

## When it's empty or wrong

- **"No people cards yet"**: cards need digests first, then up to a day for the first run. On a new install expect them after the first cycle that produced digests.
- **A colleague has no card.** You shared no DM, thread or mention with them in the last 7 days, they wrote fewer than 3 messages, you stopped their card, or they are a bot or a deleted account.
- **A card says "Not enough data."** It was built from thin signals and improves as messages accumulate.
- **The card is a day old.** Cards refresh at most daily.
- **Your reports or manager look wrong.** Fix them under **Edit Connections** on **My Card**.

Tab still empty? See [A tab is empty](../troubleshooting/tab-is-empty.md).

## Related

[Digests](digests.md), [Statistics](statistics.md).
