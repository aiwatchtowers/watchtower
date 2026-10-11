-- +goose Up
-- Subagent and teammate turns of a workbench Claude Code session (board
-- #543): a JSON object keyed by the hook's agent_id, each value
-- {"start": <stamp>, "stop": <stamp>} — the last SubagentStart and
-- SubagentStop, agent_state_at format, each moving forward only. A turn is
-- open while start is later than stop. Written by the workbench hooks only,
-- read by Go only (the background count); NULL = none. A new run and a
-- conversation switch clear it, a main turn does not.
ALTER TABLE terminal_sessions ADD COLUMN agent_turns TEXT;

-- +goose Down
ALTER TABLE terminal_sessions DROP COLUMN agent_turns;
