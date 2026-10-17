# Home

Home is the page Watchtower opens on. It shows what needs you right now and, on a new install, how far the setup has got. It also anchors the menu on the left, which is described at the end of this page.

## Why use it

You open the app after a meeting and want one answer: what is waiting for me? Home puts the recap you haven't read, your next meeting, pending approvals, today's briefing, your own targets and questions from coding agents in one column. Nothing here is built by Home itself, so there is nothing to wait for.

## How it works

Home only reads what the rest of the app has already produced, and refreshes about every 30 seconds. A Today card appears only when it has something to show, and only when its tab is visible: a card for Inbox, Calendar, Briefings or Catch Up disappears with that tab.

| Card | Shows | Opens |
|---|---|---|
| **SINCE YOU WERE AWAY** | The newest finished Catch Up recap you haven't marked caught up, with its TL;DR | Catch Up |
| **NEXT MEETING** | The next event starting within 24 hours: time, up to two attendees, "Prep ready" when prep exists | That event in Calendar |
| **WAITING ON YOU** | The three newest proposals, failed actions and due reminders, with the total | Inbox |
| **BRIEFING** | The first line of today's briefing | The briefing |
| **MY TARGETS** | Up to five of your own targets that are overdue, due today or in progress (never a Workbench board's) | The target |
| **AGENTS WAITING** | The three oldest questions and review requests from Claude Code or Codex sessions, with the workbench | That session |

With nothing to show, Today says "Nothing needs you right now." If a card can't be read it is skipped and the others still show. If none could be read, Today says "Couldn't read today's items — see the log."

### The Getting ready zone

On a new install a **Getting ready** zone sits above Today, one card per feature that is on and has its source. Each card carries the same status line as the feature's own empty tab, such as "Preparing now", "Starts after the first sync", "Within ~15 min" or "Today at 08:00". A finished feature shows **Ready** and **Open**.

While no account tells Watchtower who you are, the Inbox, Briefing and Day Plan cards say "Connect Slack, Google, Jira, Linear or an email account to get this" instead of a time, with **Open Connections**. A connected Jira site or Linear workspace that has not reported who you are yet shows "Waiting for your Jira identity…" (or Linear) instead. A bare IMAP login without an @ does not count as an address.

A source you haven't connected becomes one dashed row ("Connect Jira to get Boards, Workload, Blockers, Project Map and Releases") with a **Connect** button.

When every card is ready or has failed and retries on its own, the zone shrinks to "Everything's ready" for the rest of that launch and is gone on the next. It also folds by itself three days after it first showed, whatever is still waiting. An install that was already ready never sees it.

## Using it

- Click a card header to open its tab, or a row to open that item.
- Click **×** in the Getting ready header to hide the zone for good.
- When a tab you were on is turned off or its source is disconnected, you land on Home.

### The menu on the left

The menu lists Home, Targets, Tracks, Workbench, Automations and Calendar first. Below them are three collapsible sections:

- **FOCUS**: Catch Up, Briefings, Day Plan, Inbox, Ideas.
- **EXECUTION**: Project Map, Releases, Blockers, Workload.
- **INSIGHTS**: Digests, People, Memory, Statistics.

AI Chat and the TOOLS (Search, Boards, Usage, MCP Server) sit at the bottom. FOCUS starts open and the other two start folded; your own folds are remembered.

- **⌘B** folds the menu into a narrow icon rail and back. In the rail each section is one group icon that opens its tabs in place.
- Right-click a tab inside a section and choose **Hide**. It moves to that section's **HIDDEN** list, where **Show** brings it back.
- A tab appears only when its feature is on in Settings → Features and a source it needs is connected. For example Calendar needs a calendar, the Jira tabs need Jira, and Statistics needs Slack or mail.
- Until Slack, mail and Jira are all connected, a quiet **+ Connect …** line at the bottom names what is missing and opens Settings → Connections. Its **×** hides it for good. A connected calendar counts as mail here.
- Badges show what waits: unread briefings, proposals and due reminders in Inbox, ideas to review, one for a recap waiting for **I'm caught up**.

Home ends with the line "Stuck? Press **⌘/** to ask, or open the User Guide." It is always there, and **⌘/** opens the [assistant over this tab](ai-chat.md).

## When it's empty or wrong

- **No Getting ready zone.** It is shown only while something is still preparing or waiting for a source. It is also gone after three days, or after you hid it.
- **A tab is missing from the menu.** Turn its feature on in Settings → Features and connect its source. You may also have hidden it: look under **HIDDEN**.
- **A card is missing from Today.** It has nothing to show right now, or its feature is off or its source isn't connected.
- **"Couldn't read today's items — see the log."** The local database couldn't be read. Quit and reopen the app; if it persists, check the app log.

A tab stays empty? See [A tab is empty](../troubleshooting/tab-is-empty.md).

## Related

[Catch Up](catch-up.md), [Briefings](briefings.md), [Inbox](inbox.md), [Day Plan](day-plan.md).

For developers: [docs/features/first-run.md](../../features/first-run.md)
