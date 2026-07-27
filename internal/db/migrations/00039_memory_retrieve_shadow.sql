-- +goose Up
-- Secretary memory Phase-5 Slice B, Task 7: dark retrieval-compare telemetry
-- table, mirroring memory_digest_shadow's role for the digest-render compare
-- (see docs/superpowers/specs/2026-07-20-memory-slice-b-unified-retrieval-design.md
-- Section 6). Unlike memory_digest_shadow (keyed by channel/period, self-
-- overwriting), each row here is one point-in-time comparison of a live
-- surface call (memory_recall / briefing / meeting-prep) against the new
-- RankByImportance-based retrieval — an append-only audit trail, not a
-- snapshot, because the three surfaces are called ad hoc rather than on a
-- fixed per-window schedule. No FK onto memory_nodes: a shadow row is pure
-- telemetry that must survive independently of the compared node's later
-- eviction/deletion.
CREATE TABLE IF NOT EXISTS memory_retrieve_shadow (
    id                INTEGER PRIMARY KEY,
    surface           TEXT NOT NULL CHECK (surface IN ('recall','briefing','meeting_prep')),
    query_key         TEXT NOT NULL DEFAULT '', -- recall's query text / briefing's since-ts / meeting-prep's subject entity id
    old_result_json   TEXT NOT NULL,
    new_result_json   TEXT NOT NULL,
    diff_metrics_json TEXT NOT NULL,
    ts                TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_memory_retrieve_shadow_surface ON memory_retrieve_shadow(surface, ts);

-- +goose Down
DROP TABLE IF EXISTS memory_retrieve_shadow;
