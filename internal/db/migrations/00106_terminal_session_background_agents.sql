-- +goose Up
-- Background subagents a workbench Claude Code session left running when its
-- turn ended (board #411). Written by the workbench hooks only; the Desktop
-- reads both columns. Meaningful only under agent_state = 'waiting'.
--
-- agent_background: in-flight background subagents at the last Stop of this
-- run, lowered by later reports; NULL = none / unknown.
-- agent_background_at: the last report about those subagents (the Stop, a
-- subagent's tool result, a SubagentStop), agent_state_at format; NULL when
-- agent_background is NULL.
ALTER TABLE terminal_sessions ADD COLUMN agent_background INTEGER
    CHECK (agent_background IS NULL OR agent_background >= 0);
ALTER TABLE terminal_sessions ADD COLUMN agent_background_at TEXT;

-- +goose Down
ALTER TABLE terminal_sessions DROP COLUMN agent_background_at;
ALTER TABLE terminal_sessions DROP COLUMN agent_background;
