# Inbox

The Inbox is a menu of folders you arrange, holding everything that waits on you. Your automations put their cards into folders; the top folder, **Inbox**, gets everything whose automation names no other. **Needs approval** holds every action and due reminder that waits for you, and **Waiting for me** lists the messages aimed at you.

## Why use it

You open the Inbox at 09:00. **Needs approval** shows 1: the draft Jira issue your :ticket: reaction asked for. In the root, **Waiting for me** lists two pings; you press **Reply…** on one and **Done** on the other. Your Monday Jira summary sits in its own **Release** folder, out of the way until you want it.

## How it works

### Folders and the menu
<!-- learn
id: inbox-folders
title: Sort the Inbox into folders
text: Press **New Folder** under the Inbox menu, then **Move to Folder** in a card's **⋯** to send its cards there.
area: communication
level: basics
kind: feature
since: next
action: nav:inbox
replaces: [inbox-filters]
changed: The filters above the list are gone; folders you arrange replace them.
-->

The Inbox has three columns: the folder menu, the selected folder's list, and the reading pane. The menu starts with the root, **Inbox**, then **Needs approval**, then your folders as a tree, each with an icon and its own count. The folder you picked is remembered.

An automation's cards go to its folder, the root unless you moved it. **Move to Folder** moves the automation, so its earlier cards move with it. A recipe can also name a folder for one card ([which folder a card goes to](automations-inbox-buttons.md#which-folder-a-card-goes-to)). Folders nest up to 3 deep below the root; you can have up to 100, with titles up to 60 characters.

### What the root holds

The root lists **Waiting for me** first while anyone waits on you, then, newest first, the cards your automations put there and these entries:

- **Morning brief**: today's day and every one you haven't read, with the plan and the brief. One you have read leaves the list; Home's **Briefing** link and a briefing notification still open it.
- **Track my threads**: your [tracks](tracks.md), with **Stopped · N** at the end.
- **Idea finder**: [ideas and decisions](ideas-and-decisions.md), those to judge under **Needs your decision**.
- **Messages**: only before **Waiting for me** has run, and after a run of it failed, so a message never waits on a run.

### Needs approval
<!-- learn
id: inbox-needs-approval
title: Approve what the assistant proposes
text: Every proposed action and due reminder waits in **Needs approval** for your **Approve**, **Reject** or **Done**.
area: communication
level: basics
kind: feature
since: next
action: nav:inbox
replaces: [inbox-proposals]
changed: Proposals and due reminders moved from Needs your decision to their own folder.
-->

**Needs approval** holds every action waiting for you, whatever started it (a reaction, a chat, an automation, a Workbench terminal, a **Reply…**), and every reminder once due. It can't be moved, renamed, hidden or deleted. The built-in **Needs approval** draws one card per approval, and each card carries the usual buttons: **Approve**, **Reject** and **Edit…**, **Retry** after a failure; **Done** and **Snooze 1h** on a reminder. Nothing outside Watchtower happens before you approve.

A new approval shows at once in the standard card until the built-in redraws it. While the built-in is off, stopped or its last run failed, every approval shows in the standard card, under a line that says why.

### Waiting for me
<!-- learn
id: inbox-waiting-for-me
title: See who waits on your answer
text: **Waiting for me** at the top of the Inbox lists the mentions, DMs, replies, mail and issues you haven't answered.
area: communication
level: basics
kind: feature
since: next
action: nav:inbox
replaces: [inbox-messages]
changed: The Messages filter became the Waiting for me list in the Inbox.
-->

**Attention detection** finds the mentions, DMs, thread replies, Jira and Linear issues assigned to you or mentioning you, and mail to you. The built-in **Waiting for me** turns them into one list after every sync, newest first, up to 200, with each item's age, flagged once it passes a day. An item leaves when you answer in the source, or press **Done**, **Hide** or **Snooze**. Detection makes no AI calls and needs an account that identifies you.

### What the badge counts

Each folder counts its own unread cards, and the rows of a list that still wait on you. The sidebar badge is the sum over the folders you see; a hidden folder leaves it.

### Reaction commands
<!-- learn
id: inbox-reactions
title: React with an emoji to act
text: React to a Slack message with :eyes:, :bulb: or :ticket: and a track, an idea or a draft issue comes back as a card.
area: communication
level: basics
kind: feature
since: 0.24.0
requires: source:slack
done_when: reaction.used
-->

<!-- learn
id: inbox-reaction-dictionary
title: Edit your reaction dictionary
text: Choose which emoji do what on the **Reactions** card in Automations → **Built in**.
area: communication
level: next
kind: tip
since: 0.24.0
action: nav:automations
-->

An emoji from your dictionary on a Slack message makes the built-in **Reactions** gather the thread and compose an action, checked every sync cycle (**Sync Now** picks one up at once).

| Emoji | Does | Default |
|---|---|---|
| :eyes: | Starts a track on the topic | Asks first |
| :bulb: | Captures the message as an idea | Applies at once |
| :alarm_clock: | A reminder, tomorrow 09:00 unless it names a time | Applies at once |
| :pushpin: | Summarises the thread | Applies at once |
| :white_check_mark: | Turns the message into a target | Asks first |
| :ticket: | Drafts an issue in Jira or Linear | Always asks |

