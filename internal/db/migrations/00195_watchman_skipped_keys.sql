-- +goose Up
-- Watchman: decisions a source offered that the learner did not store (no
-- category), so a source's lookback does not offer them again.
CREATE TABLE IF NOT EXISTS watchman_skipped_keys (
    source     TEXT NOT NULL,
    source_key TEXT NOT NULL,
    skipped_at TEXT NOT NULL,
    PRIMARY KEY (source, source_key)
);

-- +goose Down
DROP TABLE IF EXISTS watchman_skipped_keys;
