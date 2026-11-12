# Inbox

The Inbox holds everything that waits on you, in folders you arrange. **Needs approval** has every action and due reminder for you, **Waiting for me** the messages aimed at you, and the top folder, **Inbox**, every automation card that names no other folder.

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
since: 0.28.0
action: nav:inbox
replaces: [inbox-filters]
changed: The filters above the list are gone; folders you arrange replace them.
-->

The Inbox has three columns: the folder menu, the selected folder's list, and the reading pane. **⌥⌘S** (View → **Hide Inbox Folders**) folds the menu away and back. The menu starts with the root, **Inbox**, then **Needs approval**, then your folders as a tree under **Folders**, each with an icon and its own count. The Inbox opens on today's brief, or on the card you last opened in that folder.

An automation's cards go to its folder, the root unless you moved it; **Move to Folder** moves its earlier cards too, and a recipe can name a folder for one card ([which folder a card goes to](automations-inbox-buttons.md#which-folder-a-card-goes-to)). Folders nest 3 deep below the root, up to 100, with titles up to 60 characters.

### What the root holds

The root sorts its rows by urgency. Each row shows a coloured tile for its kind, its first real line, the time and a count of what needs you.

- **Needs you**: **Waiting for me** (people waiting today; older ones as a grey line), **Messages** in its place before it has run or after a failed run, and each **Thread brief** a reaction made, for 24 hours.
- **Today**: **Morning brief**, today's only, then cards your automations changed today.
- **Running**: **Track my threads** ([tracks](tracks.md)), **Idea finder** ([ideas](ideas-and-decisions.md)), then older cards.
- **Earlier**: one line counting the past briefs; click it for **History**.

Your own folders have **Today** and **Earlier**. **Search the Inbox** in the toolbar filters every list by title and first line.

### Needs approval
<!-- learn
id: inbox-needs-approval
title: Approve what the assistant proposes
text: Every proposed action and due reminder waits in **Needs approval** for your **Approve**, **Reject** or **Done**.
area: communication
level: basics
kind: feature
since: 0.28.0
action: nav:inbox
replaces: [inbox-proposals]
changed: Proposals and due reminders moved from Needs your decision to their own folder.
-->

**Needs approval** holds every action waiting for you, whatever started it (a reaction, a chat, an automation, a Workbench terminal, a **Reply…**), and every reminder once due. It can't be moved, renamed, hidden or deleted. The built-in **Needs approval** draws one card per approval, with **Approve**, **Reject** and **Edit…**, **Retry** after a failure; **Done** and **Snooze 1h** on a reminder. Nothing outside Watchtower happens before you approve.

The list groups them by kind, oldest first: **Messages**, **Tracks to create**, **Targets**, **Confluence and Jira**, **Reminders**, **Other**, after **Built-in updates** and before **Approved, still running**. Two or more of one track, target, Confluence or Jira change make one row with **Approve All N…**; messages to people, reminders and **Other** are approved one by one.

A new approval shows in the standard card until the built-in redraws it; so does every approval while the built-in is off, stopped or failing, under a line that says why.

### Waiting for me
<!-- learn
id: inbox-waiting-for-me
title: See who waits on your answer
text: **Waiting for me** at the top of the Inbox lists the mentions, DMs, replies, mail and issues you haven't answered.
area: communication
level: basics
kind: feature
since: 0.28.0
action: nav:inbox
replaces: [inbox-messages]
changed: The Messages filter became the Waiting for me list in the Inbox.
-->

**Attention detection** finds the mentions, DMs, thread replies, Jira and Linear issues assigned to you or mentioning you, and mail to you. The built-in **Waiting for me** turns them into one list after every sync, newest first, up to 200, with each item's age, flagged once it passes a day. An item leaves when you answer in the source (Gmail mail too; Outlook and IMAP mail archives on its own), or press **Done**, **Hide** or **Snooze**.

### What the badge counts

