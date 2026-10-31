-- +goose Up
-- The newest hub epoch a phone confirmed with an epoch_ack control (Go hub
-- plan 1a Task 10, relay sim rules 7a and 14): a counter, no content.
ALTER TABLE devices ADD COLUMN acked_epoch INTEGER NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE devices DROP COLUMN acked_epoch;
