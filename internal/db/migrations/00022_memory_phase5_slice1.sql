-- +goose Up
-- Secretary memory Phase 5 slice-1, Task 3: the Gmail episode-extraction
-- watermark, the 5D interaction-ingest floor, and the memory_engagement
-- runtime side table. See
-- docs/superpowers/plans/2026-07-16-memory-phase5-slice1.md Task 3. All three
-- changes are additive ALTER TABLE ADD COLUMN / CREATE TABLE — no CHECK
-- constraint changes, so no table-recreation dance and no PRAGMA
-- foreign_keys toggling is needed here.

-- Gmail episode-extraction watermark: unix seconds of the newest gmail
-- thread message fully folded into an episode by the (memory.sources.gmail)
-- thread->episode extractor. Deliberately DISTINCT from the two watermarks it
-- sits beside: gmail_last_internal_date (the Gmail *sync* watermark — what is
-- pulled into gmail_messages, see 00016) and memory_last_extracted_ts (the
-- Slack episode-extraction watermark, see 00017). Three independent
-- watermarks (resolved ambiguity #7): the Gmail extractor's own watermark
-- advances only behind committed thread batches (MEM-04), never coupling to
-- either of the other two.
ALTER TABLE workspace ADD COLUMN memory_gmail_last_extracted_ts REAL NOT NULL DEFAULT 0;

-- 5D mechanical interaction-ingest floor: the highest owner-interaction row
-- id (inbox_feedback, primarily) already folded into episode-mirror outcome
-- annotations and memory_engagement aggregates by ingestInteractions
-- (memory.sources.actions). A workspace scalar like MemoryIngestFloor/
-- MemoryChatTurnFloor, so MEM-05 holds (memory only ever reads
-- inbox_feedback/situations/etc, never writes them or nudges
-- inbox_last_processed_ts).
ALTER TABLE workspace ADD COLUMN memory_last_interaction_id INTEGER NOT NULL DEFAULT 0;

-- Per-entity engagement aggregates (resolved ambiguity #3): the retention-
-- importance input that Phase-3's RetentionInputs/RetentionScore stubbed out.
-- A dedicated side table, not columns on memory_nodes and not
-- memory_node_stats (the access-stats counters stay write-dead in this
-- slice) — accumulated by the mechanical interaction-ingest step from
-- inbox_feedback/situation transitions/conversions, then read by eviction
-- scoring. Runtime state derived from interaction rows, MEM-02-exempt (like
-- memory_entity_hints, NOT like memory_node_stats): it must survive
-- DropMemoryIndex/reindex, because the interaction floor may already have
-- stepped past the rows that produced it — losing this table on a reindex
-- would silently and permanently erase accumulation a reindex has no way to
-- replay.
CREATE TABLE IF NOT EXISTS memory_engagement (
    node_id             TEXT PRIMARY KEY REFERENCES memory_nodes(id),
    engaged_count       INTEGER NOT NULL DEFAULT 0,
    dismissed_count     INTEGER NOT NULL DEFAULT 0,
    last_interaction_at TEXT NOT NULL DEFAULT ''
);

-- +goose Down
DROP TABLE IF EXISTS memory_engagement;
-- Precedent: 00017/00018/00019's Down drops their ALTER-added columns so a
-- down;up cycle is clean.
ALTER TABLE workspace DROP COLUMN memory_gmail_last_extracted_ts;
ALTER TABLE workspace DROP COLUMN memory_last_interaction_id;
