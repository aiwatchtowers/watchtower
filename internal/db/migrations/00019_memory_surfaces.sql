-- +goose Up
-- Secretary memory Phase 4 surfaces, Task 1: belief index columns
-- (subject/confidence), the dispute-flag side table, and the owner-chat
-- ingest floor. See docs/superpowers/plans/2026-07-16-memory-phase4-surfaces.md
-- Task 1. All three changes are additive ALTER TABLE ADD COLUMN / CREATE
-- TABLE — no CHECK constraint changes, so no table-recreation dance and no
-- PRAGMA foreign_keys toggling is needed here.

-- memory_nodes.subject / .confidence mirror the belief-only frontmatter
-- fields (Node.Subject / Node.Confidence) into the index so the Swift
-- Discuss MEMORY block (Task 8) can join belief -> subject entity and render
-- confidence with a pure GRDB index read (no vault file parsing beyond
-- map.md). Both are FILE-DERIVED: Reconcile/upsertIndexNode populate them
-- identically from the parsed node on both the incremental and rebuilt
-- paths, so MEM-02 (TestMemory02_ReindexEquivalence) stays green with no
-- test change. '' / 0 for non-belief nodes.
ALTER TABLE memory_nodes ADD COLUMN subject TEXT NOT NULL DEFAULT '';
ALTER TABLE memory_nodes ADD COLUMN confidence REAL NOT NULL DEFAULT 0;

-- Dispute flags: a SIDE TABLE (per the plan's patched design), not a
-- memory_nodes column — the same memory_node_stats precedent (runtime
-- state, not derivable from vault files). Set by the belief pass / weekly
-- reflection (Tasks 4, 7) when a belief's evidence looks contested; read and
-- cleared, in the same transaction, by the inbox watchtower detector
-- (Task 6) when it mints the dispute trigger item — MEM-05 holds because the
-- memory package only ever writes this table, never inbox_items/situations.
-- Kept off memory_nodes so it is naturally EXCLUDED from the MEM-02
-- reindex-equivalence dump (like memory_node_stats), requiring no guard-test
-- edit at all. A full reindex does not touch this table (Reconcile/Rebuild
-- never write it), so resetting is not even a concern here — unlike a
-- dispute_pending column would have been.
CREATE TABLE IF NOT EXISTS memory_dispute_flags (
    node_id     TEXT PRIMARY KEY REFERENCES memory_nodes(id),
    flagged_at  TEXT NOT NULL,
    reason      TEXT NOT NULL DEFAULT ''
);

-- Owner-chat ingest floor: the highest chat_messages.id (a Swift-owned
-- table, absent until the Desktop app creates it) already folded by
-- ingestChatStatements (Task 4) into the belief pass, so a rerun does not
-- re-stage the same owner Discuss turns as evidence. A workspace scalar,
-- not a chat_* or inbox column, so MEM-05 holds (same shape as
-- memory_last_ingested_situation_id from 00018).
ALTER TABLE workspace ADD COLUMN memory_chat_turn_floor INTEGER NOT NULL DEFAULT 0;

-- +goose Down
DROP TABLE IF EXISTS memory_dispute_flags;
-- Precedent: 00017/00018's Down drops their ALTER-added columns so a
-- down;up cycle is clean.
ALTER TABLE memory_nodes DROP COLUMN subject;
ALTER TABLE memory_nodes DROP COLUMN confidence;
ALTER TABLE workspace DROP COLUMN memory_chat_turn_floor;
