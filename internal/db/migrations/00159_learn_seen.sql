-- +goose Up
-- Home's Learn zone (docs/superpowers/specs/2026-10-19-home-zones-design.md
-- §9.6): one row per guide card the owner has seen, written once by the
-- Desktop; Show again deletes the row. how = Got it, the card's button, or
-- the feature already in use.
CREATE TABLE learn_seen (
    item_id TEXT PRIMARY KEY,
    how     TEXT NOT NULL CHECK (how IN ('got_it','action','in_use')),
    seen_at TEXT NOT NULL
);

-- +goose Down
DROP TABLE learn_seen;
