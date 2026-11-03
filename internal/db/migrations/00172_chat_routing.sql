-- +goose Up
ALTER TABLE chat_conversations ADD COLUMN routing_mode TEXT NOT NULL DEFAULT 'preferred_reserve' CHECK(routing_mode IN ('pinned','preferred_reserve'));
ALTER TABLE chat_conversations ADD COLUMN actual_provider TEXT NOT NULL DEFAULT '';
ALTER TABLE chat_conversations ADD COLUMN actual_model TEXT NOT NULL DEFAULT '';
ALTER TABLE chat_conversations ADD COLUMN routing_reason TEXT NOT NULL DEFAULT '';
UPDATE chat_conversations SET routing_mode = 'pinned';

-- +goose Down
ALTER TABLE chat_conversations DROP COLUMN routing_reason;
ALTER TABLE chat_conversations DROP COLUMN actual_model;
ALTER TABLE chat_conversations DROP COLUMN actual_provider;
ALTER TABLE chat_conversations DROP COLUMN routing_mode;
