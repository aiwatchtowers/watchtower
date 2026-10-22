# Tracks

Tracks are the few things in your Slack that need your eye right now: a request waiting on you, a decision that needs your input, a thread you delegated and must follow. Watchtower pulls them out of your channel digests and merges mentions of the same thing across channels, so you read one entry instead of five threads. You can also create custom tracks, which watch a topic you describe. Tracks are cards in the [Inbox](inbox.md), under its **Tracks** filter.

## Why use it

Scrolling channels to find "what was I asked to do?" is the cost this removes. A track is one line of work, with who asked, what is blocking it, the key messages, and the sub-steps. When something new lands on a track you already read, it comes back marked **Updated**.

## How it works

**Tracks are mined from digests, not from raw messages.** After each sync cycle the daemon reads the channel digests created since its last run and asks the AI which of them hold an actionable request, decision or follow-up for you. A topic that matches an existing track updates it; when the AI is unsure, it creates a new track, so a duplicate is the expected slip. Informational topics, finished work and mere mentions create nothing.

**It needs [Digests](digests.md) first.** Tracks run only when both **Tracks** and **Slack Digests** are on, and they need to know who you are in Slack. Muted channels are skipped. On the first run it looks back over the first sync's window (**Initial History Days**, 3 days when set up in the app); after that it takes only new digests.

**Ownership says whose it is.** **Mine** is on you, **Delegated** is owned by one of your reports and you follow it, **Watching** is something you monitor and is limited to high priority. Priority, category (task, approval, decision needed, code review and so on) and an optional due date come from the AI; you can change the priority from the badge.

**Read state follows Slack.** When you have read the source messages in Slack, the daemon marks the track read for you. In the Inbox, opening a track changes nothing; **Done** marks it read, with its linked digests and its events. Something new on it brings it back as unread.

**Custom tracks are watches.** You describe a topic, the AI turns it into a watch instruction and a name, and each daemon cycle scans new channel digests, auto tracks and inbox items for it. Matches become timeline events. A watch that fails three scans in a UTC day waits until the next day.

## Using it

1. Open the Inbox and pick the **Tracks** filter: every track you follow, updated ones first, with a dot on the unread ones. **All** shows only the unread ones.
2. Click a track for its context, blocking, sub-items, participants, **Key Messages** (open in Slack), **Related Digests**, linked targets and Jira issues. **Open chat** at the bottom unfolds a chat about this track. The priority badge changes its priority.
3. Press **Done** when you have read it. **Open in Slack**, **Discuss in Chat** and **Hand to Agent…** sit beside it.
4. The **⋯** menu has **Stop watching**, which takes the track off the list. A mined track adds **Make a Task**, which creates a [target](targets.md) and opens it; a custom track adds **Go to Target** when it is linked to one, and **Delete…**, which asks inline.
5. Stopped tracks fold into **Stopped · N** at the end of the Tracks filter; **Show** lists them and **Restore** on a card brings it back.
6. To clean up many at once, ask the [AI Chat](ai-chat.md), for example "dismiss every auto track older than a month". It proposes the exact set and waits for your **Approve**.

### Custom tracks on the card

A custom track's card has a **Collecting / Paused** switch and its **Watch instruction** with **Edit**. Its activity shows **New since you looked** first and **Earlier · N** folded until **Show all**. **Scan** fills the timeline for a range: **Since last check**, the last 7, 30 or 90 days, since the track was created, all history, or **Scan from date**. **Stop watching** a custom track also pauses it; **Restore** resumes collecting.

When the track is linked to a target, an event's proposed change waits for your **Apply** or **Dismiss**. **Apply** goes through the same approval as any assistant action, applies once, and says why when it can't (for example "This change was already applied.").

To watch a new topic, open Automations → **Tracks** and press **New track**, describe it and choose **Create with AI**.

## When it's empty or wrong

- **"No tracks yet"** means no digest has produced an actionable item for you yet. Check that **Slack Digests** is on and that digests exist; tracks follow the next cycle after them.
- **Few tracks from a busy channel is by design.** Silence is intended: informational chatter and topics without an action for you are skipped. Muting a channel in [Statistics](statistics.md) removes it from tracks entirely.
- **Duplicates.** The AI matches by meaning and prefers a duplicate to a wrong merge. Press **Stop watching** on the extra one.
- **A custom watch shows nothing.** It scans only while **Collecting** is on and only reads what Watchtower already holds, so use **Scan** to backfill history.

Filter still empty? See [A tab is empty](../troubleshooting/tab-is-empty.md).

## Related

[Inbox](inbox.md), [Digests](digests.md), [Targets](targets.md), [Statistics](statistics.md).
