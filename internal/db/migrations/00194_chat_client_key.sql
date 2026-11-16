-- +goose Up
-- Unified chat (#1822 T1): the client's id of a chat_turn request, stored on
-- the row the turn's start transaction inserts (the owner row; a
-- regenerate's new reply), so a send whose answer was lost to a dropped
-- connection is found by (conversation_id, client_key) and answered with the
-- turn it already started — also after a daemon restart. NULL for every row
-- written without one (the Desktop's own path, every row before this).
ALTER TABLE chat_messages ADD COLUMN client_key TEXT;
CREATE UNIQUE INDEX idx_chat_messages_client_key ON chat_messages(conversation_id, client_key) WHERE client_key IS NOT NULL;

-- +goose Down
DROP INDEX idx_chat_messages_client_key;
ALTER TABLE chat_messages DROP COLUMN client_key;
