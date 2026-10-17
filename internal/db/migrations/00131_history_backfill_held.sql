-- +goose Up
-- History backfill holds (#580): when a row's chunk is held by a transient
-- failure (offline, an AI or provider outage), held_since is when the hold
-- began and last_error says why. NULL = not held. A hold older than 7 days
-- counts as a strike, so a failure that never clears ends in a skip.
ALTER TABLE history_backfill ADD COLUMN held_since TEXT;

-- +goose Down
ALTER TABLE history_backfill DROP COLUMN held_since;
