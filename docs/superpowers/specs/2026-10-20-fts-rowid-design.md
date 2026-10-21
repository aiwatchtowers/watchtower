# Search indexes keyed by row — technical spec

Board #872 (group #527). Business spec: `2026-10-20-fts-rowid-business.md` (owner reviews that). Owner decisions: ask #362. Decisions and contracts only.

## Why

`messages_fts` (00001, schema.sql ~98-126), `transcripts_fts` (00052) and `memory_fts` (00017) are contentful FTS5 tables whose link to the source row is an UNINDEXED column (`channel_id`+`ts`, `transcript_id`, `id`). Every `DELETE FROM <fts> WHERE <unindexed col> = ?` — in the `messages_ai/au/ad` and `meeting_transcripts_*` triggers and in `internal/db/memory.go` (~135, 176, 509) — scans the whole index: O(n) per write, O(n²) per batch (sync pages of 100–200, tombstones of 200, `ClearSlackData`'s `DELETE FROM messages`). Evidence in the repo: `internal/digest/channel_window_test.go:541-545`, the #868 seed workaround in `internal/automations/templates_run_e2e_test.go`.

## Goals

- G1. Each index's rowid equals its source row's rowid; every trigger/Go write to the index addresses it by rowid (O(log n)).
- G2. Search results unchanged: same columns, `snippet()`, `rank`, readers' joins keep working (Go `internal/db/search.go`, Swift `SearchQueries.swift`, memory search `memory.go` ~509/532, transcripts search readers).
- G3. The one-time fill of the messages index runs outside goose (the Desktop kills `db migrate` at 30 s): in the launch step of #850, chunked, resumable, before the compaction; the daemon finishes it in the background if the launch step never runs it. Transcripts are small and backfill inside the migration.
- G4. memory_fts is OUT of scope (owner approved, ask #364): its body exists only in memory_fts and the vault (no body column in memory_nodes), memory_nodes' implicit rowid has already been rebuilt once (00018), and an empty index would zero link counts that feed importance scores and eviction. It is small, so its per-write scan is cheap; revisit if it grows.

## Non-goals

External-content FTS (`content=`): it needs the exact indexed values on delete and couples the index to WHEN-gate mirroring; contentful + rowid keeps today's columns and readers. Ranking/query changes. Readers' join rewrites (optional, not required — see D5).

## Decisions

### D1. Migration (one goose file, fast)

**messages_fts:**
1. `ALTER TABLE messages_fts RENAME TO messages_fts_legacy` (FTS5 supports it; shadow tables follow; triggers are NOT rewritten, so they must be dropped here).
2. Recreate `messages_fts` with today's columns, options and tokenizer (contentful; `channel_id`, `ts`, `user_id` UNINDEXED kept so readers are unchanged).
3. Drop `messages_ai/au/ad`; recreate keyed by rowid: `messages_ai` (same WHEN) `DELETE FROM messages_fts WHERE rowid = NEW.rowid` then `INSERT INTO messages_fts(rowid, text, channel_id, ts, user_id) VALUES (NEW.rowid, …)` (the delete-first guards against a constraint failure if rowids ever drift); `messages_ad` `DELETE … WHERE rowid = OLD.rowid`; `messages_au` (same WHEN) delete `OLD.rowid`, insert `NEW.rowid` under `NEW.text != '' AND NEW.is_deleted = 0`.
4. If `messages` has no indexable rows (fresh install) → `DROP TABLE messages_fts_legacy`, no pending key. Otherwise `INSERT OR REPLACE INTO db_maintenance(key, value) VALUES ('fts_rebuild_pending', '1')`.

**transcripts_fts:** recreate keyed by `meeting_transcripts.id` (INTEGER PRIMARY KEY — stable) and backfill in the migration itself (`INSERT INTO transcripts_fts(rowid, text, transcript_id, title) SELECT id, … FROM meeting_transcripts WHERE transcript_text != ''`, the 00052 precedent); new triggers keyed by `id`; no legacy table, no pending state.

Add the migration version to `compactAfterMigrations` only if the compaction should run after the fill drops the legacy table — the fill completion itself marks compaction due (D2), so no.

### D2. The messages fill (`internal/db`, e.g. `RebuildMessagesSearch(ctx, path, opts)`)

**The legacy index goes first** (amended 2026-10-20 by the whole-branch review): the first chunk drops `messages_fts_legacy` (the launch step, daemon stopped) or the daemon drains its shadow tables in short chunks and then drops it, and sets `fts_rebuild_pending` in the same transaction so a legacy table that was the only pending mark still leads to the fill. Only then do fill chunks run. The new index, about the legacy one's size, reuses the freed pages, so the file never holds both indexes; until the fill finishes search misses older messages either way (readers never read the legacy index).

Then chunks of 5,000 `messages` rows by ascending rowid, each one short write transaction: `INSERT INTO messages_fts(rowid, text, channel_id, ts, user_id) SELECT m.rowid, … FROM messages m WHERE m.rowid > :cursor AND m.text != '' AND m.is_deleted = 0 AND NOT EXISTS (SELECT 1 FROM messages_fts f WHERE f.rowid = m.rowid) ORDER BY m.rowid LIMIT 5000` (the `NOT EXISTS` skips rows a trigger indexed since the migration); cursor `fts_rebuild_cursor_messages` in `db_maintenance` updated in the same transaction. Interruptible between chunks (ctx); resumes from the cursor. Complete when the legacy table is gone and the cursor is at MAX(rowid): one transaction deletes the pending key and the cursor (and the launch fill's failure counter, D4). Completion makes the compaction due (the freed legacy pages trip the freelist rule; if not, record nothing that would mark a compaction done while the fill was pending).

### D3. Due rules and who runs the fill

- Own due check, independent of the compaction's 3-failure cap and 2× disk rule: due while `fts_rebuild_pending` is set. Disk rule for the fill: free space ≥ a fixed 64 MiB floor (`ftsRebuildMinFreeBytes`), headroom for WAL frames only — the legacy index is freed first (D2), so the new index needs no room of its own. (Was 1.5 × the legacy index's size, read through `dbstat`; a volume with less free space than that skipped forever, the daemon included, since each Slack sync moved `MAX(rowid)` past the cursor.)
- Launch step (Desktop): runs the fill first (D4), then the compaction if due.
- Daemon fallback: if pending, `phase…` runs the fill in the background with a per-cycle budget (e.g. 30 s), short chunk transactions — covers daemon-only installs and a skipped/failed launch step. Both paths are safe concurrently (cursor + `NOT EXISTS`; the launch step stops the daemon anyway).

### D3b. Rowid stability (new contract)

`messages.rowid` is now an index key (already a cursor key for kb `source_slack` and `linkscan`; VACUUM preservation pinned by `TestCompact_PreservesRowids`). Add an inventory entry (docs/inventory, db/search module): any migration that rebuilds `messages` copies `rowid` explicitly (`INSERT INTO new(rowid, …) SELECT rowid, …`), with a review-rules line; add a test that the delete-first insert trigger keeps the index consistent if a row is re-inserted under an existing rowid.

### D4. Launch step and CLI (#850 integration)

(Fill = messages only.)

- `db compact --check` reports `fts_rebuild_pending: true` and is due when it is set (reason `fts_rebuild`); `--if-due` runs the fill first, then the VACUUM, in one run; the JSON result gains `fts_rebuilt: bool` and `fts_skipped`/interrupt reporting through the existing `skipped:"interrupted"` path (exit 4, resumable). Keep exit codes 0–5 and the existing keys (Go pins them in `TestDBCompact_WireKeys`; extend that test).
- Desktop: the splash shows "Updating search index — m:ss" while the fill phase runs, then the existing "Optimizing database — size, m:ss". The CLI prints a phase line Swift can read (e.g. a JSON progress line per phase on stdout before the final result, or stderr — builder's choice; the final stdout line stays the result). Skip/kill/quit behaviour unchanged.
- The fill uses its own disk rule (D3); the compaction keeps its 2× rule.
- Launch fill failure cap: a fill error of `db compact` (not busy, not interrupted) is counted in `fts_rebuild_failures` under `fts_rebuild_failures_version` = the CLI version (a new version restarts it, the fill's completion clears it); never in `compact_failures`. At 3 the check stops reporting the fill as due: reason `fts_rebuild_gave_up`, `due: false`, `fts_rebuild_pending: true`, unless the freelist rule makes a compaction due (the migration rule waits for the fill, since its record does). `--if-due` then runs no fill; a manual `db compact` still fills, and the daemon keeps filling regardless.
- A manual `db compact` (no `--if-due`) reads only whether the fill is pending; a failing due check does not stop it.

### D5. Readers

Unchanged (they join on the kept columns). Transcript readers: Go `SearchTranscripts` only. Optional, cheaper: `m.rowid = fts.rowid` joins in Go `search.go` and Swift `SearchQueries.swift` (dual path — do both or neither).

## Tests that must exist

- Triggers: inserting/updating/tombstoning/deleting a message keeps exactly one FTS row per indexable message, addressed by rowid; a non-indexable row (empty text, deleted) has none. Same for transcripts.
- Write cost is O(log n): EXPLAIN QUERY PLAN on the trigger-equivalent delete shows the FTS5 rowid lookup (`VIRTUAL TABLE INDEX 0:=`) rather than a column filter (`INDEX 0:` full scan), plus a timing-free scale check (CPU-ratio of inserting 1k vs 10k rows into a pre-filled table, #871's pattern).
- Migration + fill on a seeded DB: `SearchMessages` and `SearchTranscripts` results identical before and after; legacy table dropped; pending key cleared. Fresh install: no legacy table, no pending key, golden schema without `*_legacy`.
- Daemon fallback fills a pending index across cycles; the gave_up cap of the compaction does not block the fill.
- Fill is resumable: interrupt after a chunk (seam), rerun → completes, no duplicates; rows inserted by triggers between chunks are not duplicated.
- CLI: `--check` due with reason `fts_rebuild`; `--if-due` runs fill then VACUUM; wire keys pinned; Swift step shows the fill phase then the compaction phase.
- The digest/automations tests no longer need their trigger workarounds (remove them where they were only for the quadratic cost, keeping what they test).
- schema.sql, golden, Swift test schema regenerated; `TestAllTablesExist`; drift check tolerates the transient `*_legacy` tables.

## Docs

Feature note update in `docs/features/db-compact.md` (fill phase) and `docs/features/knowledge-search.md` / memory notes where they describe these indexes; `docs/desktop-app.md` search section; user guide line for the launch screen's new phase.