"Asks first" waits in **Needs approval**. An issue goes to the tracker whose keys the channel mentions (`ENG-41` Linear, `ABC-9` Jira), else the one your dictionary names. Edit the dictionary on the **Reactions** card in Automations → **Built in** ([Reactions and tracks](automations-rules.md)). Reactions placed before the first check are never acted on.

## Using it

### Handle a row
<!-- learn
id: inbox-snooze
title: Snooze a message until later
text: Press **Snooze** on a message card and pick **Tomorrow**, **In 3 days** or **Next week**; it stays away until then.
area: communication
level: next
kind: tip
since: 0.24.0
action: nav:inbox
-->

<!-- learn
id: inbox-hand-to-agent
title: Hand a message to an agent
text: Press **Hand to Agent…** on a message card to give the work to a Workbench agent.
area: communication
level: power
kind: feature
since: 0.24.0
action: nav:inbox
-->

A row in **Waiting for me** has **Open in Slack** (or Mail, Jira, Linear), **Reply…**, **Done**, **Hide**, **Snooze** (**Tomorrow**, **In 3 days**, **Next week**), **Discuss in Chat** and **Hand to Agent…**. A track row has **Done** and **Stop watching**, an idea row its verdict buttons. While a press runs the row's buttons wait; a failed press leaves the row with the error and **Retry**. The list re-reads every 30 seconds.

### Reply to a message
<!-- learn
id: inbox-reply
title: Reply without leaving the Inbox
text: Press **Reply…** on a Waiting for me row, type the answer and **Propose Reply**; it is sent once you approve it.
area: communication
level: next
kind: feature
since: next
action: nav:inbox
-->

1. Press **Reply…** on a Slack, Jira or Linear row (mail has none) and type your answer.
2. Press **Propose Reply** (⌘↩). Nothing is sent: the reply waits in **Needs approval**, where **Edit…** can still change it.
3. Approve it there. The row says **Reply waiting for approval** until then, and leaves once the reply is posted and the next sync sees it.

### Arrange your folders

- **New Folder** under the menu, or **⋯** on a folder: **Rename…**, **Icon**, **New Folder Inside**, **Hide** / **Show**, **Delete…**.
- Drag a folder between two others to reorder it, or onto one to put it inside.
- **Delete…** never deletes content: the folders, automations and cards inside move up to its parent.
- The root's **⋯** has **Show Hidden Folders**; hidden folders show dimmed, and their cards still arrive.

### Manage an automation from its card

The **⋯** on a card's header runs the same commands as the Automations tab: **Run Now**, **Edit What It Collects…**, **Edit the Look…**, **Schedule…**, **Move to Folder**, **Turn Off**, **Run History** and **Delete…** (not on a built-in). **New Artifact…** under the menu starts a new automation whose cards go to the selected folder.

### Teach it your preferences
<!-- learn
id: inbox-root-rules
title: Mute or boost a sender or channel
text: Open **⋯** on the **Inbox** folder → **Learned Rules**; the brief and recaps follow your **Mutes** and **Boosts**.
area: communication
level: next
kind: tip
since: next
action: nav:inbox
replaces: [inbox-learned-rules]
changed: Learned Rules moved to the Inbox folder's ⋯.
-->

The root's **⋯** opens these in the reading pane, and **?** above the Inbox opens the reaction cheat sheet:

- **Learned Rules**: **Mutes** and **Boosts** for a sender, channel, Jira label or trigger. The brief and recaps follow them.
- **Assistant Profile**: **Who you are** and **Communication style** (**Generate from my messages**).

## When it's empty or wrong

- **"Your Inbox is empty".** Nothing landed in the root yet; **New Artifact…** makes an automation.
- **"Nothing in Release yet".** No automation writes to that folder; use **Move to Folder** on a card.
- **"Showing approvals in the standard card — …".** The built-in Needs approval is off, was stopped, or its last run failed. **Turn On** or **Run History**; nothing waits unseen meanwhile.
- **"The menu changed — reloaded. Drag again if needed."** Another change landed first; nothing moved. Try again.
- **"The watchtower CLI isn't available".** Menu edits and presses that run it are off; reading still works.
- **A message you answered is still listed.** It leaves at the next sync after the answer reaches Watchtower.
- **"Connect Slack, Google, Jira, Linear or an email account so Watchtower knows who you are".** Without it, attention detection and the brief never run. Click **Open Connections**.
- **A reaction did nothing.** Check the emoji is in the dictionary and enabled, it was a new reaction and Slack is connected, then **Sync Now**.

Still empty? See [A tab is empty](../troubleshooting/tab-is-empty.md).

## Related

[Catch Up](catch-up.md), [Home](home.md), [Automations](automations.md), [Built-in automations](automations-built-in.md).

For developers: [docs/features/inbox-folders.md](../../features/inbox-folders.md), [reaction-commands.md](../../features/reaction-commands.md), [attention-detection.md](../../features/attention-detection.md)
