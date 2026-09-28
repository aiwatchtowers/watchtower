-- +goose Up
-- Channel digests whose track-extraction batch failed in a run that still
-- counted as a success (at least one other batch stored tracks). The tracks
-- watermark is the start of the last 'done' run, so without this set a
-- failed batch's digests were never offered to track extraction again. Each
-- later run re-offers them alongside the new digests; a digest is dropped
-- once its batch has failed attempts times (3), so a batch that fails
-- deterministically is not re-sent forever. A run in which EVERY batch failed
-- looks like an outage, so it charges an owed digest at most once per UTC day
-- (last_charged_day): each UTC day an outage touches costs one attempt, while a
-- digest that fails even alone still gives up within a few days. Owed digests
-- are batched apart from fresh ones, so a fresh batch's success charges a
-- failing owed digest in full. Rows go away with their digest.
CREATE TABLE IF NOT EXISTS track_retry_digests (
    digest_id  INTEGER PRIMARY KEY REFERENCES digests(id) ON DELETE CASCADE,
    attempts   INTEGER NOT NULL DEFAULT 0,
    last_charged_day TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- +goose Down
DROP TABLE IF EXISTS track_retry_digests;
