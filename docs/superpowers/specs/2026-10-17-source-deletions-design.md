# Source deletions and edits — design note (board #599)

Status: proposal for owner review. No code yet.

## Problem

When a message, email or comment is deleted at the source, by its author or by the company's retention policy, it stays in Watchtower's raw tables, `messages_fts` and the KB index for good. Edits reach us only if the item happens to be fetched again. That keeps content the company has already purged, which defeats its retention policy. The goal: deleted content leaves the raw row, FTS and KB within about a day, and edited content replaces the old text, using only the API budget we already have.

## Shared facts

- **FTS is already handled.** The `messages_au` trigger (`internal/db/migrations/00001_init.sql:106-112`) drops the FTS row when `is_deleted` goes to 1 or the text changes. Search (`internal/db/search.go:132`), memory refs (`internal/db/memory.go:632`), style samples and KB builds (`internal/kb/source_slack.go:35,41`) filter on `is_deleted = 0`, but not every reader does: `GetMessages`, `GetMessagesByTimeRange`, `GetOldestMessagesByTimeRange`, `GetThreadReplies` and `GetMessageNear` in `internal/db/messages.go` have no such predicate (they feed `tools/taskcontext.go`, `tools/experts.go`, `reactioncmd/pipeline.go`, `guide/pipeline.go`), so a tombstone would still be returned by them. Phase 1 adds the predicate to those readers.
- **KB has a gap for both deletions and edits.** Slack `Changed` only sees new rowids plus a 48 h `ts_unix` tail (`internal/kb/source_slack.go:97-125`, `slackTail` at line 18). Gmail and IMAP `Changed` use `updated_at`. The daily reconcile (`internal/kb/indexer.go:360-404`) removes a document only when its whole key is gone. So a thread or day document that loses one message older than 48 h, or has one edited, keeps the old text in the KB until something else rebuilds it. The same is true today for old edits.
- **AI-derived text** (digests, memory notes, ideas, briefings) is a summary, not a copy. Memory refs to a tombstoned message already fail closed through `MessageExists`.

## Per source

### Slack

**Current behaviour.** Every writer sets `IsDeleted: false`: `internal/sync/message_sync.go:413` and `internal/sync/search_sync.go:346`. The upsert overwrites `is_deleted` and `text` (`internal/db/messages.go:40-46,68-74`). The daemon's default path is `search.messages` with `after:<watermark − 2 days>` (`internal/sync/search_sync.go:44-75`, `orchestrator.go:355`), so a message edited within about 3 days is fetched again and its text updated. Nothing ever detects a deletion. `syncThread` (`thread_sync.go:13`) only upserts.

**API limits (checked on the 2025-05-29 Slack changelog and later reports).** For unlisted (non-Marketplace) commercial apps, `conversations.history` and `conversations.replies` are Tier 1: 1 request a minute and at most 15 objects per request. This has applied to new installs since 2025-05-29 and to existing installs since 2026-03-03, so it now applies to us. Internal customer-built apps keep 50+/min and 1000 objects. At 15 messages a minute, re-reading history to find deletions is out of the question. `search.messages` is Tier 2 (about 20 a minute, 100 results a page) and is unaffected. Neither API returns a deleted message. A deleted thread parent that has replies can come back as a `tombstone` subtype. Edited messages come back with their current text and an `edited` field.

**Detection.** Use search as a set listing, diffed against what we store.

1. **Live window, no extra calls.** When `searchAndSave` finishes with `completed == true`, every local row in the same account whose `ts` falls inside the fully covered window and was not seen is a deletion candidate. Only rows with `subtype = ''` qualify, because search does not index join/leave events.
2. **Rolling sweep, for old deletions and edits.** Each cycle, take one stored day D, from newest to oldest and wrapping around. Query `slackSearchRange(D, D+1)` (`search_sync.go:192`), upsert what comes back, which refreshes edits, and diff only the rows inside D. At the default 15-minute poll that is 96 days revisited per day, and a year of history in about 4 days. Cost is ceil(messages that day / 100) Tier-2 calls, typically 1-5 a cycle. It runs only when the live search was not rate-limited (`searchRateLimited`).

**Local action.** Turn the row into a tombstone in one transaction: `is_deleted = 1`, `text = ''`, `raw_json = '{}'`, and delete its reactions. The row itself (channel, ts, thread_ts, user) stays so thread structure and ids still resolve. FTS follows through the trigger. A wrong tombstone repairs itself: the next search that returns the message upserts `is_deleted = 0` and the text again.

**Risks and the one guard that is needed.** Search can come back partial or empty without an error (index lag, a dropped `search:read` scope, lost channel access). We already skip the diff when `completed` is false. On top of that, skip any day or window where search returned 0 hits while we hold 5 or more rows, or where the diff would tombstone more than half of 10 or more rows. Log the skip. Without this guard, a bad listing would silently blank whole days. Index lag affects only the newest hours, so the live-window diff leaves out the last 2 h.

### Gmail

**Current behaviour.** `in:inbox after:<watermark>` lists and then fetches new mail only (`internal/gmail/sync.go:72-78`). Nothing is ever removed from `gmail_messages`. Email bodies do not change, so edits do not apply.

