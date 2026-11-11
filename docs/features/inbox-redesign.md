# Inbox redesign

## Phase 4 — mail closes on reply (Gmail)

Board #1076, ask #634 (2026-11-11). A Gmail `email_received` item resolves (`User replied`) once the owner replies in its thread, so mail behaves like Slack, Jira, Linear and calendar items (INBOX-02). Sent mail is ordinary mail: the sync stores it like any other message, and each reader of `gmail_messages` decides whether the owner's own rows count.

### Listing scope

- `internal/gmail/sync.go`: `listScope = "{in:inbox in:sent}"` is the query of both `Sync` (`after:<watermark>`, or `newer_than:<gmail.initial_history_days>d` on a first sync) and `FetchRange` (history backfill, `after:… before:…`). Noise labels (Promotions, Social) are skipped as before; the per-cycle cap, the oldest-first order and the watermark rules are unchanged, so sent rows ride the same watermark as received ones.
- `internal/gmail/client.go` `messagePermalink`: a message labelled `SENT` and not `INBOX` links to `#sent/<id>`, everything else to `#inbox/<id>`.
- The daily deletion diff (`deletions.go`) lists every message after the oldest stored one outside trash and spam, so sent rows are diffed like received ones (SRCDEL-01); the PURGE-02 gmail step deletes by `account_id` and takes them too.

### Sent catch-up

An account that synced before this release has its sent mail only from the release on. Migration 00188 adds `google_accounts.gmail_sent_catchup_at` (`''` = not yet, else RFC 3339 UTC).

- `Syncer.CatchUpSent(ctx, now)` (`internal/gmail/sent_catchup.go`) lists `in:sent after:<now − gmail.initial_history_days>` once per account and stores each message with its own date as `synced_at` (`backfillSyncedAt`), so the inbox detector never sees the rows as new. It writes no watermark and no auth state.
- No-op when the stamp is set, or when the account has not synced yet (watermark 0): a first `Sync` lists sent mail itself and stamps at its listing time.
- `phaseGmailSync` (`internal/daemon/daemon.go`) runs it after a successful `Sync`, outside `observePhase`, so catch-up rows are never `gmail.new_messages` events.
- Failures: a 404 on one message skips it; any other error stops the pass unstamped and the next cycle retries (a failed listing never counts). A transient error (Gmail 429/5xx and rate-limit 403 via `StatusError.Transient`, a network or `*url.Error`, a cancelled or expired context, `io.ErrUnexpectedEOF`, `ErrAuthRevoked`) retries without limit; after 3 passes in one process that failed with a non-transient error (`sentCatchUpMaxAttempts`) the pass stamps anyway and logs that it gave up.

### The owner-sent predicate

`db.GmailOwnSent(labelsJSON, fromEmail, accountEmail)` (`internal/db/gmail_sent.go`): the row's labels hold `"SENT"` (quoted, so a user label containing SENT never counts), or its sender equals the account's own address (trimmed, case-insensitive). A "Send mail as" alias carries `SENT`. `db.GmailOwnSentSQL(msg, acct)` is the SQL twin over a `gmail_messages` alias and its `google_accounts` alias; `TestGmailOwnSentSQL_MatchesGo` pins that both decide every case alike.

### Readers by side

The rule: a reader that treats a row as something that happened to the owner skips the owner's own sent rows; a reader that treats a row as knowledge keeps them. `TestInbox02_EveryGmailReaderHasASide` (`internal/inbox/gmail_readers_test.go`) pins every non-test Go file under `internal` and `cmd` that names `gmail_messages` to a side; a new file fails it until classified.

