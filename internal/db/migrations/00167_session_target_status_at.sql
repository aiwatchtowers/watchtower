-- +goose Up
-- Session progress scope (docs/superpowers/specs/2026-10-31-session-progress-scope-design.md):
-- status_at is the last time the session's agent changed the status of the target (or the owner
-- bound it); last_at also moves on comments. NULL = never a status write (a later comment link).
-- Existing rows start owning what they had touched: status_at = last_at.
ALTER TABLE terminal_session_targets ADD COLUMN status_at TEXT;
UPDATE terminal_session_targets SET status_at = last_at;

-- +goose Down
ALTER TABLE terminal_session_targets DROP COLUMN status_at;
