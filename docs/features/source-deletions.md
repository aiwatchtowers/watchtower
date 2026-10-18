# Source deletions and edits (2026-10-17, board #640)

A message, mail or comment deleted or edited at its source disappears or updates in Watchtower's raw tables, full-text search and the knowledge index. Design: `docs/superpowers/specs/2026-10-17-source-deletions-design.md`; plan: `docs/superpowers/plans/2026-10-17-source-deletions.md`. Contracts: SRCDEL-01..03 in `docs/inventory/source-deletions.md`.

## What each source detects, and when

| Source | Mechanism | Cadence |
|---|---|---|
| Slack | `search.messages` listing diffed against stored rows (`internal/sync/deletions.go`); a missing row becomes a tombstone | live window every cycle (UTC today up to now − 2 h, `liveDiffLag`), plus one stored past day per cycle (the sweep); both run only after a completed live search |
| Gmail | stored message IDs diffed against the account's full ID listing, all mail except trash and spam (`internal/gmail/deletions.go`); archived mail stays | once a day per account (`google_accounts.deletions_checked_at`); an incomplete listing leaves no stamp and retries next cycle |
| IMAP | UID diff against the synced folder, plus cleanup of rows stored under an old UIDVALIDITY (`reconcileDeletions` in `internal/imap/sync.go`) | every sync |
| Jira comments | an issue's comments are replaced by what the refetch returns (`internal/jira/sync.go`) | whenever the issue is refetched |
| Confluence | already reconciled by `extsync` (a deleted comment stamps its page's `children_changed_at`) | no change |

Slack sweep: `slack_accounts.deletion_sweep_day` is the per-account cursor. It walks from the newest stored day back to the oldest, then wraps. It advances after a finished day, a guard refusal or a skipped day, and holds on a rate limit or partial pages. The query is widened to about three days around the swept day (`sweepSearchRange`) so the UTC day is covered in any timezone, and `sweepMaxPages = 10` applies to that widened query. A bigger day is skipped and logged. The sweep also refreshes edited text.

## Tombstone shape and self-heal

A deleted Slack message is not removed. `db.TombstoneSlackMessages` sets `is_deleted = 1`, blanks `text`, sets `raw_json = '{}'`, and deletes its `reactions` and `files` rows. `ts`, `user_id` and `thread_ts` stay, so threads and ids still resolve. A later fetch that returns the message restores text and `is_deleted = 0` and the KB document gets the text back. Readers skip tombstones (`TestMessageReaders_SkipTombstones`); `GetOldestMessagesByTimeRange` deliberately keeps them, because the digest's considered-mark needs them.

`inbox_items` made from the message stay, but their text copies (`snippet`, `raw_text`, `context`, the message's entry in a channel item's mentions JSON) are blanked with the tombstone. Healing does NOT restore them. Other inbox items' `context` may still hold copies of the text.

## The shared guard

`internal/sourcediff.Check(stored, listed, missing, floors)` refuses a diff when the listing returned 0 of at least `EmptyMin` stored rows, or when more than half of at least `HalfMin` stored rows would go. `SlackFloors` = {5, 10}; `MailFloors` = {1, 1}. Every diff also needs a complete listing first: no API error, every page fetched, Slack matched >= `Total` (Slack caps `pages` at 100, so reaching the last page does not prove completeness), Jira reporting a complete listing (a missing `total` means incomplete). Every skip is logged with source, account, range and reason. Jira is the exception to `Check`: a complete comment listing may be empty and then removes all of the issue's stored comments.

The Slack live window is also clamped to what the forward query's `after:` date provably covers (`liveDiffWindow`), and a missing Slack row whose ts lies between one page's last match and the next page's first match is skipped and counted in the log: offset paging can skip a match there when the result set shifts mid-paging.

Slack candidates are narrowed so rows search cannot see are never judged: rows with a subtype, bot posts, rows with an empty author or an author with no `users` row, rows of other accounts, rows outside the range, and every channel the listing returned nothing from inside the range. The half-check counts only listed channels, so a small listed channel can lose more than half its rows in one cycle (bounded by the listed >= 1 gate). Gmail skips undated rows, and a store of only undated rows skips the listing.

## KB follow-through

Migration 00136 adds `kb_dirty(source, key, gen)` and AFTER triggers: `messages_kb_dirty` (text or `is_deleted` change; marks the thread or channel-day key, for both OLD and NEW), `gmail_messages_kb_dirty` (delete) and `jira_comments_kb_dirty` (delete). They write in the same statement as the change, so every writer is covered. The trigger key expressions and the Go key builders are a dual path pinned by `TestSRCDEL03_TriggerKeysMatchSourceKeys`. `drainDirty` (`internal/kb/dirty.go`) re-renders each marked document and deletes the mark only if its `gen` is unchanged (`TestDrainDirty_ReMarkDuringRenderSurvives`); a mark whose source document is gone is a delete. IMAP needs no mark (its KB key is one message and every non-Slack source reconciles each run). KB-01 was amended with this (see `docs/inventory/knowledge-search.md`).

## v1 limits

- The Slack live diff and the sweep run only after a completed live search; a rate-limited or incomplete search skips both for that cycle.
- A Slack day whose widened query needs more than 10 pages (about 1000 searchable messages, fewer for the day itself) is skipped by the sweep and logged; the live window is not capped.
- A message moved out of the synced IMAP folder, or out of a Slack channel the token can no longer search, counts as deleted. Losing access counts as deletion.
- AI-derived text (digests, memory, ideas, briefings) is left as is. Only raw rows, FTS and the KB follow the source.
- A Slack message that search never indexes keeps its row until a full sync heals it; a Slack bot post is never tombstoned.
- `BackfillSearch` passes no listing and never tombstones (`TestBackfillSearch_NeverTombstones`).
- A thread_ts-only change does not mark `kb_dirty`. A hard-deleted Slack document still waits for the daily KB reconcile.
- The sweep's 429 does not set `searchRateLimited`; a persistent DB error retries the same day.
- The live window starts no earlier than `after:` + 1 day at 12:00Z (the latest a profile-local day can start, UTC−12). When the machine's local date runs ahead of UTC (east of UTC, after local midnight), the early-UTC-day hours before that bound are left to the sweep.
- Gmail mail restored from trash (or spam) after the daily check removed it may not come back: the forward sync queries `in:inbox after:<watermark>` on the message date, and the history backfill covers each date window once, so a restored mail dated before the watermark is not re-fetched.

## Tests

`internal/sourcediff/guard_test.go`, `internal/sync/{deletions,deletions_sweep}_test.go`, `internal/db/{kb_dirty,slack_deletions}_test.go`, `internal/kb/dirty_test.go`, `internal/gmail/deletions_test.go`, `internal/imap/sync_test.go`, `internal/jira` (`TestSyncComments_*`).
