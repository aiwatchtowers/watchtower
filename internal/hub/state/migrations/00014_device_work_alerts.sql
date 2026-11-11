-- +goose Up
-- The phone's "When work stops" switch being off, from its device record
-- (protocol §5.5, work_alerts_off): the hub pushes it no relay alert. Written
-- only by the record's rewrite; a re-link starts it at 0 again.
ALTER TABLE devices ADD COLUMN work_alerts_off INTEGER NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE devices DROP COLUMN work_alerts_off;
