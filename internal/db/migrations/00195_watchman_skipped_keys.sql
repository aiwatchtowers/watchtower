-- +goose Up
-- Watchman: decisions a source offered that the learner did not store (no
-- category), so a source's lookback does not offer them again.
CREATE TABLE IF NOT EXISTS watchman_skipped_keys (
    workbench_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    source       TEXT NOT NULL,
    source_key   TEXT NOT NULL,
    skipped_at   TEXT NOT NULL,
    PRIMARY KEY (workbench_id, source, source_key)
);

-- +goose Down
DROP TABLE IF EXISTS watchman_skipped_keys;
