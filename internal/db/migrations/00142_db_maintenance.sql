-- +goose Up
-- Database maintenance state for compaction at launch (board #850,
-- `watchtower db compact`). One row per key, the value as text:
--   last_compacted_version   highest applied goose version at the last
--                            successful compaction (integer as text)
--   compacted_at             time of the last successful compaction (RFC 3339 UTC)
--   compact_failures         consecutive failed compactions (integer as text);
--                            reset on success
--   compact_failures_version the app version that failed; the step is skipped
--                            after 3 failures until the version changes
-- Absent key = never compacted / no failures.
CREATE TABLE IF NOT EXISTS db_maintenance (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- +goose Down
DROP TABLE IF EXISTS db_maintenance;