| Side | File | Readers |
|---|---|---|
| skip | `internal/inbox/gmail_detector.go` | `detectGmailAccount` (via `GmailMessagesSyncedAfter`): no item from the owner's own mail |
| skip | `internal/db/automation_event_sources.go` | `MailNewsFloor`, `CountMailAfter` (`gmail.new_messages`) |
| skip | `internal/memory/seed.go` | `seedGmailSenders` (correspondents) |
| answer | `internal/db/gmail_sent.go` | `GmailItemsAnsweredByOwner` (reads only the owner's sent rows) |
| keep | `internal/kb/source_mail.go` | `gmailSource.Changed/Keys/Build` |
| keep | `internal/kb/media.go` | media parent key lookup |
| keep | `internal/doclinks/linkscan/scan.go` | `gmailScanQuery` |
| keep | `internal/db/memory.go` | `GmailMessageSender`, `GmailMessageExists`, `ListGmailThreadsForExtract` (memory extraction and ideas email digests) |
| keep | `internal/memory/gmail_extract.go`, `internal/memory/provenance.go` | comments over the `internal/db/memory.go` readers |
| keep | `internal/db/emails_read.go` | `ListLocalEmails`, `GetLocalEmail` (`list_emails`/`get_email`, `sent` key) |
| keep | `internal/tools/emails.go` | `list_emails`/`get_email` tool texts naming the table (reads through `internal/db/emails_read.go`) |
| lifecycle | `internal/db/gmail.go` | `upsertGmailMessage` (writer), `GmailMessagesSyncedAfter` (detector feed), `GmailStoredIDs` + `DeleteGmailMessages` (SRCDEL), `ClearGmailData` |
| lifecycle | `internal/db/account_purge_steps.go` | PURGE-02 gmail step (`account_id = ?`) |
| lifecycle | `internal/db/google_accounts.go` | `DeleteGoogleAccount` cascade (comment) |
| lifecycle | `cmd/gmail.go` | clear confirmation row count |
| lifecycle | `cmd/google_legacy.go` | comment only |

`list_emails`/`get_email` mark the owner's own mail with the `sent` key (an IMAP row only when its sender is the mailbox's own address). Readers that reach the rows only through those tools are outside the guard's reach and are checked by hand: the `new-mail-summary` template and the `create-automation` skill's mail examples skip `sent` rows. The Gmail sync's media "owner first" flag uses `db.GmailOwnSent` too. Not readers of `gmail_messages`: track updates, people cards, the Desktop, Kit and phone (no Swift reads the table), the briefing, day plan and Catch-Up (they read `inbox_items` and `stream_digests`).

### The mail branch

`Pipeline.autoResolveGmail` (`internal/inbox/pipeline.go`) is the last check of `autoResolveByRules`, after Slack, Jira, Linear and Calendar. It resolves each id from `db.GmailItemsAnsweredByOwner` with `User replied`; errors are logged and never detector errors, and it never touches the inbox watermark (INBOX-09).

`GmailItemsAnsweredByOwner` reads every pending, unarchived `email_received` item whose `channel_id` parses as a Gmail one (`ParseGmailChannelID`; IMAP items are skipped), then the newest owner-sent `internal_date` in the same thread and account. Date rule: the item resolves when that reply is strictly after the received message's `internal_date` (the item's `message_ts`); when the received row is gone or its date does not parse, the item's `created_at` stands in, and an item with neither date is left alone. Dates are compared in Go as RFC 3339. `email_cc` items are not touched and still archive on their own.

### INBOX-02 amendment

`docs/inventory/inbox-pulse.md` INBOX-02 now covers Gmail mail (approved in ask #634) and names IMAP and Outlook as not covered. Guards: `TestInbox02_AutoResolveGmailOnOwnerReply` and `TestInbox02_EveryGmailReaderHasASide`.

### v1 limits

- IMAP and Outlook mail are not covered: no Sent folder sync and no thread headers, so those items archive on their own as before (14 days To, 7 days Cc).
- For an account connected before this release, sent mail older than the catch-up window (`gmail.initial_history_days`, 7 by default) is not fetched: the history backfill already done does not re-run.
- The ideas and memory floors do not re-mine the catch-up rows: they are dated in the past, below floors that already moved on.
- Any owner message in the thread newer than the received one closes the item: a forward or a note to a colleague in the same thread counts too.
- The sent catch-up is one pass per cycle with no per-pass cap and no resume: a pass cut by a cycle cancel restarts and re-fetches. A one-time cost, like `FetchRange`.
- Sent rows also feed the ideas email pre-digests (`ListGmailThreadsForExtract`), so ideas mining spends more AI on mail (owner decision 8: the owner's words are evidence).
- Installed copies of the "New mail summary" template made before this release still sum up sent mail: they are confirmed by hash (AUTO-06) and are not upgraded. Reinstall from the gallery to get the skip.
