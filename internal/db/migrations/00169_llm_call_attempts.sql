-- +goose Up
-- Link physical leaf rows without recording a synthetic wrapper call.
ALTER TABLE llm_calls ADD COLUMN operation_id TEXT NOT NULL DEFAULT '';
ALTER TABLE llm_calls ADD COLUMN attempt INTEGER NOT NULL DEFAULT 0;
ALTER TABLE llm_calls ADD COLUMN config_revision TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE llm_calls DROP COLUMN config_revision;
ALTER TABLE llm_calls DROP COLUMN attempt;
ALTER TABLE llm_calls DROP COLUMN operation_id;
