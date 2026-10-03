-- +goose Up
-- What a workbench claude session's agent is doing, reported by the Claude
-- Code hooks (`watchtower workbench session-state`, the Stop hook). Go is the
-- only writer; the Desktop reads both columns. agent_state_at is UTC with
-- milliseconds, fixed width, so string order is time order.
ALTER TABLE terminal_sessions ADD COLUMN agent_state TEXT CHECK (agent_state IN ('working','waiting','approval'));
ALTER TABLE terminal_sessions ADD COLUMN agent_state_at TEXT;

-- +goose Down
ALTER TABLE terminal_sessions DROP COLUMN agent_state_at;
ALTER TABLE terminal_sessions DROP COLUMN agent_state;
