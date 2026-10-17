# Statistics

Statistics shows how busy your synced Slack channels and people are, and it is where you decide what the AI reads. Its main job is cost and noise control: mute a channel or a bot here and it drops out of [Digests](digests.md), [Tracks](tracks.md) and the briefing.

## Why use it

Most of the AI bill and most of the noise come from a few channels: bot feeds, huge announcement rooms, channels you never join in. Statistics points at them with reasons, and one click removes them from analysis. Nothing is deleted and syncing carries on; only the AI skips them.

## How it works

**Everything is computed from synced Slack messages.** The three sub-tabs are **Channels**, **Users** and **Activity**. They read the local database and need no AI, so they fill as soon as Slack has synced. Channels with fewer than 5 messages and users with no messages are hidden, and a footer says how many.

**Mute for AI is the real lever.** A muted channel is skipped by channel digests, and so by everything built on them (tracks, rollups, people cards, ideas). Its digests are also left out of the briefing. A muted user is treated as a bot when digests are written, so their messages are not read.

**Favorite is only a mark.** It filters the list and stops the channel from being suggested for muting or leaving. No AI step reads it today.

**Recommendations come from simple rules**, shown above the table:

| Suggestion | When it appears |
|---|---|
| **Suggest Mute** | 70% or more bot messages, or 50+ messages with none from you and no mentions of you |
| **Suggest Leave** | You never posted, or last posted over 30 days ago; not a DM, not a favorite, not watched, and you are a member |
| **Suggest Favorite** | You posted 10+ times and were mentioned 3+ times; the channel is on your watch list; or it holds 5+ decisions or 2+ active tracks |

Pending inbox items or open targets block both muting and leaving suggestions; active tracks or three or more decisions also block leaving.

**"Leave" only mutes.** Watchtower cannot remove you from a Slack channel, so the **Mute** button on a **Suggest Leave** row does exactly what the other **Mute** does.

## Using it

1. Open **Statistics** and pick **Channels**. Read the recommendations, then press **Mute** or **Favorite** on each row you agree with.
2. In the table, the speaker button toggles **Mute for AI** and the star toggles favorite. The filter offers All, Muted, Favorites and Recommendations. Sort by Messages, Name, Bot % or Activity.
3. The **Digest** column shows each channel's status: **Up to date**, **N pending**, **Not processed**, **Too few msgs** or **Muted**. The chart above the table counts them as OK, Pending, New, Few and Muted.
4. On **Users**, mark a person **Mark as bot** or **Mark as human** when Slack got it wrong, and **Mute for AI** for a noisy account. A hand-marked row shows a hand icon.
5. **Activity** summarises human versus bot traffic, the most active users, and a **Bot Management** table for muting bots in one place.

## When it's empty or wrong

- **"No activity yet"** means no Slack messages are synced. Connect Slack and wait for the first sync; see [sources and accounts](../concepts/sources-and-accounts.md).
- **A channel I expected is hidden.** It has fewer than 5 messages; the footer counts them.
- **A muted channel still has old digests.** Muting stops new analysis only. Existing digests and tracks stay until dismissed.
- **A recommendation looks wrong.** It uses message counts only, so a quiet but critical channel can be flagged. Favorite it to stop the suggestion, or ignore it.

Tab still empty? See [A tab is empty](../troubleshooting/tab-is-empty.md).

## Related

[Digests](digests.md), [Tracks](tracks.md), [People](people.md).
