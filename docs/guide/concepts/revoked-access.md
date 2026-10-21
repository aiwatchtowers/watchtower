# Revoked access deletes an account's data

When a company revokes your Slack, Google, Jira or Linear access, Watchtower can delete what it synced from that account, so a Mac you no longer work on for them stops holding their messages and mail. It is off unless you turn it on; the corporate build has it on. This page explains when it deletes, what it keeps and how to stop it.

## Why turn it on

Synced data stays in the database on your Mac for good. When you leave a company, they revoke your access, but the copy here keeps their correspondence. With this setting on, that copy deletes itself after a notice. A personal install loses a sign-in for harmless reasons too (Google revokes mail access when you change your password), so it is off by default there.

## How it works

Nothing is deleted without a notice of at least 72 hours, and reconnecting stops it.

- **Revoked access:** when a source rejects an account's sign-in, its data is scheduled for deletion 72 hours after Watchtower first sees the revocation. A sync that fails for another reason, such as no network, is not a revocation, and a sync that works again afterwards cancels it.
- **Not reached for 30 days:** when no account of a source (Slack, Google, Jira or Linear) has synced for 30 days, the data of each is scheduled, due 72 hours later (on a Mac that stays on, at the 30-day mark). Days offline count, but a Mac back after a long time away first tries to sync. A disabled account still counts, and one account syncing keeps all of them safe; for Jira, a Confluence sync counts too.
- **Removed accounts:** **Remove** keeps a Slack, Jira or Linear account's data. Once that account has not been reached for 30 days, its data is scheduled the same way, 72 hours out. Adding it back stops it. (Removing a Google account already deletes its mail and events.)

From the moment it is scheduled you see a red line under the account in **Settings → Connections**, a banner on [Home](../features/home.md) with **Reconnect**, and a macOS notification. A second notification says when the data is gone.

If the account is in error rather than revoked when the time comes, the deletion waits and its line says it is on hold. Once it starts, it runs in small steps over a few sync cycles and finishes even if you turn the setting off; **Re-login** is unavailable until then, and a `watchtower … login` in the terminal is refused with a message pointing to `watchtower accounts purges`. If it fails three times in a row, it stops: the line and a notification show the error, the account syncs again, and any new attempt comes with a new notice.

## Turning it on

1. Open **Settings → System**.
2. Under **Privacy**, turn on **Delete an account's data when its access is revoked**.
3. Press **Save**. The background sync restarts once to pick it up.

Turning it off cancels every scheduled deletion; one already running finishes. In `config.yaml` the key is `privacy.purge_revoked_data`.

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

You see **Data deleted** on the account's row in **Settings → Connections**, with a line saying when.

The account was revoked or not reached for 30 days while the setting was on, and nobody reconnected within the notice. Deleted data cannot be restored from Watchtower.

1. Press **Re-login** on the account and sign in.
2. Wait for the next sync cycles. The account syncs again from scratch: a short first sync, then [history backfill](history-backfill.md) for the last 30 days. Anything older is not fetched again.

For Linear, adding the same workspace again says it is already connected: use **Re-login** on its row instead.

## Related

- [Privacy](privacy.md)
- [Sources and accounts](sources-and-accounts.md)
- [An account needs attention](../troubleshooting/account-needs-attention.md)

For developers: [docs/features/revoke-purge.md](../../features/revoke-purge.md)
