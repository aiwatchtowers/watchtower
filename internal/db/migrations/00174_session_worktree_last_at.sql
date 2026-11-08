-- +goose Up
-- The last run a terminal_session_worktrees pair was seen in (board #1018):
-- the session-state hook moves it to the event's time when the pair's last
-- sighting is older than the session's run mark, so a lane worktree a later
-- run reuses counts in that run (the Desktop's "N lanes"). agent_state_at
-- format; NULL = not seen again since first_at. first_at never changes.
ALTER TABLE terminal_session_worktrees ADD COLUMN last_at TEXT;

-- +goose Down
ALTER TABLE terminal_session_worktrees DROP COLUMN last_at;
