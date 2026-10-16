# Automations: recipes and templates
A recipe is one Markdown file you can read in full. This page covers its parts and the five ready-made templates. How confirmation, budgets and runs work is on [Automations](automations.md).

## Why use it
A template gives you a working recipe to adapt instead of a blank page. Knowing the parts tells you what you are confirming.

## How it works
### The settings block
The top of the file holds the settings:
- **Trigger**, exactly one of: a `schedule` (five-field cron, local time), a `button` (with a label of 1 to 24 characters, and optionally `confirm`), or `manual: true` (only when you run it). The edit form calls the button option **When I press a button**; it draws no button anywhere. It only makes the recipe appear under its label in **Run Automation…** (**⌃⌘R**) and in the tray's **Run automation** submenu.
- **Permissions**, such as `gmail:read@work`, `jira:read@PAY`, `llm:light`, `llm:strong`, `tool:create_jira_issue`. Reading all Slack messages or all calendar events needs `slack:read@*` or `calendar:read@*`.
- **Outputs**, any of `inbox`, `briefing`, `report`, `target`, `slack`. Posting to Slack also needs `slack:write@<account>`.
- **Budget**: tokens (1,000 to 2,000,000) and minutes (1 to 60).
- Optionally, how many runs may overlap (1 to 4) and what to do about a missed slot.

Text outside the settings and the script is the description. The script is one block of plain, synchronous JavaScript. It can only use what Watchtower gives it: ask the assistant, read tools, a small saved state and the outputs.

### Where recipes live
Personal recipes sit in the `automations` folder inside Watchtower's workspace folder. The file name is the recipe's id: lower-case letters, digits and dashes. Shortcuts (symlinks) are never read; put the real file there.

### Workbench recipes
A recipe can also live in a Workbench folder, in `.watchtower/automations/`, where it may run a command. The app shows these read-only: no form editing and no **Change in words**.

## Using it
1. In **Automations**, click **Templates** (or **Browse templates** on an empty tab).
2. Pick a card and click **Use template**. The copy arrives unconfirmed and disabled.
3. If the card names a placeholder, such as the Jira project key, replace it in **Edit**.
4. **Dry run**, then **Review…**, then **Confirm and enable**.

### The templates
| Template | Where | When | What it does |
|---|---|---|---|
| `new-mail-summary` | personal | by hand | summarises new mail, at most 600 messages per mailbox per run |
| `jira-state-report` | personal | Mondays 09:00 | weekly Jira report to reports and the briefing; needs your project key |
| `team-performance-report` | personal | Fridays 17:00 | report from Jira, people cards and Slack |
| `pr-review-rounds` | workbench | weekdays 10:00 and 16:00 | lists open pull requests with `gh` |
| `release-buttons` | workbench | by hand | three recipes (release, deploy to test, deploy to stage), each running one `make` target and asking before it acts |

`new-mail-summary` is triggered by new-mail events, and nothing sends those events today, so it never starts by itself. Put your mailboxes' labels or addresses in `scheduledAccounts` in the script, then run it by hand, or change its trigger to a schedule.

## When it's empty or wrong
- **"No templates yet."** The command-line tool is older than the app; update Watchtower.
- **Install refused.** A recipe with that name already exists (a removed one counts), or a symlink is in the way. Nothing is left half-installed.
- **The form opens on a parse error.** The placeholder is still in the file; replace it.
- **A workbench template cannot be installed.** In the app the gallery installs personal templates only; the command line installs workbench ones with `--workbench`.

## Related
- [Automations](automations.md)

For developers: docs/features/automations.md
