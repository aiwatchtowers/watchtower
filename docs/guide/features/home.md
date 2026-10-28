# Home

Home is the page Watchtower opens on. It shows what needs you right now and, on a new install, how far the setup has got.

## Why use it

After a meeting you want one answer: what is waiting for me? Home puts what needs you, then your meetings, in one feed, beside your agents' sessions, shortcuts and today's numbers.

## How it works

Home only reads what the app produced, about every 30 seconds. The feed is on the left; on the right, top to bottom, are **Workbench**, **Links**, **Today in numbers** and **Learn Watchtower** (one column in a narrow window). A zone with nothing to show is left out.

### The feed
<!-- learn
id: home-feed
title: Start the day from Home
text: Home lists what waits on you above the **NOW** line and your meetings below it; **Done** or **Hide** clears a row.
area: communication
level: basics
kind: feature
since: 0.24.0
action: nav:home
-->
<!-- learn
id: home-feed-more
title: Page through what waits on you
text: Press **N more** under the feed to see up to 50 waiting rows right on Home, and **Show 50 more** for the next ones.
area: communication
level: next
kind: tip
since: 0.25.0
action: nav:home
-->

Above a **NOW** line is everything that waits on you; below it, your meetings and what is still to come.

**Above NOW** are, from the last 72 hours: Slack mentions, direct messages, thread replies and reactions, then Jira and Linear items, proposals and failed actions from the assistant, automation notes, due reminders, your own targets that are overdue or due today, and email. Inbox rows follow its detection and snooze; a read one stays, dimmer; an automation note leaves once you open its card, and so does a Jira row whose issue was deleted. Newest first within each kind; seven rows show, **N more** opens up to 50, and **Show 50 more** the next 50. Workbench targets never appear.

**Below NOW** are the meeting in progress, then today's remaining meetings, reminders and timed targets in time order. The next meeting says how soon it starts ("in 25 min") and "Prep ready" when prep exists. Then the first of the next three days with meetings (**Tomorrow** or the weekday) shows up to three of them. All-day, cancelled and declined events are left out.

### Done and Hide

- **Done** resolves a row; **Hide** puts it away. A hidden reminder or target comes back tomorrow at 09:00; a hidden automation note is dismissed, as in Inbox. Proposals and meetings have no buttons: open them instead.
- A row leaves at once; if the action fails it comes back with the error.
- Click a row to open it: Slack, Jira and email open their source, an automation note its Inbox card, the rest Inbox, the target or the meeting.

### Workbench

The **Workbench** zone lists, per workbench, the agent sessions that need a look and their questions to you; **Open →** opens the Workbench tab. Finished and stopped sessions are left out; the rest show while waiting for approval, failed, ready to check or working. Then open questions and review requests, oldest first. Click a session for its terminal (and Branch review when ready to check), a question for its session.

If you keep telling agents or the chat the same thing, the last row offers it as an instruction: **Add** or **Dismiss**.

### Links

The **Links** zone has up to four shortcuts, each shown while its tab (for the briefing and plan, the Inbox) is in the menu:

- **Briefing** shows "ready 08:05" once today's briefing exists, else the latest one's weekday.
- **Catch-Up** shows a highlighted "new recap" while a finished recap waits for **I'm caught up**.
- **Day plan** shows "2 of 5 done" for today's plan.
- **Digests** has no status.

**Briefing** and **Day plan** open today's **Your day** card in the [Inbox](inbox.md).

### Today in numbers

**Today in numbers** counts the current day:

- **messages to me / sent**: Slack DMs and mentions from others, and your sent messages, in every workspace.
- **meetings**: count and hours; all-day, cancelled and declined events don't count.
- **AI spend**: today's AI cost; opens **Usage → Watchtower**.
- **Claude 5 h · week**: your Claude plan limits used.
- **workbench targets new / done**: created and finished today.
- **meetings recorded**: recordings made today.

**AI spend** always shows; a number whose source is off is left out, one that couldn't be read shows "—".

### Learn Watchtower
<!-- learn
id: home-learn
title: Learn a feature at a time
text: The **Learn Watchtower** zone on Home shows three features to try; **Got it** brings the next ones.
area: setup
level: basics
kind: feature
since: 0.25.0
action: nav:home
-->

