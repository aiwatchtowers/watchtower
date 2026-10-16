# Catch Up

Catch Up writes a recap of a stretch of time you weren't watching: what happened, what was decided, which meetings you missed and what needs you. It is for the morning after a day off, a long meeting day or a holiday.

## Why use it

You come back after a week away with hundreds of unread messages. Instead of scrolling channels, you build one recap for the week: a TL;DR, a handful of topics with their sources, the decisions made, and a short **For you** list of mentions, DMs, mail and tasks aimed at you. Then you press **I'm caught up** and the next recap starts from there.

## How it works

A recap is built only when you ask for it. The daemon never builds one for you.

- **Window.** **Auto** runs from the end of the last recap you marked caught up to now. With none, it covers the last 24 hours, and it never reaches back more than 31 days. The other choices are **Today**, **Yesterday**, **3 days**, **Week**, or **Range** with your own from and to (neither can be in the future).
- **Material.** The recap reads Slack and stream digests, meetings and transcripts, decisions, attention-detection items, tracks and targets for that window.
- **Top-up.** When the window ends within five minutes of now, the digests for the part not yet covered are refreshed first. A failed top-up never fails the recap.
- **One AI call** composes the recap. Every source link in it is checked against what was gathered, and a link that doesn't exist is dropped.

The tab shows when any of Attention detection, Slack Digests or Stream Digests is on and any source (Slack, mail, Jira or a calendar) is connected. **For you** is only as good as Attention detection, which needs no AI and runs every sync cycle.

## Using it

### Build a recap

1. Pick a window in the left column. Under **Auto** a caption names the start.
2. Click **Build recap**. The recap reads "Building the recap…" until it is ready.
3. Click a recap in the history list to read it. Older recaps stay when a new build fails.

A recap shows a TL;DR, **What happened** (topic cards with **Sources** that expand in place), **Decisions**, **Meetings** and **For you**. A window with nothing in it says "Quiet — nothing happened in this window."

### Rebuild a recap with a correction

Type what is wrong in the **Correction…** field at the bottom and click **Regenerate**. The same window is built again with your note.

### Teach it which topics matter

Each topic has a thumbs-up and thumbs-down. Type under **What's wrong with this topic?** and click **Send** to add a comment. A comment can also rebuild the whole recap, and it can become a rule in Inbox → Learned, which the digests, tracks, briefings and recaps then apply.

### Mark it done

Click **I'm caught up**. Everything in the window is marked read: digests, stream digests, tracks, attention items and briefings. The next **Auto** recap starts from there, and the badge on the tab and the **SINCE YOU WERE AWAY** card on Home go away.

## When it's empty or wrong

The empty pane says "No recap yet" with a status line. The line reads like this:

| Line | Meaning | What to do |
|---|---|---|
| Off — Turn on | Slack Digests is off | Click **Turn on** |
| Connect Slack to get this | No Slack workspace connected, so the pane shows **Connect Slack** instead of its **Build a recap** button | Connect Slack, or without Slack use **Build recap** in the left column, which works with mail, Jira or a calendar alone |
| Starts after the first sync | The first sync hasn't finished | Wait; the sync line shows progress |
| Preparing now | Digests are being built right now | Wait, or build anyway |
| Within ~15 min, After this sync | Digests are scheduled for the next cycle | Wait, or click **Build a recap** |
| Didn't work yet — retries automatically | The last digest run failed | Click **Build a recap**; the reason shows in the line |

- **"This recap failed to build."** Click **Retry**. A build stuck for more than 30 minutes is marked failed on its own.
- **"Quiet — nothing happened in this window."** The window had no activity. Pick a wider one.
- **The tab isn't in the menu.** Turn on one of the three features above and connect a source.
- **A recap misses something.** Digests need a sync first, so build after the last sync, or add a **Correction…**.

Tab still empty? See [A tab is empty](../troubleshooting/tab-is-empty.md).

## Related

[Home](home.md), [Briefings](briefings.md), [Inbox](inbox.md).

For developers: [docs/features/catchup.md](../../features/catchup.md)
