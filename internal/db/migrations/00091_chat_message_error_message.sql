-- +goose Up
-- The session's own error text for a failed assistant turn (status='error'),
-- next to error_code: the card shows it under the generic phrase, so a
-- fixable cause ("no Ollama model is configured…", a missing binary, the
-- attachment that was refused) is not lost. Swift is the only writer.
ALTER TABLE chat_messages ADD COLUMN error_message TEXT;

-- +goose Down
ALTER TABLE chat_messages DROP COLUMN error_message;