The sidebar badge counts what you can clear today: open approvals in **Needs approval** plus people waiting on you since midnight. Mail, tracks, ideas, briefs and automation cards never count. Until Mail waiting arrives, Waiting for me counts mail from today too.

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

An emoji from your dictionary on a Slack message makes the built-in **Reactions** act on it at the next sync: [what each emoji does](automations-rules.md#what-each-emoji-does).

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

A row in **Waiting for me** has **Open in Slack** (or Mail, Jira, Linear), **Reply…**, **Done**, **Hide**, **Snooze** (**Tomorrow**, **In 3 days**, **Next week**), **Discuss in Chat** and **Hand to Agent…**. Track and idea rows have the buttons [Tracks](tracks.md) and [Ideas](ideas-and-decisions.md) describe. A failed press leaves the row with the error and **Retry**. The list re-reads every 30 seconds.

### Reply to a message
<!-- learn
id: inbox-reply
title: Reply without leaving the Inbox
text: Press **Reply…** on a Waiting for me row, type the answer and **Propose Reply**; it is sent once you approve it.
area: communication
level: next
kind: feature
since: 0.28.0
action: nav:inbox
-->

1. Press **Reply…** on a Slack, Jira or Linear row (mail has none) and type your answer.
2. Press **Propose Reply** (⌘↩). Nothing is sent: the reply waits in **Needs approval**, where **Edit…** can still change it.
3. Approve it there. The row says **Reply waiting for approval** until then, and leaves once the reply is posted and the next sync sees it.

### Read an earlier brief
<!-- learn
id: inbox-brief-history
title: Read an earlier morning brief
text: Open **Morning brief** in the Inbox and press **‹** for the day before, or **History** for the last 30 days.
area: communication
level: next
kind: tip
since: next
action: nav:inbox
-->

1. Open **Morning brief** in the root.
2. Press **‹** for the day before and **›** to come back (it stops at today), or **History** for the last 30 days; unread days carry a dot.
3. The day you open is marked read. Nothing marks a past brief read for you.

### Approve a group at once
<!-- learn
id: inbox-approve-all
title: Approve a group of changes at once
text: In **Needs approval**, press **Approve All N…** on a group of tracks, targets or Jira changes and confirm.
area: communication
level: next
kind: feature
since: next
action: nav:inbox
-->

1. In **Needs approval**, click a group row such as "Create 3 tracks".
2. Press **Approve All 3…** on its header and confirm. Each is approved in turn, exactly as its card shows.
3. A failure stops the run on that card ("Closed 1 of 3. …"); **Try Again** runs what is left.

### Arrange your folders

- **New Folder** under the menu, or **⋯** on a folder: **Rename…**, **Icon**, **New Folder Inside**, **Hide** / **Show**, **Delete…**.
- Drag a folder between two others to reorder it, or onto one to put it inside.
- **Delete…** never deletes content: the folders, automations and cards inside move up to its parent.
- The root's **⋯** has **Show Hidden Folders**; hidden folders show dimmed, and their cards still arrive.
- A card's **⋯** runs its automation's commands ([from its card](automations-inbox-buttons.md#manage-an-automation-from-its-card)).

### Teach it your preferences
<!-- learn
id: inbox-root-rules
title: Mute or boost a sender or channel
text: Open **⋯** on the **Inbox** folder → **Learned Rules**; the brief and recaps follow your **Mutes** and **Boosts**.
area: communication
level: next
kind: tip
since: 0.28.0
action: nav:inbox
replaces: [inbox-learned-rules]
changed: Learned Rules moved to the Inbox folder's ⋯.
-->

The root's **⋯** opens these in the reading pane, and **?** in a pane's header opens the reaction cheat sheet:

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

For developers: [docs/features/inbox-redesign.md](../../features/inbox-redesign.md), [inbox-folders.md](../../features/inbox-folders.md), [reaction-commands.md](../../features/reaction-commands.md), [attention-detection.md](../../features/attention-detection.md)
