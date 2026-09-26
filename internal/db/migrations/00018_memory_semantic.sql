-- +goose NO TRANSACTION
-- +goose Up
-- Secretary memory semantic tier (Phase 3), Task 1: belief statuses, hint
-- recurrence table, ingest floor. See
-- docs/superpowers/specs/2026-07-15-memory-phase3-semantic-tier-design.md.

-- Expand memory_nodes.status CHECK from ('active','closed','tombstone') to
-- also allow the belief-only statuses 'shaken'/'retired'. SQLite has no
-- ALTER TABLE ... ADD CONSTRAINT, so recreate the table (create-new/
-- insert-select/drop/rename). memory_aliases.node_id and
-- memory_node_stats.node_id REFERENCE memory_nodes(id) WITHOUT ON DELETE
-- CASCADE, so under PRAGMA foreign_keys=ON (set unconditionally in db.go)
-- the DROP TABLE below would fail outright — NO ACTION still checks, at
-- statement time, that no child row references a row being deleted. Wrap
-- the dance in PRAGMA foreign_keys=OFF/ON (never defer_foreign_keys, which
-- only postpones dangling-reference validation and would not help here
-- since there is no cascade action to defer around) per the add-migration
-- skill's gotcha. PRAGMA foreign_keys cannot be toggled inside a
-- transaction, hence this file is marked NO TRANSACTION above.
-- memory_nodes carries no indexes beyond its PRIMARY KEY, so none to
-- recreate after the rename.
PRAGMA foreign_keys = OFF;

CREATE TABLE memory_nodes_new (
    id            TEXT PRIMARY KEY,             -- ent_*/ep_*/sum_*/bel_*
    type          TEXT NOT NULL CHECK (type IN ('entity','episode','rollup','belief')),
    tier          TEXT NOT NULL CHECK (tier IN ('short','long')),
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed','tombstone','shaken','retired')),
    redirect_to   TEXT,
    title         TEXT NOT NULL DEFAULT '',
    path          TEXT NOT NULL,                -- vault-relative file path
    content_hash  TEXT NOT NULL,                -- sha256 of file bytes at last index
    indexed_at    TEXT NOT NULL
);

INSERT INTO memory_nodes_new SELECT * FROM memory_nodes;

DROP TABLE memory_nodes;

ALTER TABLE memory_nodes_new RENAME TO memory_nodes;

PRAGMA foreign_keys = ON;

-- Persists unresolved extractor entity hints ("HSM", "phishing", free-text
-- concepts that cannot match natural-key-only aliases) for concept-entity
-- promotion once a hint recurs across enough distinct episodes
-- (COUNT(*) per hint). This is runtime accumulation like memory_node_stats
-- — NOT derivable from vault files, so it is excluded from the MEM-02
-- reindex-equivalence comparison. Unlike memory_node_stats it is
-- deliberately NOT cleared by DropMemoryIndex/Rebuild, so a reindex never
-- resets promotion progress (see docs/inventory/memory.md known-limitations).
CREATE TABLE IF NOT EXISTS memory_entity_hints (
    hint        TEXT NOT NULL,          -- normalized (lowercased, trimmed) hint text
    episode_id  TEXT NOT NULL,          -- the ep_* node that emitted it (distinct-episode counting)
    first_seen  TEXT NOT NULL,
    promoted_to TEXT NOT NULL DEFAULT '', -- ent_* once a concept entity was created; '' until then
    PRIMARY KEY (hint, episode_id)
);

-- Ingest floor: the highest situation id whose terminal (done|stale|
-- converted) scan has already been folded into the vault, so
-- listIngestSituations only rescans terminal situations with id > floor on
-- later runs (open situations are always scanned regardless of the floor).
-- A workspace scalar, not a situations column, so MEM-05 (no inbox/
-- situation writes from memory) holds.
ALTER TABLE workspace ADD COLUMN memory_last_ingested_situation_id INTEGER NOT NULL DEFAULT 0;

-- +goose Down
PRAGMA foreign_keys = OFF;

CREATE TABLE memory_nodes_old (
    id            TEXT PRIMARY KEY,
    type          TEXT NOT NULL CHECK (type IN ('entity','episode','rollup','belief')),
    tier          TEXT NOT NULL CHECK (tier IN ('short','long')),
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed','tombstone')),
    redirect_to   TEXT,
    title         TEXT NOT NULL DEFAULT '',
    path          TEXT NOT NULL,
    content_hash  TEXT NOT NULL,
    indexed_at    TEXT NOT NULL
);

-- Filter out belief-only statuses the old CHECK cannot hold (precedent:
-- other CHECK-narrowing Downs, e.g. 00016's trigger_type filter).
INSERT INTO memory_nodes_old SELECT * FROM memory_nodes WHERE status NOT IN ('shaken', 'retired');

DROP TABLE memory_nodes;

ALTER TABLE memory_nodes_old RENAME TO memory_nodes;

PRAGMA foreign_keys = ON;

DROP TABLE IF EXISTS memory_entity_hints;

-- Precedent: 00017's Down drops its ALTER-added columns.
ALTER TABLE workspace DROP COLUMN memory_last_ingested_situation_id;
