-- +goose Up
-- Inbox builder A: an Inbox card may carry a block document and, for an
-- automation with living artifacts, a key it is upserted by. No CHECK
-- changes, so no table rebuild.
ALTER TABLE automation_outputs ADD COLUMN blocks_json TEXT NOT NULL DEFAULT '';
ALTER TABLE automation_outputs ADD COLUMN output_key TEXT;
ALTER TABLE automation_outputs ADD COLUMN content_hash TEXT NOT NULL DEFAULT '';
ALTER TABLE automation_outputs ADD COLUMN written_at TEXT;
ALTER TABLE automation_outputs ADD COLUMN changed_at TEXT;
UPDATE automation_outputs SET written_at = created_at, changed_at = created_at;
CREATE UNIQUE INDEX IF NOT EXISTS idx_automation_outputs_key ON automation_outputs(automation_id, output_key) WHERE output_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_automation_outputs_changed ON automation_outputs(kind, changed_at);

-- +goose Down
DROP INDEX IF EXISTS idx_automation_outputs_changed;
DROP INDEX IF EXISTS idx_automation_outputs_key;
ALTER TABLE automation_outputs DROP COLUMN changed_at;
ALTER TABLE automation_outputs DROP COLUMN written_at;
ALTER TABLE automation_outputs DROP COLUMN content_hash;
ALTER TABLE automation_outputs DROP COLUMN output_key;
ALTER TABLE automation_outputs DROP COLUMN blocks_json;
