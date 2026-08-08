-- +goose Up
CREATE INDEX IF NOT EXISTS idx_idea_mentions_ref ON idea_mentions(source, ref);

-- +goose Down
DROP INDEX IF EXISTS idx_idea_mentions_ref;
