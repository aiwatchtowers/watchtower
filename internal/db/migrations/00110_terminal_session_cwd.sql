-- +goose Up
-- The working directory of a workbench Claude Code session's main agent
-- (board #565/#566): the input's cwd of the last main-thread hook (never a
-- subagent's or teammate's), absolute, with that event's time in
-- agent_state_at format. Written by the workbench hooks only (Go); it rides
-- in the state write's own UPDATE, or is written alone only when it changed
-- and its event is later. NULL = unknown. The run mark stores the new run's
-- cwd, the no-hooks clear removes it, a conversation switch keeps it. Read by
-- row id, no index.
ALTER TABLE terminal_sessions ADD COLUMN agent_cwd TEXT;
ALTER TABLE terminal_sessions ADD COLUMN agent_cwd_at TEXT;

-- +goose Down
ALTER TABLE terminal_sessions DROP COLUMN agent_cwd_at;
ALTER TABLE terminal_sessions DROP COLUMN agent_cwd;
