# Inbox

The Inbox is one list of everything that waits on you: your day (the morning brief and today's plan), messages aimed at you, tracks, ideas to judge, actions the assistant proposed, due reminders and notes from your automations. Briefings, Day Plan, Tracks and Ideas have no screens of their own; they are filters here.

## Why use it

You open the Inbox at 09:00. Your day sits on top with the plan and the brief, then a colleague's mention, then a draft Jira issue your :ticket: reaction asked for, waiting for **Approve**. One list, top to bottom, and you are done.

## How it works

### Filters and sections

<!-- learn
id: inbox-filters
title: Filter the Inbox to one kind
text: Pick **Day**, **Messages**, **Tracks**, **Ideas** or **Automations** above the list to see just that; it stays picked.
area: communication
level: basics
kind: feature
since: 0.24.0
action: nav:inbox
-->

The bar above the list has six filters. The one you picked is remembered.

| Filter | Shows |
|---|---|
| **All** | What waits: decisions, today's day card and older unread ones, unread tracks, open messages, due reminders, automation cards |
| **Day** | One **Your day** card per date with a brief or a plan, and today's even before either exists; the last 30 dates, then **Show older** for 30 more |
| **Messages** | Open mentions, DMs, thread replies, mail and Jira or Linear items for you, newest first, up to 200 |
| **Tracks** | Every track you follow, then a folded **Stopped · N** |
| **Ideas** | Ideas, notes and decisions, in every status but merged |
| **Automations** | Proposals, due reminders and your automations' cards |

The list has up to three sections: **Needs your decision** (proposals, a proposed automation, ideas waiting for your verdict), **Today** and **Earlier**, newest first. Today's day card stays first in **Today** until you press **Done** on it.

### What the badge counts

The sidebar badge counts what needs your decision, unread messages, one for an unread latest brief, and due reminders. Tracks, automation cards and ideas of the decision kind never count (everything under **Needs your decision** does); they show only an unread dot in the list.

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

Reacting to a Slack message with an emoji from your dictionary makes the assistant gather the thread, compose an action and bring it back as a card. Reactions are checked on every sync cycle, so **Sync Now** in the menu bar picks one up at once. The built-in **Reactions** runs it, on by default.

| Emoji | Does | Lands in | Default |
|---|---|---|---|
| :eyes: | Starts a track following the topic | Tracks filter | Asks first |
| :bulb: | Captures the message as an idea | Ideas filter | Applies at once |
| :alarm_clock: | Resurfaces the message later (tomorrow 09:00 unless it names a time) | Inbox | Applies at once |
| :pushpin: | Summarises the thread: topic, people, decisions, what you're asked | Inbox | Applies at once |
| :white_check_mark: | Turns the message into a target | Targets | Asks first |
| :ticket: | Drafts an issue in Jira or Linear | Jira or Linear | Always asks |

You edit the dictionary on the **Reactions** card in Automations → **Built in**, which the cheat sheet's **Edit reaction commands in Automations…** button opens; a recipe can also run on a reaction (see [Reactions and tracks in Automations](automations-rules.md)). Reactions placed before the first check are never acted on, and removing then re-adding an emoji on the same message doesn't fire again.

### Which tracker an issue reaction files in

An issue reaction drafts the issue in the tracker whose keys the channel mentions: `ENG-41` (a Linear team) gets Linear, `ABC-9` (a Jira project) gets Jira. With one tracker connected, that one is used. A channel that mentions both, or neither while both are connected, gets the tracker your dictionary names.

### Proposals from everywhere

<!-- learn
id: inbox-proposals
title: Approve what the assistant proposes
text: Actions from reactions, chats and automations wait under **Needs your decision** for your **Approve** or **Reject**.
area: communication
level: basics
kind: feature
since: 0.24.0
action: nav:inbox
-->

**Needs your decision** holds every action waiting for you, whatever started it: a reaction, the main chat, a target's chat, an automation or a Workbench terminal. Actions that touch an outside system, such as Jira, always wait for **Approve**.

### Attention detection

<!-- learn
id: inbox-messages
title: See every message aimed at you
text: The **Messages** filter lists mentions, DMs, replies, mail and issues for you; a card closes when you answer.
area: communication
level: next
kind: feature
since: 0.24.0
action: nav:inbox
-->

**Attention detection** collects the mentions, DMs, thread replies, Jira and Linear issues assigned to you or mentioning you, calendar invites and mail to you. They are the **Messages** cards, and they also feed Catch Up's **For you** list and the brief. An item closes on its own when you answer in the source.

Messages for you in one channel outside threads stay one card that lists each message with its sender and an **Open** link, the 20 newest plus "+N earlier". It makes no AI calls, runs every sync cycle, and needs an account that identifies you.

## Using it

### Handle a card

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

Click a card to open it on the right. **Up** and **Down** move between cards, **Esc** closes the card. The list re-reads every 30 seconds while the Inbox is on screen.

- **Opening marks read** a brief, a message and an automation card, and only that. A track is marked read by its **Done**.
- **Your day**: the plan, then the brief. Before either exists, today's card offers **Make today's brief and plan**. See [Day Plan](day-plan.md) and [Briefings](briefings.md).
- **Messages**: **Open in Slack** (or Mail, Jira, Linear), **Discuss in Chat**, **Hand to Agent…**, **Done** (resolved), **Hide** and **Snooze** (**Tomorrow**, **In 3 days**, **Next week**). These three run the `watchtower` command line, so an error shows on the card.
- **Tracks**: **Done**, and **Stop watching** in **⋯**. See [Tracks](tracks.md).
- **Ideas**: **Approve**, **Make a Task**, **Not now**, **Reject**. See [Ideas & Decisions](ideas-and-decisions.md).
- **Reminders** appear once due: **Done**, or **Snooze 1h**.
- **Automation cards**: their own buttons, then **Open source**, **Discuss in Chat**, **Hand to Agent…**, **Done** and **Dismiss**. See [Buttons on automation cards](automations-inbox-buttons.md).
- **Proposals**: **Approve**, **Reject** or, after a failure, **Retry**. A Slack message offers **Approve & send** so you can edit the text first. A proposed automation shows **Open Draft** and **Reject**.

**Hand to Agent…** asks which workbench when it can't tell. A done action links to its result, such as **Open →** or **Open ABC-7 →**; reaction cards and reminders also show **Slack message ↗**.

### Teach it your preferences

<!-- learn
id: inbox-learned-rules
title: Mute or boost a sender or channel
text: Open **⋯** → **Learned Rules** above the Inbox list; the brief and recaps follow your **Mutes** and **Boosts**.
area: communication
level: next
kind: tip
since: 0.24.0
action: nav:inbox
-->

The **⋯** button above the list opens these in the reading pane, and **?** opens the reaction cheat sheet there:

- **Learned Rules**: **Mutes** and **Boosts** for a sender, channel, Jira label or trigger. The plus adds one, the trash removes one. The brief and recaps follow them.
- **Assistant Profile**: **Who you are**, read by Catch Up and the idea chat, and **Communication style**, which **Generate from my messages** fills for you.

## When it's empty or wrong

Once Watchtower knows who you are, **All** always lists today's day card, so the reaction cheat sheet is behind **?**. Before that, the empty **All** list says why and shows the cheat sheet. An empty filter says what lands there and, when a feature feeds it, that feature's status line.

- **"Enable Reaction Commands" button.** The feature is off. Click it; reactions you placed earlier are not replayed.
- **"Watching your Slack reactions — last check N min ago".** It works; the time is the last successful check.
- **A reaction did nothing.** Check that the emoji is in the dictionary and enabled, that it was a new reaction, and that Slack is connected. Then run **Sync Now**.
- **"Connect Slack, Google, Jira, Linear or an email account so Watchtower knows who you are".** No owner, so Attention detection and the day never run. Click **Open Connections**; a calendar alone is not enough.
- **The badge is lower than the dots.** Tracks, automation cards and decision-kind ideas never count.
- **No reminder yet.** It shows only once due.

Still empty? See [A tab is empty](../troubleshooting/tab-is-empty.md).

## Related

[Catch Up](catch-up.md), [Home](home.md), [Automations](automations.md).

For developers: [docs/features/reaction-commands.md](../../features/reaction-commands.md), [attention-detection.md](../../features/attention-detection.md), [agent-actions.md](../../features/agent-actions.md)
