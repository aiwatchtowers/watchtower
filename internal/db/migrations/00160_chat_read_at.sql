-- +goose Up
-- Chats panel (docs/superpowers/specs/2026-10-26-chats-panel-design.md §5.2):
-- when the owner last looked at the conversation; the Desktop is the only
-- writer. A conversation is unread while read_at < updated_at. Existing rows
-- start as read so nothing lights up on upgrade.
ALTER TABLE chat_conversations ADD COLUMN read_at REAL;
UPDATE chat_conversations SET read_at = updated_at;

-- +goose Down
ALTER TABLE chat_conversations DROP COLUMN read_at;
