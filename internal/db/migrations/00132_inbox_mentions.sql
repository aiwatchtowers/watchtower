-- +goose Up
-- Board #586: a channel-level (non-thread) Slack inbox item accumulates every
-- message folded into it instead of the newest overwriting the older ones.
--   mentions         JSON array of {"ts","sender","trigger","text","permalink"},
--                    oldest first, at most the 20 newest; '[]' for thread
--                    items, other sources and rows written before this
--                    migration (the first fold into such a row seeds the list
--                    from the row itself).
--   mentions_earlier how many older messages fell off the 20-entry list.
--   mentioned_at     when a fold last added a message ('' = never): Catch-Up
--                    gathers and acknowledges the item by
--                    MAX(created_at, mentioned_at).
ALTER TABLE inbox_items ADD COLUMN mentions TEXT NOT NULL DEFAULT '[]';
ALTER TABLE inbox_items ADD COLUMN mentions_earlier INTEGER NOT NULL DEFAULT 0;
ALTER TABLE inbox_items ADD COLUMN mentioned_at TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE inbox_items DROP COLUMN mentioned_at;
ALTER TABLE inbox_items DROP COLUMN mentions_earlier;
ALTER TABLE inbox_items DROP COLUMN mentions;
