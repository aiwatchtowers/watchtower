-- +goose Up
-- The phone-recording job queue (Go hub plan 1b Task 5, spec §8 p. 4a): the
-- hub queues an upload it opened into the recordings dir; Desktop claims and
-- finishes it through `hub recording claim|finish`. Ids, a status, an error
-- class and timestamps only: no record name, no path (the audio path is
-- <recordings dir>/<upload_id>.m4a) and no error text.
CREATE TABLE recording_jobs (
    upload_id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('queued', 'claimed', 'done', 'failed')),
    transcript_id INTEGER,
    error_class TEXT,
    created_at REAL NOT NULL,
    claimed_at REAL,
    finished_at REAL
);

-- +goose Down
DROP TABLE recording_jobs;
