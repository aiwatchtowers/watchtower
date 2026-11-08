-- +goose Up
-- Spec review threads (spec 2026-11-08 §3). Go is the only writer of both
-- tables; the Desktop only reads them.

-- A thread agent's question to the author of a review ask's session. Every
-- state change is a conditional update from 'open', so an answer and an
-- expiry cannot both land. thread is the thread's conversation key.
CREATE TABLE spec_review_questions (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    ask_id     INTEGER NOT NULL REFERENCES owner_asks(id) ON DELETE CASCADE,
    thread     TEXT NOT NULL,
    item_key   TEXT NOT NULL,
    question   TEXT NOT NULL,
    answer     TEXT NOT NULL DEFAULT '',
    state      TEXT NOT NULL DEFAULT 'open' CHECK (state IN ('open','answered','expired','gone')),
    created_at TEXT NOT NULL,
    closed_at  TEXT NOT NULL DEFAULT ''
);
-- At most one open question per thread.
CREATE UNIQUE INDEX idx_spec_review_questions_open ON spec_review_questions(thread) WHERE state = 'open';
CREATE INDEX idx_spec_review_questions_ask ON spec_review_questions(ask_id);

-- A finding the owner added to a review from a thread: kept apart from the
-- reviewer's result, so a re-run cannot erase it. finding is the JSON.
CREATE TABLE spec_review_thread_findings (
    ask_id     INTEGER NOT NULL REFERENCES owner_asks(id) ON DELETE CASCADE,
    item_key   TEXT NOT NULL,
    thread     TEXT NOT NULL,
    finding    TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (ask_id, item_key)
);

-- +goose Down
DROP TABLE IF EXISTS spec_review_thread_findings;
DROP INDEX IF EXISTS idx_spec_review_questions_ask;
DROP INDEX IF EXISTS idx_spec_review_questions_open;
DROP TABLE IF EXISTS spec_review_questions;
