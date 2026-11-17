# Revoked access deletes an account's data

When a company revokes your Slack, Google, Jira or Linear access, Watchtower deletes what it synced from that account, so a Mac you no longer work on for them stops holding their messages and mail. It is on by default. This page explains when it deletes, what it keeps and how to turn it off.

## Why it is on

Synced data would otherwise stay in the database on your Mac for good. When you leave a company, they revoke your access, but the copy here keeps their correspondence. With this setting on, that copy deletes itself after a notice, and a removed Slack workspace's data is gone well within the 14 business days Slack expects.

## How it works

Nothing is deleted without a notice of at least 72 hours, and reconnecting stops it.

- **Revoked access:** when a source rejects an account's sign-in, its data is scheduled for deletion 72 hours after Watchtower first sees the revocation. A sync that fails for another reason, such as no network, is not a revocation, and a sync that works again afterwards cancels it.
- **Not reached for 30 days:** only when you, your company's profile or the corporate build turned the setting on (not by default): when no account of a source (Slack, Google, Jira or Linear) has synced for 30 days, the data of each is scheduled, due 72 hours later (on a Mac that stays on, at the 30-day mark). Days offline count, but a Mac back after a long time away first tries to sync. A disabled account still counts, and one account syncing keeps all of them safe; for Jira, a Confluence sync counts too. A source your company's profile does not allow is never scheduled this way while the rule holds.
- **Removed accounts:** removing a Slack workspace also asks Slack to sign Watchtower out of it, so that sign-in stops working on every Mac that uses it. If Slack does not confirm, the remove still goes through and **Slack did not confirm the token was revoked; it may stay valid until a workspace admin removes the app** is printed. Its data is scheduled on Watchtower's next pass after the remove, due 72 hours from then. **Remove** keeps a Jira or Linear account's data until it has not been reached for 30 days, then schedules it the same way, 72 hours out. Adding it back stops it. (Removing a Google account already deletes its mail and events.)

From the moment it is scheduled you see a red line under the account in **Connections**, a banner on [Home](../features/home.md) with **Reconnect** until the deletion starts, and a macOS notification. A second notification says when the data is gone.

If the account is in error rather than revoked when the time comes, the deletion waits and its line says it is on hold. Once it starts, it runs in small steps over a few sync cycles and finishes even if you turn the setting off; **Re-login** is unavailable until then, and a `watchtower … login` in the terminal is refused with a message pointing to `watchtower accounts purges`. If it fails three times in a row, it stops: the line and a notification show the error, the account syncs again, and any new attempt comes with a new notice. If the deletion finishes but a check finds rows left, the line names the tables; a revoked or removed account then stays paused, with no new attempt, until you **Re-login** or add it back.

## Turning it on or off
<!-- learn
id: revoked-delete-data
title: Delete a revoked account's data
text: **Delete an account's data when its access ends** is on by default; it sits in **Settings → System**, under **Privacy**.
area: setup
level: power
kind: feature
since: 0.24.0
-->

The switch is on by default and says **On by default** until you change it.

1. Open **Settings → System**.
2. Under **Privacy**, turn **Delete an account's data when its access ends** on or off.
3. Press **Save**. The background sync restarts once to pick it up.

Turning it on yourself adds the 30-day rule for accounts that are not reached. Turning it off cancels every scheduled deletion; one already running finishes. With it off, synced data stays on this Mac after access ends, until you delete it with **Reset All Data…** in **Settings → System**. In `config.yaml` the key is `privacy.purge_revoked_data`.

If your company's configuration profile sets it, the switch shows **Managed by your organization** and cannot be changed; see [Managed by your organization](managed-by-your-organization.md).

To see every scheduled and finished deletion, run `watchtower accounts purges`. There is no command to delete sooner, and no button to keep the data: the way to keep it is to restore access.

## What is deleted and what is kept

Deleted, for that account only:

- **Slack:** its channels, messages, reactions, files and users; its channel digests; tracks and people cards that belong to that workspace alone.
- **Google:** its mail and mail digests; its calendar events, except events tied to a meeting recording or recap.
- **Jira:** its issues, comments, history, boards and sprints, its Jira digests, and the Confluence spaces synced through that Atlassian sign-in.
- **Linear:** its issues, comments, history, cycles and projects, and its digests.
- **Everywhere:** the account's inbox items and learned rules, its entries in the search index, and its sign-in files.

Kept: briefings, Catch Up recaps, ideas and decisions, memory notes, chats, automation outputs and meeting transcripts, which mix several sources. A digest or track that spans two accounts is kept too. IMAP and Outlook mail and CalDAV calendars are not covered.

## My data was deleted

You see **Data deleted** on the account's row in **Connections**, with a line saying when.

The account was revoked, removed or not reached for 30 days while the setting was on, and nobody reconnected within the notice. Deleted data cannot be restored from Watchtower.

1. Press **Re-login** on the account and sign in.
2. Wait for the next sync cycles. The account syncs again from scratch: a short first sync, then [history backfill](history-backfill.md) for the last 30 days. Anything older is not fetched again.

For Linear, adding the same workspace again says it is already connected: use **Re-login** on its row instead.

## Related

- [Privacy](privacy.md)
- [Sources and accounts](sources-and-accounts.md)
- [An account needs attention](../troubleshooting/account-needs-attention.md)

For developers: [docs/features/revoke-purge.md](../../features/revoke-purge.md)
