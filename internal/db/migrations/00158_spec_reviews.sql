-- +goose Up
-- Spec review (docs/superpowers/specs/2026-10-25-spec-review-design.md §5):
-- owner_asks.doc_type is the kind of a review ask's document ('' for a
-- non-review ask, else spec|plan|other); spec_reviews holds one reviewer
-- agent run per review ask; spec_review_marks are the owner's per-item
-- marks (the Desktop writes them, Go only reads them for `show`); a
-- comment's about is the finding text, so a comment whose finding a
-- re-run drops still says what it was about.
ALTER TABLE owner_asks ADD COLUMN doc_type TEXT NOT NULL DEFAULT '';

CREATE TABLE spec_reviews (
    ask_id      INTEGER PRIMARY KEY REFERENCES owner_asks(id) ON DELETE CASCADE,
    status      TEXT NOT NULL CHECK (status IN ('queued','running','done','failed','skipped')),
    reason      TEXT NOT NULL DEFAULT '',
    result      TEXT NOT NULL DEFAULT '',
    provider    TEXT NOT NULL DEFAULT '',
    model       TEXT NOT NULL DEFAULT '',
    doc_sha     TEXT NOT NULL DEFAULT '',
    dropped     INTEGER NOT NULL DEFAULT 0,
    pid         INTEGER NOT NULL DEFAULT 0,
    attempt     INTEGER NOT NULL DEFAULT 0,
    queued_at   TEXT NOT NULL,
    started_at  TEXT NOT NULL DEFAULT '',
    finished_at TEXT NOT NULL DEFAULT ''
);

CREATE TABLE spec_review_marks (
    ask_id     INTEGER NOT NULL REFERENCES owner_asks(id) ON DELETE CASCADE,
    item_key   TEXT NOT NULL,
    state      TEXT NOT NULL CHECK (state IN ('ok','comment','viewed')),
    body       TEXT NOT NULL DEFAULT '',
    about      TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL,
    PRIMARY KEY (ask_id, item_key)
);

-- +goose Down
DROP TABLE spec_review_marks;
DROP TABLE spec_reviews;
ALTER TABLE owner_asks DROP COLUMN doc_type;
