-- +goose Up
-- Custom-track scans (internal/customtracks) run on every daemon cycle and
-- route to the strong tier. A track whose AI reply never parses (or whose
-- events fail to insert) keeps its watermark, so without a budget the same
-- growing window went back to the strong model every ~15 minutes, forever.
-- Per-TRACK state, not a daemon-wide counter (the next_step_attempts
-- precedent, migration 00068): one perpetually-failing track must not
-- silence every other track's scan for the day.
--
-- scan_attempts counts FAILED scans on the UTC day of scan_attempted_at; a
-- successful scan (the watermark advancing) resets it to 0, and a new UTC day
-- starts a fresh budget. A shutdown mid-scan is never counted.
ALTER TABLE tracks ADD COLUMN scan_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE tracks ADD COLUMN scan_attempted_at TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE tracks DROP COLUMN scan_attempts;
ALTER TABLE tracks DROP COLUMN scan_attempted_at;