**Detection.** The cheapest correct option is a once-a-day ID diff: `ListInboxMessageIDs(ctx, "after:<oldest stored> -in:trash -in:spam", 0)`. That is the same client with a wider query; `in:inbox` is dropped so that archived mail does not count as deleted. Any stored ID not listed is gone (trashed, purged, or removed by retention). Cost: 500 IDs per call at 5 quota units, so about 20 calls for 10k messages, once a day. `history.list` (`messagesDeleted`, TRASH label) is cheaper per cycle, but it needs a stored `historyId` per account and a full diff as a fallback when the 404 says the ID has expired. That is more machinery for the same result at a daily cadence.

**Local action.** Delete the row; nothing references email rows structurally. Guard: skip the diff when the listing returned 0 IDs while we store any, or when more than half would go.

### IMAP

**Current behaviour.** UID watermark plus `N:*` listing of new mail (`internal/imap/client.go:90`, `sync.go:146-255`). EXPUNGE is never seen. When UIDVALIDITY changes, the account resyncs (`sync.go:175`), but the rows under the old UIDVALIDITY are never deleted, which is a separate existing leak.

**Detection.** Each cycle, run `UID SEARCH ALL` on the synced folder: one command, about 6 bytes per UID. Diff it against stored UIDs for the current UIDVALIDITY. A message moved to another folder also looks deleted, because we sync only one folder.

**Local action.** Delete the missing rows. After a successful resync under a new UIDVALIDITY, delete every row under the old one. Same empty or over-half guard as Gmail.

### Jira comments (and issues)

**Current behaviour.** Comments are fetched in full for issues the `updated` JQL returns (`internal/jira/sync.go:602-648`) and upserted only. An empty list is skipped (`continue`, line 624), so even deleting an issue's last comment never lands. Jira issues are never marked `is_deleted = 1` in production code.

**Detection.** Deleting or editing a comment bumps the issue's `updated`, so the issue is already refetched. `GetIssueComments` pages to the end (`client.go:403-425`), so a successful fetch is the complete set.

**Local action.** In the same write, delete that issue's stored comments that are not in the fetched set, and treat an empty list as "no comments". Zero extra calls. A failed fetch changes nothing. The issue's `synced_at` bump already rebuilds the KB document (`internal/kb/source_work.go:20-22`). Deleted or moved issues need a daily key-only JQL diff per project. That is deferred to Phase 3.

### Confluence

Already reconciled once a day with a verification guard (`internal/extsync/reconcile.go:74-205`, `reconcile_guard.go`). Absent pages, attachments and comments are deleted. The KB drops documents whose key is gone. One thing to check during Phase 1: a page whose only change is a deleted comment should get its KB document rebuilt.

## KB follow-through (shared, needed by all of the above)

Add one small table, `kb_dirty(source, key)`. Any writer that tombstones, deletes or edits a row inserts the affected document key in the same transaction: the Slack thread or day key (`slackKeyFor`), the Gmail thread key, or the IMAP key. `kb.Run` drains the table first through the normal `Build`/`storeBatch`. A key with no live content builds to nil and is deleted; a key with content left is rebuilt without the removed text. This also fixes old edits that today never reach the KB. Without it, the deletion would remove the raw row and leave the content in the knowledge index.

## Recommendation and phased order

1. **Phase 1, highest value, no new API cost:** add `is_deleted = 0` to the message readers that lack it (`GetMessages`, `GetMessagesByTimeRange`, `GetOldestMessagesByTimeRange`, `GetThreadReplies`, `GetMessageNear` in `internal/db/messages.go`), `kb_dirty`, Jira comment set-replace, IMAP UID diff plus the old-UIDVALIDITY cleanup, and the Slack live-window diff with its guard.
2. **Phase 2:** the Slack rolling day sweep (old deletions, retention purges, old edits) and the Gmail daily ID diff.
3. **Phase 3, optional:** a Jira deleted-issue key diff, and an optional local "retention mirror" (purge Slack rows older than N days) if the owner wants a hard ceiling that does not depend on search.

Deliberately left out: `conversations.history` re-reads (Tier 1 makes them impractical), Gmail `history.list`, IMAP QRESYNC, and the Events API.

## Owner decisions needed

1. **Slack local action.** (a) A tombstone: keep ts, user and thread_ts, blank the text and raw_json. Self-healing, and threads keep working. Recommended. (b) Hard-delete the row: leaves no trace, but thread parents and memory refs break and the self-repair is lost.
2. **How far back the Slack sweep goes.** (a) All stored history, one day per cycle. Recommended. (b) Only the last N days, plus a local retention mirror that purges anything older than N. (c) The live window only, no sweep: old deletions and retention purges are never seen.
3. **AI-derived text.** (a) Leave digests, memory, ideas and briefings as they are; they are summaries, and refs already fail closed. Recommended. (b) Also regenerate or purge any digest or memory note whose source messages were deleted. This needs source tracking in every pipeline.
4. **What counts as deleted.** Should losing access (leaving a Slack channel, moving an IMAP message to another folder) purge local copies too? (a) Yes, treat it like a deletion. This is the simplest option and is what the diff does naturally. (b) No: this needs per-channel and per-folder exceptions in the diff.

Owner approved the note on 2026-10-17 (ask #324) with the recommended options: 1a, 2a, 3a, 4a.
