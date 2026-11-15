# Statistics

Statistics shows how busy your synced Slack channels and people are, and it is where you decide what the AI reads. Its main job is cost and noise control: mute a channel or a bot here and it drops out of [Digests](digests.md), [Tracks](tracks.md) and the briefing, or stop syncing a channel you never need.

## Why use it

Most of the AI bill and most of the noise come from a few channels: bot feeds, huge announcement rooms, channels you never join in. Statistics points at them with reasons, and one click removes them from analysis. Muting deletes nothing and syncing carries on; only the AI skips them. **Stop syncing** goes further and stops storing the channel at all.

## How it works

**Everything is computed from synced Slack messages.** The three sub-tabs are **Channels**, **Users** and **Activity**. They read the local database and need no AI, so they fill as soon as Slack has synced. Channels with fewer than 5 messages and users with no messages are hidden, and a footer says how many.

**Mute for AI is the real lever.** A muted channel is skipped by channel digests, and so by everything built on them (tracks, rollups, people cards, ideas). Its digests are also left out of the briefing. A muted user is treated as a bot when digests are written, so their messages are not read.

**Stop syncing keeps only what matters to you.** From the next Slack sync on, Watchtower stores no new messages from the channel, except messages that mention you, so those still reach your Inbox. Messages stored before stay. The channel is also muted for AI, unless it already was. When Live Slack is on, the assistant in **Chats** reads such a channel through it; see [sources and accounts](../concepts/sources-and-accounts.md).

**Sync again fills the gap.** It fetches the messages missed while the channel was not synced, a few pages each sync. The row shows **Catching up** meanwhile. These older messages never reach the Inbox. Sync again lifts the AI mute only if Stop syncing set it; a mute you set yourself stays.

**Favorite is only a mark.** It filters the list and stops the channel from being suggested for muting, leaving or stop syncing. No AI step reads it today.

**Recommendations come from simple rules**, shown above the table:

| Suggestion | When it appears |
|---|---|
| **Suggest Mute** | 70% or more bot messages, or 50+ messages with none from you and no mentions of you |
| **Suggest Leave** | You never posted, or last posted over 30 days ago; not a DM, not a favorite, not watched, and you are a member |
| **Suggest Favorite** | You posted 10+ times and were mentioned 3+ times; the channel is on your watch list; or it holds 5+ decisions or 2+ active tracks |
| **Suggest Stop syncing** | Muted for AI 30+ days, with no message from you and no mention of you since the mute; or 90% or more bot messages and no decisions, active tracks, open targets or pending inbox items. Never a favorite, a watched channel, a DM or a channel still catching up |

Pending inbox items or open targets block both muting and leaving suggestions; active tracks or three or more decisions also block leaving. A bot channel you have not muted is offered **Mute** first, and **Stop syncing** once it is muted. A channel you stopped syncing gets no suggestions.

**"Leave" only mutes.** Watchtower cannot remove you from a Slack channel, so the **Mute** button on a **Suggest Leave** row does exactly what the other **Mute** does.

## Using it

<!-- learn
id: statistics-stop-syncing
title: Stop syncing a channel you never read
text: In **Statistics** → **Channels**, press **Stop syncing** on a row; mentions of you still arrive.
area: communication
level: next
kind: feature
since: next
action: nav:statistics
-->

<!-- learn
id: statistics-recommendations
title: Cut AI cost on noisy channels
text: Open **Statistics** → **Channels** and press **Mute** on the suggestions; the AI stops reading them.
area: communication
level: next
kind: tip
since: 0.24.0
action: nav:statistics
-->

<!-- learn
id: statistics-mute
title: Mute a channel or person for AI
text: Toggle **Mute for AI** on a channel or user in **Statistics**; syncing goes on, digests skip it.
area: communication
level: next
kind: feature
since: 0.24.0
action: nav:statistics
-->

<!-- learn
id: statistics-mark-bot
title: Mark a bot Slack missed
text: On **Statistics** → **Users**, press **Mark as bot** on an account Slack doesn't flag as one.
area: communication
level: power
kind: tip
since: 0.24.0
action: nav:statistics
-->

1. Open **Statistics** and pick **Channels**. Read the recommendations, then press **Mute** or **Favorite** on each row you agree with.
2. In the table, the speaker button toggles **Mute for AI** and the star toggles favorite. The filter offers All, Muted, Favorites, Recommendations and **Not synced**, which also lists small channels. Sort by Messages, Name, Bot % or Activity.
3. Press **Stop syncing** at the end of a row, or on a **Suggest Stop syncing** suggestion. The row then shows **Not synced** and the button turns into **Sync again**. If the button reports a failure, the row stays as it was; try again.
4. The **Digest** column shows each channel's status: **Up to date**, **N pending**, **Not processed**, **Too few msgs** or **Muted**. The chart above the table counts them as OK, Pending, New, Few and Muted.
5. On **Users**, mark a person **Mark as bot** or **Mark as human** when Slack got it wrong, and **Mute for AI** for a noisy account. A hand-marked row shows a hand icon.
6. **Activity** summarises human versus bot traffic, the most active users, and a **Bot Management** table for muting bots in one place.

## When it's empty or wrong

- **"No activity yet"** means no Slack messages are synced. Connect Slack and wait for the first sync; see [sources and accounts](../concepts/sources-and-accounts.md).
- **A channel I expected is hidden.** It has fewer than 5 messages; the footer counts them.
- **A muted channel still has old digests.** Muting stops new analysis only. Existing digests and tracks stay until dismissed.
- **A channel I stopped syncing still gets new messages.** They mention you. Those are always stored, so they reach your Inbox.
- **A row says Catching up for a while.** Sync again fetches the missed period a few pages per sync, one channel at a time, so a long gap takes several syncs. You can press **Stop syncing** meanwhile; the next **Sync again** fetches the unfinished part too.
- **A recommendation looks wrong.** It uses message counts only, so a quiet but critical channel can be flagged. Favorite it to stop the suggestion, or ignore it.

Tab still empty? See [A tab is empty](../troubleshooting/tab-is-empty.md).

## Related

[Digests](digests.md), [Tracks](tracks.md), [People](people.md).
