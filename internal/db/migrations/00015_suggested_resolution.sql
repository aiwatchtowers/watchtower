-- +goose Up
-- The secretary's "looks resolved" mark (DASH-07): set by the composer's
-- suggest_resolve op when new material shows the story concluded without the
-- owner acting; cleared by a later merge without a re-suggest, or by the
-- user's "Keep open". Never closes the situation — status stays 'open'.
ALTER TABLE situations ADD COLUMN suggested_resolution TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE situations DROP COLUMN suggested_resolution;
