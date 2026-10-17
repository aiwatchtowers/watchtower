-- +goose Up
-- Board #586: a channel-level (non-thread) Slack inbox item accumulates every
-- message folded into it instead of the newest overwriting the older ones.
-- JSON array of {"ts","sender","text","permalink"}, oldest first; '[]' for
-- thread items, other sources and rows written before this migration (the
-- first fold into such a row seeds the list from the row itself).
ALTER TABLE inbox_items ADD COLUMN mentions TEXT NOT NULL DEFAULT '[]';

-- +goose Down
ALTER TABLE inbox_items DROP COLUMN mentions;