The last zone shows three cards about what Watchtower can do: this version's new ones first (marked **NEW**), then your setup areas. Each has a button to try it, **Read more** and **Ask about this**. Its button, **Got it** or using the feature marks it seen; **See all →** lists every card, with **Show again**.

### Data scheduled for deletion

When an account's data is scheduled for deletion ([Revoked access](../concepts/revoked-access.md)), a red banner at the top names it, with **Reconnect** until the deletion starts.

### The Getting ready zone

On a new install a **Getting ready** zone sits above the columns, its header counting the ready ones ("6 of 11 ready"). Each feature on and not yet ready gets a status line, such as "Preparing now" or "Within ~15 min". Finished features share one **Ready** line; a name opens it. If the background sync has stopped for 30 seconds or more, unfinished features say "Watchtower isn't running"; the banner has **Start**.

While no account tells Watchtower who you are, the Inbox, Briefing and Day Plan lines say "Connect Slack, Google, Jira, Linear or an email account to get this" instead of a time, with **Open Connections**. A Jira site or Linear workspace that has not reported who you are yet shows "Waiting for your Jira identity…" (or Linear) instead.

A source you haven't connected becomes one dashed row ("Connect Jira to get Workload, Blockers, Project Map and Releases") with a **Connect** button. A row goes only when your company forbids every source behind it. A connected Jira with no board picked keeps **Choose Jira boards**, which opens **Connections** → **Jira**.

When every feature is ready or retrying on its own, the zone shrinks to "Everything's ready" for the rest of that launch. It folds three days after it first showed, whatever still waits. An install that was already ready never sees it.

## Using it

- Click **×** in the Getting ready header to hide it for good.
- If the tab you were on is turned off or loses its source, you land on Home.

### The menu on the left

The menu lists Home, Targets, Workbench, Automations and Calendar, then three collapsible sections:

- **FOCUS**: Catch Up, Inbox (briefings, plans, tracks and ideas are its filters).
- **EXECUTION**: Project Map, Releases, Blockers, Workload.
- **INSIGHTS**: Digests, People, Memory, Statistics.

Chats and the TOOLS (Connections, with a badge for services that need you, Usage, MCP Server) sit at the bottom. FOCUS starts open, the others folded; your folds are remembered.

- **⌘B** folds the menu into an icon rail and back; there each section is one icon with its tabs.
- Right-click a tab for **Hide**; it moves to the section's **HIDDEN** list, where **Show** brings it back.
- Until Slack, mail and Jira are connected, a quiet **+ Connect …** line at the bottom names what is missing, unless your company forbids it, and opens **Connections**. **×** hides it for good.
- Badges show what waits: the Inbox's count, a recap.

Home ends with "Stuck? Press **⌘/** to ask, or open the User Guide."; **⌘/** opens the [assistant over this tab](ai-chat.md).

## When it's empty or wrong

- **No Getting ready zone.** It shows only while something is preparing or waiting for a source, and is gone after three days or once you hid it.
- **A tab is missing from the menu.** Turn its feature on in Settings → Features and connect its source, or look under **HIDDEN**.
- **A link or number is missing.** Its tab is hidden, or its feature or source is off.
- **The feed has no Slack, Jira, Linear or email rows.** Inbox detection is off, or nothing arrived in the last 72 hours.
- **No meetings below NOW.** Calendar isn't connected or its tab is hidden, or the events are all-day, cancelled or declined.
- **No Learn Watchtower zone.** The cards couldn't be read; the next launch tries again.
- **"Couldn't read … — see the log."** A zone (Workbench, the links, or a feed source) couldn't read the local database. Reopen the app; if it persists, check the app log.

A tab stays empty? See [A tab is empty](../troubleshooting/tab-is-empty.md).

## Related

[Workbench](workbench/README.md), [Catch Up](catch-up.md), [Briefings](briefings.md), [Inbox](inbox.md), [Day Plan](day-plan.md).

For developers: [docs/features/first-run.md](../../features/first-run.md)
