-- +goose Up
-- Session-applied rows (claude_ai_connector_call, board #737): the token of
-- the one chat-session process that proposed the row. Only that process may
-- claim, finish or cancel it — another process of the same conversation (a
-- respawn, a --resume, a replay) never runs a call it did not hold. Empty for
-- every other row.
ALTER TABLE agent_actions ADD COLUMN session_token TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE agent_actions DROP COLUMN session_token;
