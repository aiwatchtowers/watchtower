# An account needs attention

A service in **Settings → Connections** shows a red dot, an account row has a **Re-login** button, or a row says it stopped syncing. One account failing never stops the others, so the rest of Watchtower keeps working on what it has.

## What you see

- A red dot on a service. It means at least one of its accounts has a problem. Hover the dot on an account row for the reason.
- A **Re-login** button (Slack, Google, Jira), or an orange dot for a revoked mail account.
- "Stopped syncing: this server uses no TLS …" on a mail account, or "… uses plain http …" on a CalDAV calendar.
- "Google Calendar for <name> can't sync" on the Calendar tab, with **Reconnect**.
- "Loading history paused — reconnect the account" in the menu bar.

## Why

The service revoked or expired the sign-in (a password change, an admin removing the app, a long idle period), or the server refused the connection. Watchtower keeps what it already synced and stops asking until you sign in again.

## Fix

1. **Slack:** on the account row press **Re-login**, then approve in the browser. A healthy row shows **Reconnect**, which also grants new permissions such as sending messages.
2. **Google and Jira:** press **Re-login** on the row and approve in the browser.
3. **Linear:** sign in again with `watchtower linear add` in a terminal.
4. **Email (IMAP, Outlook) and CalDAV or ICS:** these rows have no **Re-login**. Remove the account and add it again, using SSL or STARTTLS for mail and an https URL for CalDAV.
   **Known issue:** removing a Google, Email or Calendar account deletes the mail or events synced from it, though the dialog says they are kept. Before you remove one, make sure you can live without the old mail or events; adding the account again syncs recent mail and events from the server again, and older mail returns through [history backfill](../concepts/history-backfill.md). Slack and Jira keep their data. See [Known issues](known-issues.md).

## How to check

The dot turns green and the next sync cycle brings new data. The service dot stays red until every account under it is healthy.

## If it did not help

If it fails again at once, read the red error under the account list. A disabled Slack or Jira account (**Enabled** off) shows no problem and syncs nothing. Details on accounts are in [Sources and accounts](../concepts/sources-and-accounts.md).
