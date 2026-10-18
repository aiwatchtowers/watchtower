# Jira and Linear

Watchtower copies the Jira boards you pick onto your Mac and turns them into four overview tabs: **Project Map**, **Releases**, **Blockers** and **Workload**. It is for anyone who wants to see what is stuck, late or overloaded without opening Jira. Linear is connected and synced from the command line; no tab shows it.

## Why use it

Jira shows one board at a time. Here the same data is read across every connected site: which epics slip, which release is at risk, which issues have sat in progress for a week, and who carries too much. The same issues also feed the briefing, the inbox and the assistant's answers.

## How it works

The background sync pulls issues from the boards you selected every 15 minutes (`jira.sync_interval_mins`), one pass per connected Jira site. Nothing is written back to Jira from the tabs. The four tabs read the local copy, so they show what the last sync saw.

- **Blockers** lists two kinds of issue. *Blocked* means the status name contains "block" and the issue is not done. *Stale* means it is in progress and its status category has not changed for more than 7 days.
- **Workload** has one row per Jira assignee matched to a Slack user, by email first and then by a close name match, even when they have nothing open.
- **Workload** signals: **Overload** when someone has more than 2 late issues, more than 3 blocked or more than 15 open. **Watch** above 0 late, above 1 blocked or above 10 open. **Low** when they have nothing open (the command-line dashboard also requires fewer than 5 Slack messages).
- **Releases** shows fix versions that are not released and not archived, with an **At Risk** badge when more than 30% of the issues are blocked, or less than 7 days remain and under 80% is done.
- **Project Map** gives each epic a status of **On Track**, **At Risk** or **Behind**, from its velocity over recent weeks against its due date.

The **Jira Features** switches (role preset plus one switch per signal) decide which Jira signals show up in the briefing, people cards, the command-line dashboards and badges, and the "without Jira" check in digests. They do not hide the tabs, and they do not limit what the chat assistant can look up.

### Linear

- **Connect:** `watchtower linear add` signs in with Linear, then `watchtower linear teams` and `select` pick the teams. Connecting (or signing in again) switches `linear.enabled` on for you.
- **Sync:** the daemon syncs the selected teams every 15 minutes (`linear.sync_interval_mins`). The first pass loads every open issue and everything updated in the last 90 days.
- **What reads it:** the data is stored next to Jira's in a shared form, but no tab, briefing or inbox card reads it. Linear's one use is identifying you: a connected Linear workspace can identify you for the briefing and the day plan.

## Using it

1. Open **Settings** → **Connections** → **Jira**, press **Add Jira Site** and approve in the browser. Add a second site the same way. Setup's Jira card opens the same sheet. **Also connect Confluence** (ticked by default) makes the same sign-in cover Confluence for [knowledge search](search-and-knowledge.md); untick it for Jira only, or if Atlassian refuses the sign-in.
2. After the approval the sheet turns into **Choose Boards**: tick the boards you want synced and press **Done**. Only ticked boards sync. With Confluence connected, a line under the list names the spaces it selected for you. To change them later, open **Boards** in the sidebar, press **Refresh Boards** (**Fetch Boards** when the list is empty) and flip a board's switch.
3. Wait for the first sync. **Last sync** and **Issues synced** at the bottom of **Boards** show progress.
4. Open **Workload**. If people are missing, expand **User Mapping** on **Boards** and press **Resolve**, or use **Assign Slack user** on an unmatched row.
5. A board's row opens its profile. **Re-analyze** rebuilds the profile (workflow stages, estimation field) after the board's setup changed.
6. To change which Jira signals the briefing and people cards include, open **Jira Features** and pick a role, or flip single switches. **Reset to Role Defaults** undoes your changes.

An issue or epic key on any tab opens in Jira.

## When it's empty or wrong

- **A tab says Jira isn't connected.** The tab says "Connect Jira to get this". Press **Connect Jira**; it opens **Settings** → **Connections**.
- **A tab says "Choose Jira boards to get this".** Jira is connected but no board is picked, so nothing syncs. Press **Choose Jira boards**; it opens **Boards**, where you switch boards on.
- **Boards says "No boards yet".** Press **Fetch Boards**.
- **A tab says "No blockers yet", "No workload yet" or similar.** Jira is connected but no data has arrived. Check that a board is switched on in **Boards** and wait for a sync.
- **Workload is empty though Jira has issues.** No Jira user is matched to a Slack user. Connect Slack, then press **Resolve** in **User Mapping**.
- **A Jira site row shows a Re-login button.** Atlassian revoked the grant, so that site stops syncing until you press **Re-login** in **Settings** → **Connections** → **Jira**.
- **Blockers misses an issue you call blocked.** An issue is listed as blocked only when its status name contains "block"; a flag or label is not read. Issue links only build the chain shown under a listed issue.

Site needs **Re-login**? See [An account needs attention](../troubleshooting/account-needs-attention.md).

## Related

- [Search and knowledge](search-and-knowledge.md): Jira issues and comments are searchable by the assistant.

For developers: [docs/features/jira-multi-account.md](../../features/jira-multi-account.md), [docs/features/jira-changelog.md](../../features/jira-changelog.md), [docs/features/linear.md](../../features/linear.md)
