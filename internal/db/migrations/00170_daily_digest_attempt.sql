-- +goose Up
-- Local completion receipt for one claimed scheduled daily window. It is not
-- part of the public Digest/wire model, and ordinary upserts preserve it.
ALTER TABLE digests ADD COLUMN daily_attempt_id TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE digests DROP COLUMN daily_attempt_id;
