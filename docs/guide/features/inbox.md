# Inbox

The Inbox holds everything that waits on you, in folders you arrange. **Needs approval** has every action and due reminder for you, **Waiting for me** the people waiting on your answer, **Mail waiting** your open mail by sender, and the top folder, **Inbox**, every automation card that names no other folder.

## Why use it

You open the Inbox at 09:00. **Needs approval** shows the draft Jira issue your :ticket: reaction asked for. **Waiting for me** lists two pings: **Reply…** to one, **Done** on the other. One newsletter holds 40 of your 60 open mails; **Mark All Done…** in **Mail waiting** clears them.

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

The Inbox has three columns: the folder menu, the folder's list and the reading pane; **⌥⌘S** (View → **Hide Inbox Folders**) folds the menu. The menu lists the root, **Inbox**, then **Needs approval**, then your folders as a tree under **Folders**, each with its own count. The Inbox opens on today's brief, or on the card you last opened in that folder.

An automation's cards go to its folder, the root unless you moved it; **Move to Folder** moves its earlier cards too, and a recipe can name a folder for one card ([which folder a card goes to](automations-inbox-buttons.md#which-folder-a-card-goes-to)).

### What the root holds

The root sorts its rows by urgency; each shows its first real line, the time and a count of what needs you.

- **Needs you**: **Waiting for me** (people waiting today; older ones as a grey line), **Messages** in its place before it has run or after a failed run, **Mail waiting** once it has run, and each **Thread brief** a reaction made, for 24 hours.
- **Today**: **Morning brief**, today's only, then cards your automations changed today.
- **Running**: **Track my threads** ([tracks](tracks.md)), **Idea finder** ([ideas](ideas-and-decisions.md)), then older cards.
- **Earlier**: one line counting the past briefs; click it for **History**.

Your own folders have **Today** and **Earlier**. **Search the Inbox** in the toolbar filters the list by title and first line.

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

**Needs approval** holds every action waiting for you, whatever started it (a reaction, a chat, an automation, a **Reply…**), and every reminder once due. It can't be moved, renamed, hidden or deleted. Each approval is one card with **Approve**, **Reject** and **Edit…** (**Retry** after a failure; **Done** and **Snooze 1h** on a reminder). Nothing outside Watchtower happens before you approve.

The list groups them by kind, oldest first: **Messages**, **Tracks to create**, **Targets**, **Confluence and Jira**, **Reminders**, **Other**. Two or more tracks, targets or one Confluence or Jira action make one row with **Approve All N…**. While the built-in is off, stopped or failing, approvals show in the standard card.

### Waiting for me
<!-- learn
id: inbox-waiting-for-me
title: See who waits on your answer
text: **Waiting for me** at the top of the Inbox lists the mentions, DMs, replies and issues you haven't answered.
area: communication
level: basics
kind: feature
since: 0.28.0
action: nav:inbox
replaces: [inbox-messages]
changed: The Messages filter became the Waiting for me list in the Inbox.
-->

**Attention detection** finds Slack mentions, DMs and thread replies, and Jira and Linear issues assigned to you or mentioning you. The built-in **Waiting for me** lists these people after every sync under **Today**, **This week** and **Older** (7 days or more, folded), newest first, up to 200, each with its age, flagged past a day. An item leaves when you answer in the source or press **Done**, **Hide** or **Snooze**; nothing old leaves on its own. Your own edited copy of Waiting for me lists people only too. No AI calls.

### Mail waiting
<!-- learn
id: inbox-mail-waiting
title: Clear your mail by sender
text: **Mail waiting** groups unanswered mail by sender; **Mark All Done…** clears a sender and **Mute** hides one.
area: communication
level: next
kind: feature
since: next
action: nav:inbox
-->

The built-in **Mail waiting** lists your open mail after every sync, one row per sender, the busiest first: how many are open, how many came today and the newest subject. Its first line says how much comes from the top ten senders. Gmail mail leaves once you reply; Outlook and IMAP mail archives on its own. No AI calls.

### What the badge counts

The sidebar badge counts what you can clear today: open approvals in **Needs approval** plus people waiting on you since midnight. Mail, tracks, ideas, briefs and automation cards never count. In the menu, **Inbox** counts who waits today, today's unread brief and its other unread cards; each folder counts its own.

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

Point at a row in **Waiting for me** for its buttons: **Open in Slack** (or Jira, Linear), **Reply…**, **Done**, **Hide**, **Snooze** (**Tomorrow**, **In 3 days**, **Next week**), **Discuss in Chat** and **Hand to Agent…**. On **Older**'s first row, **Mark All Done…** names the count and closes those items only after you confirm. A failed press leaves the row with the error and **Retry**.

Keys on the focused row: **J** / **K** move, **E** done, **R** reply, **S** snooze, **⏎** open, **⌘K** hand to an agent; on a sender, **⏎** open, **E** mark all done, **M** mute.

### Clear mail by sender

1. In **Mail waiting**, point at a sender: **Open** opens their newest mail.
2. **Mark All Done…** asks first ("Mark 46 Done") and closes exactly those; the row goes at once. A failure says "Closed N of M." with **Try Again**.
3. **Mute** hides a sender from Mail waiting; the mail stays. **Mute Senders…** in the header lists the ten busiest: tick some, press **Mute N Senders**.
4. To unmute, delete the rule under **Mutes** in **Learned Rules** (the root's **⋯**).

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

1. Press **Reply…** on a Slack, Jira or Linear row and type your answer.
2. Press **Propose Reply** (⌘↩). Nothing is sent: the reply waits in **Needs approval**, where **Edit…** can still change it.
3. Approve it there; until then the row says **Reply waiting for approval**.

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

In **Morning brief**, press **‹** for the day before and **›** to come back, or **History** for the last 30 days; unread days carry a dot. The day you open is marked read; nothing marks a past brief read for you.

### Approve a group at once
<!-- learn
id: inbox-approve-all
title: Approve a group of changes at once
text: In **Needs approval**, press **Approve All N…** on a group of tracks, targets or Confluence and Jira changes.
area: communication
level: next
kind: feature
since: next
action: nav:inbox
-->

1. In **Needs approval**, click a group row such as "Create 3 tracks", press **Approve All 3…** on its header and confirm.
2. A failure stops the run on that card ("Closed 1 of 3. …"); **Try Again** runs what is left.

### Arrange your folders

- **New Folder** under the menu, or **⋯** on a folder: **Rename…**, **Icon**, **New Folder Inside**, **Hide** / **Show**, **Delete…**.
- Drag a folder between two others to reorder it, or onto one to nest it. **Delete…** moves what is inside up to its parent.
- The root's **⋯** has **Show Hidden Folders**; hidden folders show dimmed, and their cards still arrive.

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

The root's **⋯** opens **Learned Rules** (**Mutes** and **Boosts** for a sender, channel, Jira label or trigger) and **Assistant Profile**. **?** in a pane's header opens the reaction cheat sheet.

## When it's empty or wrong

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
