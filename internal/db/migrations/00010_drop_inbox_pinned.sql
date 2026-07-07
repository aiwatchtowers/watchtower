-- +goose Up
-- The two-stage inbox pipeline (Task 7) replaced the single AI-prioritize call
-- and its dedicated pinned-selector call, so the pinned column and the
-- inbox.prioritize prompt are no longer used anywhere in Go.
DROP INDEX IF EXISTS idx_inbox_items_pinned;
ALTER TABLE inbox_items DROP COLUMN pinned;
DELETE FROM prompts WHERE id = 'inbox.prioritize';

-- +goose Down
ALTER TABLE inbox_items ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_inbox_items_pinned ON inbox_items(pinned) WHERE pinned = 1;
