-- +goose Up
-- Secretary memory index: rebuildable SQLite mirror of the markdown vault
-- (files + git are the source of truth — see docs/superpowers/specs/
-- 2026-07-15-secretary-memory-design.md). Dropping all memory_* tables and
-- reindexing must reproduce this index exactly (MEM-02).
CREATE TABLE IF NOT EXISTS memory_nodes (
    id            TEXT PRIMARY KEY,             -- ent_*/ep_*/sum_*/bel_*
    type          TEXT NOT NULL CHECK (type IN ('entity','episode','rollup','belief')),
    tier          TEXT NOT NULL CHECK (tier IN ('short','long')),
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed','tombstone')),
    redirect_to   TEXT,
    title         TEXT NOT NULL DEFAULT '',
    path          TEXT NOT NULL,                -- vault-relative file path
    content_hash  TEXT NOT NULL,                -- sha256 of file bytes at last index
    indexed_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS memory_aliases (
    alias    TEXT PRIMARY KEY COLLATE NOCASE,
    node_id  TEXT NOT NULL REFERENCES memory_nodes(id)
);

CREATE TABLE IF NOT EXISTS memory_node_stats (
    node_id          TEXT PRIMARY KEY REFERENCES memory_nodes(id),
    access_count     INTEGER NOT NULL DEFAULT 0,
    last_accessed_at TEXT
);

-- FTS5 index over node titles/bodies for memory_recall.
CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
    id UNINDEXED, title, body
);

-- Consolidation watermark: unix ts of the last raw message fully processed by
-- the episode extractor (MEM-04 freeze discipline, same as INBOX-09).
ALTER TABLE workspace ADD COLUMN memory_last_extracted_ts REAL NOT NULL DEFAULT 0;

-- Split cache token accounting on pipeline runs (cache reads and cache
-- creation are billed differently, so they are recorded separately).
ALTER TABLE pipeline_runs ADD COLUMN cache_read_tokens INTEGER NOT NULL DEFAULT 0;
ALTER TABLE pipeline_runs ADD COLUMN cache_creation_tokens INTEGER NOT NULL DEFAULT 0;

-- +goose Down
DROP TABLE IF EXISTS memory_fts;
DROP TABLE IF EXISTS memory_node_stats;
DROP TABLE IF EXISTS memory_aliases;
DROP TABLE IF EXISTS memory_nodes;
-- The ALTER-added columns (workspace.memory_last_extracted_ts,
-- pipeline_runs.cache_read_tokens, pipeline_runs.cache_creation_tokens) are
-- intentionally kept: SQLite's DROP COLUMN would require rewriting rows and
-- the zero defaults are harmless for older code.
