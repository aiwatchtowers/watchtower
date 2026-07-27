-- +goose Up
-- Secretary memory Phase 5 slice-3, Task 2: the memory_provenance
-- episode-window index and the memory_digest_shadow compare-telemetry
-- table. See
-- docs/superpowers/plans/2026-07-16-memory-phase5-slice3.md Task 2. Both
-- changes are additive CREATE TABLEs — no CHECK constraint change, no
-- table-recreation dance, no PRAGMA foreign_keys toggling needed here.

-- Derived index of each episode/rollup node's `## Provenance` refs
-- (`- <channel_id> <ts>` bullets) — there is today no indexed way to ask
-- "which episodes cover Slack channel C in window [t0,t1]?" without a full
-- vault body re-scan. Rebuildable from vault files (parsed from the same
-- body already passed to UpsertMemoryNode), so — unlike memory_engagement/
-- memory_entity_hints — it belongs INSIDE MEM-02's reindex-equivalence set
-- (Task 3 extends TestMemory02_ReindexEquivalence; owner-review flagged,
-- see docs/inventory/memory.md). scheme distinguishes non-Slack refs
-- (mail:/cal:/chat:/act:) from the bare Slack channel_id (scheme=''), so a
-- window query for a Slack channel naturally excludes them. Population
-- (write site) and DropMemoryIndex clearing land in Task 3 — this
-- migration only creates the shape.
CREATE TABLE IF NOT EXISTS memory_provenance (
    node_id     TEXT NOT NULL REFERENCES memory_nodes(id),
    scheme      TEXT NOT NULL DEFAULT '',
    channel_id  TEXT NOT NULL,
    ts_raw      TEXT NOT NULL,
    ts_unix     REAL NOT NULL,
    PRIMARY KEY (node_id, channel_id, ts_raw)
);
CREATE INDEX IF NOT EXISTS idx_memory_provenance_window ON memory_provenance(channel_id, ts_unix);

-- Dedicated memory-owned compare telemetry table for the dark
-- digest_compare render (memory.renders.digest_compare) — never the legacy
-- digests/digest_topics tables (MEM-05/MEM-14: memory never writes an
-- operational table). Keyed by (channel_id, period_from, period_to) so a
-- rerun over the same window self-overwrites via upsert. NOT a
-- memory_nodes child — a plain side table, never read by any UI; a pure
-- reader of digests/digest_topics/messages writes here and only here.
-- render_refs_rejected counts MEM-13 dropped-and-counted invented refs.
-- Not vault-derived, so DropMemoryIndex leaves it alone (harmless — see
-- Task 2 decision in the plan; rows are throwaway telemetry that
-- self-overwrites, and leaving them avoids losing a report's input
-- mid-validation).
CREATE TABLE IF NOT EXISTS memory_digest_shadow (
    id                   INTEGER PRIMARY KEY,
    channel_id           TEXT NOT NULL,
    period_from          REAL NOT NULL,
    period_to            REAL NOT NULL,
    legacy_digest_id     INTEGER NOT NULL DEFAULT 0,
    rendered_json        TEXT NOT NULL,
    coverage             REAL NOT NULL DEFAULT 0,
    render_refs_rejected INTEGER NOT NULL DEFAULT 0,
    model                TEXT NOT NULL DEFAULT '',
    created_at           TEXT NOT NULL,
    UNIQUE(channel_id, period_from, period_to)
);

-- +goose Down
DROP TABLE IF EXISTS memory_digest_shadow;
DROP TABLE IF EXISTS memory_provenance;
