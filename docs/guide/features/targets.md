# Targets

Targets are your own to-do list inside Watchtower: things you must do, follow up on or keep an eye on, each with a due date, an owner and a suggested next step. You write them, or you turn something Watchtower found (a track, a digest topic, a briefing item, an idea, a meeting note) into one.

Targets that belong to a Workbench board live on that board, not in this tab.

## Why use it

Slack and mail make promises easy and tracking them hard. A target keeps the promise next to the context that produced it, and the assistant can break it down, find the Jira tickets and transcripts behind it, and say what to do next. The **Today** section answers "what do I do now?" without a planning session.

## How it works

**Nothing creates targets behind your back.** Every target comes from an action of yours: the **New Target** composer, a **Create Target** / **Create task** / **Create target** button on a track, a digest, a briefing or a meeting note, **Convert to Target** on an idea, a request to the chat, or `watchtower remind`. Each keeps a link back to its source.

**Creation never needs the AI.** The composer saves the row first, titled with the first line of your text. If you chose to brief the assistant, your whole text then goes to the target's chat as its first message. If the AI is down, the target still exists and the error shows in the chat.

**The assistant works only on your instruction.** In a discussion it proposes changes as cards you **Approve** or **Reject**. On a direct instruction ("break this down", "set the deadline to Friday") it applies edits to this target and its new sub-targets at once. A change to any other target on its line (sub-targets at any depth, parents) always waits for your **Approve**. It never touches siblings or unrelated targets, and it never acts between your messages.

**The next step is refreshed by the daemon.** After each sync cycle the daemon writes a **NEXT STEP** card for every To Do, In Progress or Blocked target that has none, or whose text changed since the last one. It handles up to 50 targets per cycle and gives each 3 tries a day, so a target whose reply keeps failing stops until you edit it or tomorrow arrives.

**Dates are watched.** A snoozed target returns to To Do when its date passes. A target whose due date arrives is surfaced once in the Inbox. Both happen in the daemon cycle, so they need the daemon running.

## Using it

1. Press **⌘N** in the Targets tab (or the **+** in the toolbar). Write the target in your own words.
2. Press **Enter** to brief the assistant, or **⌘Enter** to just create. **Shift+Enter** adds a line.
3. To split a pasted blob (meeting notes, a ticket list) into several targets, use **Extract with AI** and review the proposals first.
4. Open a target: **Details** holds the next step, intent, checklist, sub-targets and notes; **Links** holds connections to other targets (**Suggest links** proposes them); **Watch** holds custom tracks watching this goal ([Tracks](tracks.md)); **Assistant** is the chat, with several chats per target.
5. Right-click a row for **Mark Done**, **Dismiss**, **Snooze** (**Tomorrow**, **In 3 days**, **In a week**) and **Delete…**.

**Today** shows active targets that are overdue, due today, or high priority. **All Targets** holds the rest. The sidebar badge shows the overdue count in red when there are overdue targets, otherwise the active count.

On a **NEXT STEP** card, the refresh button regenerates it on demand. After you edit the target or chat about it, a **Context changed since this step** strip appears with **Refresh step**. A target with no step shows **Suggest a next step** and **Generate**.

## When it's empty or wrong

- **"No targets yet"** is normal on a new install: nothing fills this tab until you or a button creates a target. Use **New target** or **Create Target** on a track.
- **No next step on a target.** Only To Do, In Progress and Blocked targets get one. The daemon must be running, the setting `targets.next_step.enabled` must be on (it is by default), and a target that failed 3 times today waits until tomorrow. **Generate** works at any time.
- **A card from the assistant didn't change anything.** Cards apply only after **Approve**. A proposal aimed outside the target's own line fails with an explanation instead of writing elsewhere.
- **A snoozed target hasn't come back.** It returns on the first daemon cycle after its date.

## Related

[Tracks](tracks.md), [Digests](digests.md), the Workbench board for targets an agent works.

For developers: [docs/features/target-brief-chat.md](../../features/target-brief-chat.md)
