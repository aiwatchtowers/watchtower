# Automations: recipes and templates
A recipe is one Markdown file you can read in full. This page covers its parts and the five ready-made templates. How confirmation, budgets and runs work is on [Automations](automations.md).

## Why use it
A template gives you a working recipe to adapt instead of a blank page. Knowing the parts tells you what you are confirming.

## How it works
### The settings block
The top of the file holds the settings:
- **Trigger**, exactly one of: a `schedule` (five-field cron, local time), an `event` (see [Event triggers](#event-triggers)), a `button` (with a label of 1 to 24 characters, and optionally `confirm`), or `manual: true` (only when you run it). The edit form calls the button option **When I press a button**. It makes the recipe appear under its name in **Run Automation…** (**⌃⌘R**) and in the tray's **Run automation** submenu, and a workbench recipe also gets a button in its workbench's header; with `confirm` it asks before running.
- **Permissions**, such as `gmail:read@work`, `jira:read@PAY`, `llm:light`, `llm:strong`, `tool:create_jira_issue`. Reading all Slack messages or all calendar events needs `slack:read@*` or `calendar:read@*`.
- **Outputs**, any of `inbox`, `briefing`, `report`, `target`, `slack`. Posting to Slack also needs `slack:write@<account>`.
- **Budget**: tokens (1,000 to 2,000,000) and minutes (1 to 60).
- Optionally, how many runs may overlap (1 to 4) and what to do about a missed slot.

Text outside the settings and the script is the description. The script is one block of plain, synchronous JavaScript. It can only use what Watchtower gives it: ask the assistant, read tools, a small saved state and the outputs. BigInt numbers (`10n`) are not available; a recipe that uses one shows "BigInt is not available in automations" and does not run.

### Event triggers
An event trigger runs the recipe after a sync brings something new. For example, `trigger: {event: {type: slack.new_messages, where: {channel: releases}}}` runs after new messages land in #releases. The script finds what happened in `trigger.events`: ids, names and counts, never the text.

| Type | When | `where` keys |
|---|---|---|
| `slack.new_messages` | new messages in a channel, not counting your own | `account`, `channel`, `channel_id` |
| `gmail.new_messages` | a mailbox sync stored mail that arrived after you connected it (Gmail or IMAP) | `account`, `provider` |
| `jira.issue_changed` | an issue changed; `field` says which: `status`, `assignee`, `priority`, `comment` or `other` | `account`, `key`, `project`, `field` |
| `calendar.event_changed` | an event was created, updated or cancelled | `account`, `event_id`, `change` |
| `confluence.page_changed` | a page is new or has a new version | `space`, `page_id` |
| `slack.reaction_added` | you put an emoji on a Slack message | `account`, `channel_id`, `emoji` |

Every `where` key must match. A value matches regardless of case, either exactly or as a wildcard such as `PAY-*` (a `*` stops at `/`). Leave `where` out to match every event of the type. `where` only filters: the recipe still needs permissions for whatever it reads.

The reaction event carries the account, the channel id, the message timestamp (`message_ts`) and the emoji name without colons (`emoji: alarm_clock`), never the message. To read the message, the recipe needs `slack:read@*` or `tool:list_messages`. It fires for reactions made after the recipe first sees your account, never for older ones, and only once per message and emoji: removing and adding a reaction again does nothing. It needs **Reaction commands** on (Settings, Features). If Watchtower stops between noticing a reaction and starting the run, that reaction is lost, not replayed.

A recipe runs at most once per sync cycle, however many events it matched; it gets up to 100 events, and `trigger.truncated` is true when there were more. A source's first sync, its history backfill and your own Slack messages never fire a trigger. In **Edit**, **On an event** picks the type; write a `where` filter in the recipe text, or ask **Change in words**.

In the Automations list, an event recipe's line names its event and filter, then when it last ran ("no runs yet" before the first), or a running or failed run's state instead.

### Where recipes live
Personal recipes sit in the `automations` folder inside Watchtower's workspace folder. The file name is the recipe's id: lower-case letters, digits and dashes. Shortcuts (symlinks) are never read; put the real file there.

### Workbench recipes
A recipe can also live in a Workbench folder, in `.watchtower/automations/`, so it travels with the repository. There it can do what a personal one can't: run an exact command listed in its settings in the folder, open an agent session there, or ask you something. Its card says "workbench" where a personal one says "personal"; **Edit**, **Change in words** and confirming work the same, and the new version is saved in the workbench folder.

Because the file belongs to the repository, it can arrive with a `git pull` or be changed by someone else. Watchtower notices when you open the workbench, and as the file changes once the workbench's files have been shown. Such a recipe shows **Needs your confirmation** on its card and its header button, and does not run until you confirm it.

## Using it
1. In **Automations**, click **Templates** (or **Browse templates** on an empty tab).
2. Pick a card and click **Use template**. For a workbench template with several workbenches, pick the workbench from its menu. The copy arrives unconfirmed and disabled.
3. **Dry run**, then **Review…**, then **Confirm and enable**.

### The templates
| Template | Where | When | What it does |
|---|---|---|---|
| `new-mail-summary` | personal | after a mail sync brings new mail | summarises new mail, at most 600 messages per mailbox per run |
| `jira-state-report` | personal | Mondays 09:00 | weekly Jira report to reports and the briefing, on your active projects |
| `team-performance-report` | personal | Fridays 17:00 | report from Jira, people cards and Slack |
| `pr-review-rounds` | workbench | weekdays 10:00 and 16:00 | lists open pull requests with `gh` and opens a review session for each changed one, at most 10 per round; the rest wait for the next round |
| `release-buttons` | workbench | by hand | three recipes (release, deploy to test, deploy to stage), each running one `make` target and asking before it acts |

`new-mail-summary` runs on its own after a Gmail or IMAP sync brings new mail. A run by hand or on a schedule has no mail event, so first put your mailboxes' labels or addresses in `scheduledAccounts` in the script. Each mailbox picks up where its last run stopped, whether you name it by label or by address.

`jira-state-report` picks its projects when you install it: every synced Jira project with an open issue assigned to you or reported by you. The form that opens says which ("Covers: PAY, OPS"). Each project gets its own `jira:read@…` permission and an entry in the script's `projects` list; to add or drop one later, change both.

## When it's empty or wrong
- **"No templates yet."** The command-line tool is older than the app; update Watchtower.
- **Install refused.** A recipe with that name already exists (a removed one counts), or a symlink is in the way. Nothing is left half-installed.
- **The Jira state report won't install.** It needs a synced Jira project with an open issue assigned to you or reported by you. Connect Jira, let it sync, and try again.
- **The form says the recipe can't be read.** The file has an error, named next to it. The form's controls stay off so they never overwrite the file's settings; click **Open in editor** and fix the recipe there. The note turns to "The recipe reads now" once the fix parses; then save.
- **A workbench template's button is off.** You have no workbench yet; add one first.

## Related
- [Automations](automations.md)

For developers: [docs/features/automations.md](../../features/automations.md)
