-- +goose Up
-- A session-applied call (claude_ai_connector_call, board #737) that failed
-- with "session ended while the call ran; outcome unknown" waits on the owner
-- (Inbox badge) until the owner dismisses it — after checking whether the call
-- ran (`watchtower actions dismiss`). The status stays `failed`.
-- Empty = not dismissed.
ALTER TABLE agent_actions ADD COLUMN dismissed_at TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE agent_actions DROP COLUMN dismissed_at;
