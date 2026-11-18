-- +goose Up
-- Background shells (a `run_in_background` Bash: a CI watch, a dev server) a
-- workbench Claude Code session left running when its turn ended (board
-- #1712). Claude Code wakes the agent when such a shell exits, so the session
-- is not stopped while one runs. Written by the workbench hooks and the
-- session probe only, beside agent_background (00106): set by the Stop
-- together with agent_background (which may then be 0), lowered by a
-- SubagentStop's snapshot, NULLed with it. NULL = none / unknown; stamped by
-- agent_background_at.
ALTER TABLE terminal_sessions ADD COLUMN agent_background_shells INTEGER
    CHECK (agent_background_shells IS NULL OR agent_background_shells >= 0);

-- +goose Down
ALTER TABLE terminal_sessions DROP COLUMN agent_background_shells;
