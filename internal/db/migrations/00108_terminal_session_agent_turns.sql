-- +goose Up
-- Subagent and teammate turns of a workbench Claude Code session (board
-- #543): JSON {"since": <run mark>, "turns": {<agent_id>: {"start": <stamp>,
-- "stop": <stamp>}}} — per hook agent_id the last SubagentStart and
-- SubagentStop, agent_state_at format, each moving forward only. A turn is
-- open while start is later than stop; a stamp earlier than since (a late
-- hook of the previous run) writes nothing. Written by the workbench hooks
-- only, read by Go only (the background count); NULL = none. A new run
-- (which stores its mark as since) and a conversation switch clear the
-- turns, a main turn does not.
ALTER TABLE terminal_sessions ADD COLUMN agent_turns TEXT;

-- +goose Down
ALTER TABLE terminal_sessions DROP COLUMN agent_turns;
