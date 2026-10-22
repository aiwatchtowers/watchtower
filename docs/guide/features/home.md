# Home

Home is the page Watchtower opens on. It shows what needs you right now and, on a new install, how far the setup has got. The menu on the left is described at the end.

## Why use it

You open the app after a meeting and want one answer: what is waiting for me? Home puts what needs you, then your meetings, in one feed, beside your agents' sessions, shortcuts and today's numbers.

## How it works

Home only reads what the app produced, and refreshes about every 30 seconds. The feed is on the left. On the right, top to bottom, are **Workbench**, **Links** and **Today in numbers**. In a narrow window everything is one column in the same order: feed, Workbench, links, numbers. A zone with nothing to show is left out.

### The feed

The feed reads top to bottom like your day: above a **NOW** line is everything that waits on you, below it your meetings and what is still to come.

**Above NOW** are, from the last 72 hours: Slack mentions, direct messages, thread replies and reactions, then Jira and Linear items, proposals and failed actions from the assistant, notes your automations left for you, due reminders, your own targets that are overdue or due today, and email. Rows from Inbox follow its detection and snooze. A read row stays, shown dimmer; only acting on it removes it. Newest comes first within each kind; seven rows show, and **N more** opens the rest in place. Workbench targets never appear.

**Below NOW** are the meeting in progress, then today's remaining meetings, reminders and timed targets in time order. The next meeting says how soon it starts, such as "in 25 min", and shows "Prep ready" when prep exists. After today, a short block shows the first of the next three days that has meetings: **Tomorrow**, or the weekday, with up to three meetings. All-day, cancelled and declined events are left out.

### Done and Hide

- Press **Done** on a row to resolve it, or **Hide** to put it away. A hidden reminder or target comes back tomorrow at 09:00; a hidden automation note is dismissed, as in Inbox. Proposals and meetings have no buttons: open them instead.
- A row leaves the feed at once. If the action fails it comes back with the error under it; press again to retry.
- Click a row to open it: Slack, Jira and email open their source, an automation note its run, the rest Inbox, the target or the meeting.

### Workbench

The **Workbench** zone lists your coding-agent sessions that need a look and the questions they have asked you, grouped by workbench, with **Open →** for the Workbench tab. Finished and stopped sessions are left out; others show while they wait for approval, failed, are ready to check, or work (or in the background). Then open questions and review requests, oldest first. Click a session for its terminal (plus its Branch review when ready to check), a question for its session.

If you keep telling agents the same thing, the last row offers it as an instruction: **Add** or **Dismiss**.

### Links

The **Links** zone has up to four shortcuts, each shown while its tab is in the menu (for the briefing and plan, the Inbox, with their feature on):

- **Briefing** shows "ready 08:05" once today's briefing exists, else the latest one's weekday.
- **Catch-Up** shows a highlighted "new recap" while a finished recap waits for **I'm caught up**.
- **Day plan** shows "2 of 5 done" for today's plan.
- **Digests** has no status.

**Briefing** and **Day plan** open today's **Your day** card in the [Inbox](inbox.md).

### Today in numbers

**Today in numbers** counts the current day:

- **messages to me / sent**: Slack direct messages and mentions from others, and the messages you sent, in every connected workspace.
- **meetings**: today's meetings and their hours; all-day, cancelled and declined events don't count.
- **AI spend**: today's AI cost.
- **Claude 5 h · week**: your Claude plan limits used.
- **workbench targets new / done**: created and finished today.
- **meetings recorded**: recordings made today.

**AI spend** always shows. A number whose source is off or not connected is left out; one that couldn't be read shows "—".

### The Getting ready zone

On a new install a **Getting ready** zone sits above the columns, its header counting the ready ones ("6 of 11 ready"). Each feature that is on and not ready yet gets a line with its status, such as "Preparing now" or "Within ~15 min". Finished features share one **Ready** line; click a name to open it. If the background sync has been stopped for 30 seconds or more, unfinished features say "Watchtower isn't running"; the banner has **Start**.

While no account tells Watchtower who you are, the Inbox, Briefing and Day Plan lines say "Connect Slack, Google, Jira, Linear or an email account to get this" instead of a time, with **Open Connections**. A Jira site or Linear workspace that has not reported who you are yet shows "Waiting for your Jira identity…" (or Linear) instead.

A source you haven't connected becomes one dashed row ("Connect Jira to get Boards, Workload, Blockers, Project Map and Releases") with a **Connect** button. A connected Jira with no board picked keeps a line with **Choose Jira boards**, which opens **Boards**.

When every feature is ready or retrying on its own, the zone shrinks to "Everything's ready" for the rest of that launch. It also folds three days after it first showed, whatever is still waiting. An install that was already ready never sees it.

## Using it

- Click a row to open that item, or **Open →** to open the Workbench tab.
- Click **×** in the Getting ready header to hide it for good.
- When a tab you were on is turned off or its source is disconnected, you land on Home.

### The menu on the left

The menu lists Home, Targets, Workbench, Automations and Calendar first. Below them are three collapsible sections:

- **FOCUS**: Catch Up, Inbox (briefings, plans, tracks and ideas are its filters).
- **EXECUTION**: Project Map, Releases, Blockers, Workload.
- **INSIGHTS**: Digests, People, Memory, Statistics.

AI Chat and the TOOLS (Search, Boards, Usage, MCP Server) sit at the bottom. FOCUS starts open and the other two start folded; your own folds are remembered.

- **⌘B** folds the menu into an icon rail and back; in the rail each section is one icon that opens its tabs.
- Right-click a tab and choose **Hide**; it moves to the section's **HIDDEN** list, where **Show** brings it back.
- A tab appears only when its feature is on in Settings → Features and its source is connected.
- Until Slack, mail and Jira are all connected, a quiet **+ Connect …** line at the bottom names what is missing and opens Settings → Connections. Its **×** hides it for good.
- Badges show what waits, such as the Inbox's count and a recap waiting.

Home ends with the line "Stuck? Press **⌘/** to ask, or open the User Guide." It is always there, and **⌘/** opens the [assistant over this tab](ai-chat.md).

## When it's empty or wrong

- **No Getting ready zone.** It is shown only while something is still preparing or waiting for a source. It is also gone after three days, or after you hid it.
- **A tab is missing from the menu.** Turn its feature on in Settings → Features and connect its source, or look under **HIDDEN**.
- **A link is missing.** Its tab is hidden or its feature is off or its source isn't connected.
- **A number is missing.** Its source isn't connected or is off.
- **The feed has no Slack, Jira, Linear or email rows.** Inbox detection is off, or nothing arrived in the last 72 hours.
- **No meetings below NOW.** Calendar isn't connected or its tab is hidden, or the events are all-day, cancelled or declined.
- **"Couldn't read … — see the log."** A zone (Workbench, the links, or a feed source) says this when the local database couldn't be read. Quit and reopen the app; if it persists, check the app log.

A tab stays empty? See [A tab is empty](../troubleshooting/tab-is-empty.md).

## Related

[Workbench](workbench/README.md), [Catch Up](catch-up.md), [Briefings](briefings.md), [Inbox](inbox.md), [Day Plan](day-plan.md).

For developers: [docs/features/first-run.md](../../features/first-run.md)
