# Inbox

The Inbox is a short queue of things waiting for your decision: reminders that came due, actions the assistant proposed, and notes from your automations. It also hides the machinery that spots what is aimed at you, which feeds Catch Up and the briefing.

## Why use it

You see a Slack message you can't deal with now and react with an alarm clock. Tomorrow at 09:00 it comes back in the Inbox as a reminder with a link to the message. Another reaction turns a thread into a draft Jira issue, and it waits in the Inbox until you click **Approve**.

Nothing lands here on its own: every card exists because of something you did.

## How it works

### Reaction commands

Reacting to a Slack message with an emoji from your dictionary makes the assistant gather the message's thread, compose an action and bring it back as a card. Reactions are checked on every sync cycle, so **Sync Now** in the menu bar picks one up at once. The feature is **Reaction Commands**, on by default.

| Emoji | Does | Lands in | Default |
|---|---|---|---|
| :eyes: | Starts a track following the topic | Tracks | Asks first |
| :bulb: | Captures the message as an idea | Ideas | Applies at once |
| :alarm_clock: | Resurfaces the message later (tomorrow 09:00 unless it names a time) | Inbox | Applies at once |
| :pushpin: | Summarises the thread: topic, people, decisions, what you're asked | Inbox | Applies at once |
| :white_check_mark: | Turns the message into a target | Targets | Asks first |
| :ticket: | Drafts a Jira issue | Jira | Always asks |

You edit the dictionary in Automations → Reactions. A recipe can also run on a reaction; see [Reactions and tracks in Automations](automations-rules.md). Reactions you had placed before the first check are recorded as history, never acted on, and removing then re-adding the same emoji on the same message doesn't trigger it again. React on a different message instead.

### Proposals from everywhere

The **Proposals** section holds every action waiting for a decision, whatever started it: a reaction, the AI Chat, a target's chat, an automation or a Workbench terminal (for example a Slack message it wants to send). Actions that touch an outside system, such as Jira, always wait for **Approve**.

### Attention detection

Behind the scenes, **Attention detection** collects the mentions, DMs, thread replies, Jira comment mentions, calendar invites and mail addressed to you. It closes each one when you answer in the source.

Messages for you in one channel outside threads, such as several mentions or DMs, stay one item that keeps them: Catch Up shows "3 mentions" (or "3 messages" when they are not all mentions), each with its sender and an **Open** link, the 20 newest plus "+N earlier". A new message adds to the item and marks it unread again, so an older one is never replaced, and the item comes back in the next recap.

It makes no AI calls, runs every sync cycle, and needs an account that identifies you. It has no screen of its own: its output is Catch Up's **For you** list and the briefing's **Needs Attention**.

## Using it

The tab has three views: **Actions**, **Learned** and **Profile**.

### Handle the Actions list

Up to three sections, newest or soonest first:

- **Reminders** appear once they are due. **Done** clears one, **Snooze 1h** brings it back in an hour.
- **From your automations** shows notes your automations left here. **Done** marks one read, **Dismiss** removes it. The "run" link opens that run.
- **Proposals** offer **Approve**, **Reject** or, after a failure, **Retry**. A Slack message offers **Approve & send** so you can edit the text first.

When an action is done, its card links to the result, such as **Open →** for the new idea, target or track, or **Open ABC-7 →** for a Jira issue. Cards that came from a reaction and due reminders also show **Slack message ↗**. The badge on the tab counts proposals, due reminders and unread automation notes.

### Teach it your preferences

**Learned** lists **Mutes** and **Boosts**: weighted rules for a sender, channel, Jira label or trigger. Add one with the plus button, or remove it with the trash button. Rules also come from comments you leave on Catch Up topics, and the briefing and recaps follow them.

**Profile** has **Who you are**, a short description of your role and priorities that Catch Up recaps and the idea chat read, and **Communication style**, which **Generate from my messages** fills for you.

## When it's empty or wrong

The empty tab says "Nothing waiting for you". It shows a reaction cheat sheet: one line per enabled emoji. The **?** button above a non-empty list opens the same sheet.

- **"Enable Reaction Commands" button.** The feature is off. Click it; reactions you placed earlier are not replayed.
- **"Watching your Slack reactions — last check N min ago".** Reaction Commands is working. The time is the last successful check.
- **A reaction did nothing.** Check that the emoji is in the dictionary and enabled, that it was a new reaction on a different message, and that Slack is connected. Then run **Sync Now**.
- **A status line under the empty message.** It follows Attention detection, not the list, and the Inbox list works without it:

| Line | Meaning |
|---|---|
| Off — Turn on | Attention detection is off; **Turn on** enables it for Catch Up and the briefing |
| Connect a source to get this | No account connected yet |
| Starts after the first sync | The first sync hasn't finished |
| Preparing now | A detection pass is running |
| Within ~15 min, After this sync | The next pass is due on the next cycle |
| Didn't work yet — retries automatically | The last pass failed; the reason follows the dash |

- **"Connect Slack, Google, Jira, Linear or an email account so Watchtower knows who you are".** There is no owner, so Attention detection never runs. Click **Open Connections** and connect one; a calendar alone is not enough.
- **No reminder yet.** A reminder shows only once it is due.

Tab still empty? See [A tab is empty](../troubleshooting/tab-is-empty.md).

## Related

[Catch Up](catch-up.md), [Briefings](briefings.md), [Ideas & Decisions](ideas-and-decisions.md), [Home](home.md).

For developers: [docs/features/reaction-commands.md](../../features/reaction-commands.md), [attention-detection.md](../../features/attention-detection.md), [agent-actions.md](../../features/agent-actions.md)
