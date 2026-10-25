# Behavior Inventory — Source deletions

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/sourcediff/`, `internal/sync/deletions.go`,
> `internal/gmail/deletions.go`, `internal/imap/sync.go` (`reconcileDeletions`),
> the Jira comment sync, `internal/jira/deletions.go`, `internal/db/jira_deletions.go`
> or `internal/db/slack_deletions.go`, read this file first.
> Any proposed change that would break a guard test or remove a contract must be
> raised as a question before touching code.

**Module:** `internal/sourcediff/`, `internal/sync/deletions.go`, `internal/db/slack_deletions.go`, `internal/gmail/deletions.go`, `internal/imap/sync.go`, `internal/jira/sync.go` (comment set-replace), `internal/jira/deletions.go`, `internal/db/jira_deletions.go`, `internal/db/migrations/00139_source_deletions.sql`, `internal/kb/dirty.go`
**Last full audit:** 2026-10-17

## SRCDEL-01 — No deletion from a bad listing

**Status:** Enforced

**Observable:** Rows are removed because a source no longer lists them only when the listing is complete (no API error, every page fetched, Slack matches received >= reported total, Jira comment listing complete; Jira issue key listing complete: every page read up to `isLast`, every issue carrying a key) and `sourcediff.Check` accepts it. An empty listing over stored rows, or a removal of more than half, deletes nothing and is logged. A Jira issue is deleted only after `GET /issue/{key}` answers 404 or returns another key; an issue Jira still returns under the same key is kept. Exception: Jira comments do not go through `sourcediff.Check`. A complete Jira listing (a `total` present and every comment it counts received) may legitimately be empty, and it then removes all stored comments of that issue.

**Test guards:**
- Guard: `internal/sourcediff/guard_test.go::TestSRCDEL01_GuardRefusesBadListings`
- Supporting, per source - Slack: `internal/sync/deletions_test.go::TestLiveDiff_SkipsWhenListingEmpty`, `TestLiveDiff_SkipsOverHalf`, `TestLiveDiff_SkipsWhenTotalExceedsMatched`, `TestLiveDiff_SkipsIncompletePages`, `TestLiveDiff_LeavesRowsOutsideItsScope`
- Gmail: `internal/gmail/deletions_test.go::TestCheckDeletions_EmptyListingDeletesNothing`, `TestCheckDeletions_OverHalfDeletesNothing`, `TestCheckDeletions_ListErrorKeepsRowsAndRetries`
- IMAP: `internal/imap/sync_test.go::TestSync_EmptyMailboxDeletesNothing`, `TestSync_OverHalfGoneDeletesNothing`
- Jira: `internal/jira/sync_comments_test.go::TestSyncComments_IncompleteListingDeletesNothing`, `TestSyncComments_FetchErrorDeletesNothing`
- Jira issues: `internal/jira/deletions_test.go::TestCheckDeletedIssues_EmptyListingDeletesNothing`, `TestCheckDeletedIssues_OverHalfDeletesNothing`, `TestCheckDeletedIssues_IncompleteListingDeletesNothing`, `TestCheckDeletedIssues_StillPresentIsKept`

*Note (2026-10-25, images and links become knowledge, asks #576/#590/#594):* the image and link rows (`media_items`, migration 00156) of a parent removed by these diffs go with it in the same write (`ON DELETE CASCADE` from `gmail_messages`, `imap_messages`, `ext_documents`), so the bad-listing guard protects them too; no new deletion path. Supporting: `internal/kb/media_delete_test.go::TestSrcdel03_GmailDiffDeleteTakesMedia`, `TestSrcdel03_IMAPDiffDeleteTakesMedia`, `TestExtDeleteTakesMedia`.

**Why locked:** A diff trusting a truncated, empty or failed listing would delete real mail, messages and comments that still exist at the source, and the loss is silent and unrecoverable for everything but Slack.

**Locked since:** 2026-10-17

## SRCDEL-02 — A Slack deletion is a self-healing tombstone

**Status:** Enforced

**Observable:** A Slack message gone from search stays as a row with `ts`, `user_id` and `thread_ts` kept, `is_deleted = 1`, empty text, `raw_json = '{}'`, and no reactions, files or image and link descriptions (`media_items` rows, deleted in the tombstone's write since 2026-10-25). The next fetch that returns the message restores it, and its images and links are recorded again (described anew, or copied from an equal one in the account).

**Test guards:**
- Guard: `internal/sync/deletions_test.go::TestSRCDEL02_ReturningMessageHeals`
- Supporting: `internal/db/slack_deletions_test.go::TestTombstoneSlackMessages_BlanksRowAndChildren`
- `internal/sync/deletions_test.go::TestLiveDiff_TombstonesMissingRow`
- `internal/kb/dirty_test.go::TestDrainDirty_HealedMessageReturnsToIndex`
- Media (2026-10-25): `internal/db/slack_deletions_test.go::TestTombstoneSlackMessages_DeletesMediaRows`, `internal/kb/media_delete_test.go::TestSrcdel02_TombstoneDeletesMediaAndMarksParent`, `TestSrcdel02_TombstoneAfterPromotionLeavesNoDocument`, `internal/sync/media_test.go::TestUpsertMessagePage_TombstoneDropsMedia`

**Why locked:** A hard delete would break threads, ids and digests that point at the message, and a tombstone that cannot heal would make one wrong search result a permanent loss.

**Locked since:** 2026-10-17

## SRCDEL-03 — Every deletion and edit reaches the KB in the same write

**Status:** Enforced

**Observable:** A Slack text change or tombstone, a deleted Gmail message and a deleted Jira comment mark the affected KB documents in `kb_dirty` in the same write (source-table triggers). The indexer drains the marks, deleting a mark only if its `gen` is unchanged since it rendered. Since 2026-10-25 the same holds for image descriptions and link summaries: deleting an `ok` `media_items` row (by cascade or by the tombstone) marks its stored document, and so does a change to or from `ok` (migration 00156 triggers); a tombstone also marks the document the message renders into now, so a stale stored key after a thread promotion leaves nothing behind.

**Test guards:**
- Guard: `internal/kb/dirty_test.go::TestSRCDEL03_TriggerKeysMatchSourceKeys`
- Supporting: `internal/kb/dirty_test.go::TestDrainDirty_ReMarkDuringRenderSurvives`
- `internal/db/kb_dirty_test.go::TestKBDirty_SlackTextChangeMarksThreadAndDay`, `TestKBDirty_TombstoneMarks`, `TestKBDirty_GmailDeleteMarksThreadOrMessageKey`, `TestKBDirty_JiraCommentDeleteMarksIssue`
- Media (2026-10-25): `internal/db/media_test.go::TestMediaKBDirtyTriggers`, `TestMediaKBDirty_MovedRefMarksOldDocument`, `internal/kb/media_delete_test.go` (the cases above)

**Why locked:** Without the same-write mark, deleted or edited text stays searchable and quotable by the assistant until a rebuild, and a mark cleared against a newer gen drops a later change.

**Locked since:** 2026-10-17

## Changelog

- 2026-10-17: file created with 3 contracts (SRCDEL-01..03), introduced by source deletions (board #640, owner approval in ask #342 Q2).
- 2026-10-17: guards renamed into the `TestSRCDEL0N_` convention (rename only).
- 2026-10-21: SRCDEL-01 amended to cover deleted and moved Jira issues (board #674, owner approval in ask #476): complete key listing, per-key confirm before delete, new supporting tests; the guard is unchanged.
- 2026-10-25 (images and links become knowledge, board #907, **SRCDEL-01..03 extended, owner approved in asks #576, #590 and #594**): a parent's image and link rows (`media_items`) follow its deletion — SRCDEL-01 note (cascade under the same bad-listing guard), SRCDEL-02 (the tombstone deletes them; the next fetch records them again), SRCDEL-03 (their delete or status change marks the document in the same write). Supporting tests added as listed; no guard changed or relaxed.
