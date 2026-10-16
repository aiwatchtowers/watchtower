# Digests

Digests turn each busy Slack channel into a short summary of topics, decisions and action items, so you can read a minute instead of scrolling. The same tab also holds Gmail and Jira summaries, meeting recaps, and a **Decisions** journal of what your teams settled.

## Why use it

Catching up on a channel you were away from, or checking "did we decide that?", is a search problem. Digests answer it before you ask, and most other features are built on them: [Tracks](tracks.md), [People](people.md), briefings and ideas all read digests, not raw messages. If digests are off, those stay empty.

## How it works

**A channel gets a digest when it has new human messages.** After each sync cycle the daemon summarises every channel with messages its last digest has not covered. Each channel keeps its own position, so a failed or skipped channel is offered again next cycle.

Left out: muted channels, one-to-one DMs (group DMs are kept), and channels with only bot traffic. A mostly-bot channel is digested around the human replies.

**Trickle channels wait.** A channel digested less than 30 minutes ago with fewer than 10 visible messages is skipped until the next cycle. On a fresh install the first run reads the initial history window, 2 days by default.

**Daily rollups combine channels.** Once at least two channel digests exist for the same UTC day, the daemon writes one **Daily** digest across channels, and rewrites it when a newer channel digest lands. A day with one channel digest gets no rollup. After 3 failed attempts in a day the daemon stops retrying the rollup until the next day.

**Mail and Jira are digested too.** Stream digests summarise new Gmail threads and changed Jira issues per account, at most every 6 hours by default. They need **Stream Digests** on and a connected account, not Slack.

Meeting recaps appear in the same feed once a recording has one.

**Decisions are mined, not typed.** While summarising Slack, mail, Jira and meetings, the AI also extracts decisions. The Ideas pipeline (every 6 hours by default) merges repeats into one entry and keeps its source mentions. Decisions are born settled: **active**, with no review step.

## Using it

1. Open **Digests**. The **Digests** segment is one feed grouped by day, with each row labelled by source. The **Decisions** segment is the journal. The tab badge counts unread digests plus unread decisions.
2. Use **Unread / All** and the search field. Meeting recaps have no unread state, so they appear only under **All**.
3. In **Digests**, **Select** lets you mark many read or rate them at once. Inside a digest, **Create task** on a topic or decision makes a [target](targets.md).
4. In **Decisions**, open a row for its mentions chronology with links back to each source. **Supersede** or **Reverse** changes its status, **Mark all read** clears the unread dots, and **New Decision** records one yourself.
5. Digests are marked read automatically when you have read the channel in Slack.

## When it's empty or wrong

- **"No digests yet"** with Slack connected: wait for the next sync cycle after the first sync. **Slack Digests** must be on (Settings → Features), and a channel needs at least one new human message.
- **A channel is missing.** It is muted (see [Statistics](statistics.md)), a one-to-one DM, bot-only, or inside the 30-minute trickle wait.
- **No Daily digest.** It needs two or more channel digests from the same UTC day.
- **No mail or Jira rows.** **Stream Digests** must be on and a Gmail or Jira account connected. Rows come at most every 6 hours.
- **A decision is missing or doubled.** Decisions appear after the next Ideas run, which merges near-duplicates. Use **Supersede** for one that was replaced and **Reverse** for one that was undone.

Tab still empty? See [A tab is empty](../troubleshooting/tab-is-empty.md).

## Related

[Tracks](tracks.md), [People](people.md), [Ideas & Decisions](ideas-and-decisions.md).

For developers: [docs/features/ideas-decisions-registry.md](../../features/ideas-decisions-registry.md)
