-- +goose Up
-- Watchman tuning §2 (#2140): the owner's instruction for a handed session or
-- target. Kept apart from watchman_arming so Take back (which deletes the
-- arming row) keeps the text and the next hand-over pre-fills it (D7).
-- Written only by `watchman arm --instructions-file` and `watchman instruct`.
CREATE TABLE IF NOT EXISTS watchman_instructions (
    scope      TEXT NOT NULL CHECK (scope IN ('session','target')),
    ref_id     INTEGER NOT NULL,          -- session or target id
    text       TEXT NOT NULL,             -- trimmed, at most 2000 runes
    updated_at TEXT NOT NULL,             -- RFC 3339 UTC
    PRIMARY KEY (scope, ref_id)
);

-- +goose Down
DROP TABLE IF EXISTS watchman_instructions;
