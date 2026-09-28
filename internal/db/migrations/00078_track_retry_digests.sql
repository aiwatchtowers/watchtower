-- +goose Up
-- Channel digests whose track-extraction batch failed in a run that still
-- counted as a success (at least one other batch stored tracks). The tracks
-- watermark is the start of the last 'done' run, so without this set a
-- failed batch's digests were never offered to track extraction again. Each
-- later run re-offers them alongside the new digests; a digest is dropped
-- once its batch has failed attempts times (3), so a batch that fails
-- deterministically is not re-sent forever. Rows go away with their digest.
CREATE TABLE IF NOT EXISTS track_retry_digests (
    digest_id  INTEGER PRIMARY KEY REFERENCES digests(id) ON DELETE CASCADE,
    attempts   INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- +goose Down
DROP TABLE IF EXISTS track_retry_digests;
