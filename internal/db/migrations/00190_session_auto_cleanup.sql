-- +goose Up
-- Board #1716: every Desktop session delete cleans up in the background.
-- delete_requested_at marks a row whose delete the owner confirmed and whose
-- cleanup has not finished (the Desktop is its only writer; NULL = not
-- deleting).
ALTER TABLE terminal_sessions ADD COLUMN delete_requested_at TEXT;

-- +goose Down
ALTER TABLE terminal_sessions DROP COLUMN delete_requested_at;
