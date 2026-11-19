-- +goose Up
-- The morning journal reads the newest item below a night's start, one
-- lookup per night (`WatchmanJournalQueries.nights`): an index on created_at.
CREATE INDEX IF NOT EXISTS idx_watchman_items_created ON watchman_items(created_at);

-- +goose Down
DROP INDEX IF EXISTS idx_watchman_items_created;
