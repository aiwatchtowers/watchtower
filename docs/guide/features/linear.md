# Linear

Watchtower copies the issues of the Linear teams you pick onto your Mac, next to Jira's. They show in **Blockers** and in the weekly digest's progress, and the assistant can read and change them. It is for a team that lives in Linear, or in both trackers.

## Why use it

You see what is blocked or stale in Linear beside your Jira work, without opening Linear. The assistant answers from the same copy and drafts changes that wait for your Approve.

## How it works

- **Sync:** the background sync pulls the selected teams every 15 minutes (`linear.sync_interval_mins`). The first pass loads every open issue and everything updated in the last 90 days.
- **Blockers:** a Linear issue counts as *blocked* while another issue that is not done blocks it, and *stale* when it has been in progress for more than 7 days without a status-category change.
- **Weekly digest:** **Epic & Project Progress** lists Linear projects with 3 or more issues, and **Active Sprints & Cycles** shows the running cycles.
- **Identity:** a connected Linear workspace can identify you for the briefing and the day plan when no Slack, Google or Jira account does.
- **Automations:** a recipe reads or changes Linear with the permissions `linear:read@ENG` or `linear:write@ENG` (team keys). See [Automation recipes](automations-recipes.md).
- **API key:** a personal key never expires and is never refreshed. It acts with your own Linear permissions.

### Linear in the assistant

In **AI Chat** you can ask the assistant to list teams and issues, read an issue with its comments and status history, or change Linear: create an issue, add a comment, move an issue to another state, assign it, or edit its title, priority, labels, due date and estimate. Every change is a proposal: it waits in the chat's action card until you press Approve, and Linear changes only then. If you press Retry after a failed create, no second issue is made. The assistant can only choose a state, label or person that Linear knows for that team; a label that does not exist is refused, not created. Teams you did not select for sync have no states to choose from, so select the team first. Type `@` and an issue key to point the assistant at a Linear issue.

## Using it

1. Open **Settings** → **Connections** → **Linear** and press **Add Linear Workspace**. Setup's Linear card opens the same sheet.
2. Pick **Sign in with Linear** and approve in the browser, or pick **API key** and paste a key you created in Linear under Settings → Account → Security & access. Press **Connect**. While the browser sign-in runs, **Cancel** stops it.
3. Wait for the first sync, then tick the teams to sync under **Teams** in the same pane.
4. To pause a workspace, switch **Enabled** off; its synced issues stay. **Remove** disconnects it and keeps the synced issues too.

`watchtower linear add` (add `--api-key` to read a key from standard input) does the same from a terminal. Connecting switches `linear.enabled` on for you.

## When it's empty or wrong

- **A workspace shows no teams.** Its first sync has not finished; the list fills after it.
- **A workspace row shows Re-login.** Linear revoked the sign-in or rejected the key. Press **Re-login**: a browser workspace signs in again, an API-key workspace asks for a new key.
- **Blockers misses a Linear issue.** It needs an open "blocked by" relation in Linear; a label is not read.
- **Removing a workspace left the key working.** **Remove** cannot revoke a personal API key; delete it in Linear's settings.

## Related

- [Jira and Linear](jira-and-linear.md): the Jira tabs and how Blockers reads both trackers.
- [An account needs attention](../troubleshooting/account-needs-attention.md): signing in again.

For developers: [docs/features/linear.md](../../features/linear.md)
