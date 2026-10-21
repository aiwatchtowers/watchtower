# Behavior Inventory — Search indexes

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when writing a migration that rebuilds `messages` or
> `meeting_transcripts`, changing the `messages_fts`/`transcripts_fts`
> triggers, or adding a write to `messages`, read this file first. Any
> proposed change that would break a guard test or remove a contract must be
> raised as a question before touching code.

**Module:** `internal/db/migrations/00147_fts_rowid.sql`, `internal/db/fts_rebuild.go`, `internal/db/messages.go`, `internal/db/search.go`
**Last full audit:** 2026-10-20

## SEARCHIDX-01 — Search index rows are keyed by their source row's rowid

**Status:** Enforced

**Observable:** `messages_fts` and `transcripts_fts` rows are keyed by their source row's rowid (`messages.rowid`, `meeting_transcripts.id`), and the triggers find a row to replace or remove by that rowid. A migration that rebuilds `messages` copies `rowid` explicitly (`INSERT INTO new(rowid, …) SELECT rowid, …`). No code path writes `messages` with `INSERT OR REPLACE`/`REPLACE INTO`; upserts use `ON CONFLICT … DO UPDATE`, which keeps the rowid.

**Test guards:**
- Guard: `internal/db/search_indexes_contract_test.go::TestSearchIdx01_MigrationsKeepMessagesRowid`, `TestSearchIdx01_NoReplaceIntoMessages`
- Supporting: `internal/db/fts_rowid_test.go::TestMessagesFTS_TriggersKeepOneRowPerIndexableMessage`, `TestMessagesFTS_ReinsertUnderExistingRowidStaysConsistent`, `TestMessagesFTS_UpsertKeepsRowid`, `TestTranscriptsFTS_TriggersKeyedByID`, `TestFTSWrites_UseRowidLookup`, `TestMessagesFTS_WriteCostDoesNotGrowWithIndex`

**Why locked:** A rebuild that renumbers `messages`, or a REPLACE that gives a message a new rowid, leaves index rows pointing at the wrong message or at none: search returns other messages' text or misses edits and deletions, silently. Keying by a column instead makes every message write scan the whole index again (quadratic sync batches, hook writes past their lock budget).

**Locked since:** 2026-10-20

## Changelog

- 2026-10-20: file created with SEARCHIDX-01, introduced by the rowid-keyed search indexes (board #872, owner approval in ask #364).
