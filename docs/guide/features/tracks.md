# Tracks

Tracks are the few things in your Slack that need your eye right now: a request waiting on you, a decision that needs your input, a thread you delegated and must follow. Watchtower pulls them out of your channel digests and merges mentions of the same thing across channels, so you read one entry instead of five threads. You can also create custom tracks, which watch a topic you describe.

## Why use it

Scrolling channels to find "what was I asked to do?" is the cost this removes. A track is one line of work, with who asked, what is blocking it, the key messages, and the sub-steps. When something new lands on a track you already read, it comes back marked **Updated**.

## How it works

**Tracks are mined from digests, not from raw messages.** After each sync cycle the daemon reads the channel digests created since its last run and asks the AI which of them hold an actionable request, decision or follow-up for you. A topic that matches an existing track updates it; the prompt prefers merging over splitting. Informational topics, finished work and mere mentions create nothing.

**It needs [Digests](digests.md) first.** Tracks run only when both **Tracks** and **Slack Digests** are on, and they need to know who you are in Slack. Muted channels are skipped. On the first run it looks back over the initial history window (2 days by default); after that it takes only new digests.

**Ownership says whose it is.** **Mine** is on you, **Delegated** is owned by one of your reports and you follow it, **Watching** is something you monitor and is limited to high priority. Priority, category (task, approval, decision needed, code review and so on) and an optional due date come from the AI; you can change the priority from the badge.

**Read state follows Slack.** When you have read the source messages in Slack, the daemon marks the track read for you. Opening a track marks it read and marks its linked digests read too.

**Custom tracks are watches.** You describe a topic, the AI turns it into a watch instruction and a name, and each daemon cycle scans new channel digests, auto tracks and inbox items for it. Matches become timeline events. A watch that fails three scans in a UTC day waits until the next day.

## Using it

1. Open **Tracks**. The orange number next to the title counts tracks updated since you read them.
2. Filter by priority, by **All / Mine / Delegated / Watching**, or by Jira link (the Jira filter appears when Jira is connected). The eye button toggles read tracks, the archive button toggles dismissed ones.
3. Open a track to see context, blocking, sub-items, participants, **Key Messages** (open in Slack), **Related Digests**, linked targets and Jira issues. A chat at the bottom talks about this track.
4. **Create Target** turns it into a [target](targets.md); the track then shows **Go to Target**. **Dismiss** removes it from the list; **Restore** brings it back.
5. To clean up in bulk, use the checklist button: **Select tracks**, then **Select all** and **Dismiss selected**, or **Dismiss all auto tracks…** (custom tracks stay). Both ask for confirmation with the exact count.
6. To watch a topic, press **+** ("Create a custom track to watch"), describe it and choose **Create with AI**.

On a custom track, **Collecting / Paused** switches scanning. **Scan** fills the timeline for a range: **Since last check**, last 7, 30 or 90 days, since the track was created, all history, or from a date. When the watch is linked to a target, an event's proposed change waits for your **Apply** or **Dismiss**.

## When it's empty or wrong

- **"No tracks yet"** means no digest has produced an actionable item for you yet. Check that **Slack Digests** is on and that digests exist; tracks follow the next cycle after them.
- **Few tracks from a busy channel is by design.** Silence is intended: informational chatter and topics without an action for you are skipped. Muting a channel in [Statistics](statistics.md) removes it from tracks entirely.
- **Duplicates or a wrong merge.** The AI matches by meaning. Dismiss the extra one; rate the track with the thumbs buttons to improve later runs.
- **A custom watch shows nothing.** It scans only while **Collecting** is on and only reads what Watchtower already holds, so use **Scan** to backfill history.

## Related

[Digests](digests.md), [Targets](targets.md), [Statistics](statistics.md).

For developers: [docs/inventory/tracks.md](../../inventory/tracks.md)
