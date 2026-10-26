-- +goose NO TRANSACTION
-- +goose Up
-- Agent coach (docs/superpowers/specs/2026-10-26-agent-coach-design.md):
-- coach_proposals (one edit proposed to the owner's setup, with its outcome
-- verdict), prompt_additions (owner-accepted additions to a Watchtower
-- prompt), spec_reviews.findings (-1 = not counted, rows from before this
-- migration) and the Not useful mark on spec_review_marks. The CHECK change
-- rebuilds spec_review_marks in one transaction, as 00150 does.
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;

CREATE TABLE spec_review_marks_new (
    ask_id     INTEGER NOT NULL REFERENCES owner_asks(id) ON DELETE CASCADE,
    item_key   TEXT NOT NULL,
    state      TEXT NOT NULL CHECK (state IN ('ok','comment','viewed','not_useful')),
    body       TEXT NOT NULL DEFAULT '',
    about      TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL,
    PRIMARY KEY (ask_id, item_key)
);

INSERT INTO spec_review_marks_new (ask_id, item_key, state, body, about, updated_at)
    SELECT ask_id, item_key, state, body, about, updated_at FROM spec_review_marks;
DROP TABLE spec_review_marks;
ALTER TABLE spec_review_marks_new RENAME TO spec_review_marks;

ALTER TABLE spec_reviews ADD COLUMN findings INTEGER NOT NULL DEFAULT -1;

CREATE TABLE coach_proposals (
    id            INTEGER PRIMARY KEY,
    fingerprint   TEXT NOT NULL UNIQUE,
    kind          TEXT NOT NULL CHECK (kind IN ('add','cut','replace')),
    destination   TEXT NOT NULL CHECK (destination IN ('session','procedure','chat','prompt_addition','claude_settings_allow','claude_md_user')),
    workbench_id  INTEGER REFERENCES projects(id) ON DELETE CASCADE, -- NULL = global
    prompt_id     TEXT NOT NULL DEFAULT '',
    title         TEXT NOT NULL,
    why           TEXT NOT NULL,
    metric        TEXT NOT NULL CHECK (metric IN ('corrections','task_cost','owner_loop','review_findings')),
    before_text   TEXT NOT NULL DEFAULT '', -- the whole destination text before
    after_text    TEXT NOT NULL DEFAULT '', -- the whole destination text after
    evidence      TEXT NOT NULL DEFAULT '[]', -- JSON [{kind,ref}]
    sources       INTEGER NOT NULL,         -- distinct sources, recomputed in Go
    status        TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','accepted','declined','superseded','rolled_back')),
    reverts_id    INTEGER REFERENCES coach_proposals(id) ON DELETE SET NULL, -- a cut of an earlier no-effect edit
    created_at    TEXT NOT NULL,
    decided_at    TEXT NOT NULL DEFAULT '',
    baseline      REAL,
    baseline_n    INTEGER NOT NULL DEFAULT 0,
    verdict       TEXT NOT NULL DEFAULT '' CHECK (verdict IN ('','works','no_effect','too_little_data')),
    verdict_value REAL,
    verdict_at    TEXT NOT NULL DEFAULT ''
);

CREATE TABLE prompt_additions (
    id          INTEGER PRIMARY KEY,
    prompt_id   TEXT NOT NULL,
    text        TEXT NOT NULL,
    proposal_id INTEGER REFERENCES coach_proposals(id) ON DELETE SET NULL,
    created_at  TEXT NOT NULL
);
CREATE INDEX prompt_additions_prompt ON prompt_additions(prompt_id, id);

COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;

-- +goose Down
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;

CREATE TABLE spec_review_marks_new (
    ask_id     INTEGER NOT NULL REFERENCES owner_asks(id) ON DELETE CASCADE,
    item_key   TEXT NOT NULL,
    state      TEXT NOT NULL CHECK (state IN ('ok','comment','viewed')),
    body       TEXT NOT NULL DEFAULT '',
    about      TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL,
    PRIMARY KEY (ask_id, item_key)
);

INSERT INTO spec_review_marks_new (ask_id, item_key, state, body, about, updated_at)
    SELECT ask_id, item_key, state, body, about, updated_at FROM spec_review_marks WHERE state <> 'not_useful';
DROP TABLE spec_review_marks;
ALTER TABLE spec_review_marks_new RENAME TO spec_review_marks;

ALTER TABLE spec_reviews DROP COLUMN findings;
DROP TABLE prompt_additions;
DROP TABLE coach_proposals;

COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;
