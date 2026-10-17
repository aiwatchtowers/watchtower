# Behavior Inventory — Source deletions

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/sourcediff/`, `internal/sync/deletions.go`,
> `internal/gmail/deletions.go`, `internal/imap/sync.go` (`reconcileDeletions`),
> the Jira comment sync or `internal/db/slack_deletions.go`, read this file first.
> Any proposed change that would break a guard test or remove a contract must be
> raised as a question before touching code.

**Module:** `internal/sourcediff/`, `internal/sync/deletions.go`, `internal/db/slack_deletions.go`, `internal/gmail/deletions.go`, `internal/imap/sync.go`, `internal/jira/sync.go` (comment set-replace), `internal/db/migrations/00136_source_deletions.sql`, `internal/kb/dirty.go`
**Last full audit:** 2026-10-17

## SRCDEL-01 — No deletion from a bad listing

**Status:** Enforced

**Observable:** Rows are removed because a source no longer lists them only when the listing is complete (no API error, every page fetched, Slack matches received >= reported total, Jira comment listing complete) and `sourcediff.Check` accepts it. An empty listing over stored rows, or a removal of more than half, deletes nothing and is logged.

**Test guards:**
- Guard: `internal/sourcediff/guard_test.go::TestSRCDEL01_GuardRefusesBadListings`
- Supporting, per source - Slack: `internal/sync/deletions_test.go::TestLiveDiff_SkipsWhenListingEmpty`, `TestLiveDiff_SkipsOverHalf`, `TestLiveDiff_SkipsWhenTotalExceedsMatched`, `TestLiveDiff_SkipsIncompletePages`, `TestLiveDiff_LeavesRowsOutsideItsScope`
- Gmail: `internal/gmail/deletions_test.go::TestCheckDeletions_EmptyListingDeletesNothing`, `TestCheckDeletions_OverHalfDeletesNothing`, `TestCheckDeletions_ListErrorKeepsRowsAndRetries`
- IMAP: `internal/imap/sync_test.go::TestSync_EmptyMailboxDeletesNothing`, `TestSync_OverHalfGoneDeletesNothing`
- Jira: `internal/jira/sync_comments_test.go::TestSyncComments_IncompleteListingDeletesNothing`, `TestSyncComments_FetchErrorDeletesNothing`

**Why locked:** A diff trusting a truncated, empty or failed listing would delete real mail, messages and comments that still exist at the source, and the loss is silent and unrecoverable for everything but Slack.

**Locked since:** 2026-10-17

## SRCDEL-02 — A Slack deletion is a self-healing tombstone

**Status:** Enforced

**Observable:** A Slack message gone from search stays as a row with `ts`, `user_id` and `thread_ts` kept, `is_deleted = 1`, empty text, `raw_json = '{}'`, and no reactions or files. The next fetch that returns the message restores it.

**Test guards:**
- Guard: `internal/sync/deletions_test.go::TestSRCDEL02_ReturningMessageHeals`
- Supporting: `internal/db/slack_deletions_test.go::TestTombstoneSlackMessages_BlanksRowAndChildren`
- `internal/sync/deletions_test.go::TestLiveDiff_TombstonesMissingRow`
- `internal/kb/dirty_test.go::TestDrainDirty_HealedMessageReturnsToIndex`

**Why locked:** A hard delete would break threads, ids and digests that point at the message, and a tombstone that cannot heal would make one wrong search result a permanent loss.

**Locked since:** 2026-10-17

## SRCDEL-03 — Every deletion and edit reaches the KB in the same write

**Status:** Enforced

**Observable:** A Slack text change or tombstone, a deleted Gmail message and a deleted Jira comment mark the affected KB documents in `kb_dirty` in the same write (source-table triggers). The indexer drains the marks, deleting a mark only if its `gen` is unchanged since it rendered.

**Test guards:**
- Guard: `internal/kb/dirty_test.go::TestSRCDEL03_TriggerKeysMatchSourceKeys`
- Supporting: `internal/kb/dirty_test.go::TestDrainDirty_ReMarkDuringRenderSurvives`
- `internal/db/kb_dirty_test.go::TestKBDirty_SlackTextChangeMarksThreadAndDay`, `TestKBDirty_TombstoneMarks`, `TestKBDirty_GmailDeleteMarksThreadOrMessageKey`, `TestKBDirty_JiraCommentDeleteMarksIssue`

**Why locked:** Without the same-write mark, deleted or edited text stays searchable and quotable by the assistant until a rebuild, and a mark cleared against a newer gen drops a later change.

**Locked since:** 2026-10-17

## Changelog

- 2026-10-17: file created with 3 contracts (SRCDEL-01..03), introduced by source deletions (board #640, owner approval in ask #342 Q2).
- 2026-10-17: guards renamed into the `TestSRCDEL0N_` convention (rename only).
