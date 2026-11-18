-- +goose NO TRANSACTION
-- +goose Up
-- Watchman phase 2 (Task 7, fix round 1): every denial of the guard hook is
-- its own journal item, so it shows under Waiting for you on the night it
-- happened. Such an item has no wait point to point at: ref_kind gains
-- 'guard', its ref_id a number the writer takes from the guard items before
-- it (ParkWatchmanGuard). SQLite cannot change a CHECK in place: the table is
-- rebuilt with every row, its id and its AUTOINCREMENT high-water mark
-- (sqlite_sequence carry), and its indexes — 00198's two and 00200's
-- created_at index (IF NOT EXISTS: created here too should 00200 not have
-- run). Task 9 adds the outcome 'superseded' (an ask withdrawn or replaced
-- after the twin decided it). One transaction as one goose statement (see 00150); foreign keys are
-- OFF around it so the DROP fires no cascade (nothing references the table).
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;
CREATE TABLE watchman_items_new (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    workbench_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    session_id    INTEGER,
    target_id     INTEGER,
    kind          TEXT NOT NULL CHECK (kind IN ('ask','review_doc','check','handover','permission','review_code','guard')),
    ref_kind      TEXT NOT NULL CHECK (ref_kind IN ('ask','permission','session','round','guard')),
    ref_id        INTEGER NOT NULL,
    state         TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','deciding','done')),
    outcome       TEXT NOT NULL DEFAULT '' CHECK (outcome IN ('','answered','handed','parked','owner_first','approved','changes','superseded')),
    attempts      INTEGER NOT NULL DEFAULT 0,
    lease_until   TEXT,
    not_before    TEXT,
    question      TEXT NOT NULL DEFAULT '',  -- redacted, at most 2048 runes
    choice        TEXT NOT NULL DEFAULT '',
    rationale     TEXT NOT NULL DEFAULT '',
    precedent_ids TEXT NOT NULL DEFAULT '[]',  -- JSON array of watchman_precedents ids
    confidence    TEXT NOT NULL DEFAULT '',
    importance    TEXT NOT NULL DEFAULT '',
    category      TEXT NOT NULL DEFAULT '',
    unsure        INTEGER NOT NULL DEFAULT 1 CHECK (unsure IN (0, 1)),  -- every twin decision is journalled unsure (D43)
    park_reason   TEXT NOT NULL DEFAULT '',
    delivery      TEXT NOT NULL DEFAULT '',
    round_id      INTEGER,
    cost_usd      REAL NOT NULL DEFAULT 0,
    error         TEXT NOT NULL DEFAULT '',
    created_at    TEXT NOT NULL,
    decided_at    TEXT,
    feedback      TEXT NOT NULL DEFAULT '' CHECK (feedback IN ('','ok','corrected')),  -- written by the Desktop only
    feedback_text TEXT NOT NULL DEFAULT '',
    feedback_at   TEXT,
    check_done_at TEXT,
    UNIQUE (ref_kind, ref_id, kind)
);
INSERT INTO watchman_items_new (id, workbench_id, session_id, target_id, kind, ref_kind, ref_id, state, outcome, attempts, lease_until, not_before, question, choice, rationale, precedent_ids, confidence, importance, category, unsure, park_reason, delivery, round_id, cost_usd, error, created_at, decided_at, feedback, feedback_text, feedback_at, check_done_at)
    SELECT id, workbench_id, session_id, target_id, kind, ref_kind, ref_id, state, outcome, attempts, lease_until, not_before, question, choice, rationale, precedent_ids, confidence, importance, category, unsure, park_reason, delivery, round_id, cost_usd, error, created_at, decided_at, feedback, feedback_text, feedback_at, check_done_at FROM watchman_items;
DELETE FROM sqlite_sequence WHERE name = 'watchman_items_new';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'watchman_items_new', seq FROM sqlite_sequence WHERE name = 'watchman_items';
DROP TABLE watchman_items;
ALTER TABLE watchman_items_new RENAME TO watchman_items;
CREATE INDEX IF NOT EXISTS idx_watchman_items_queue ON watchman_items(state, not_before);
CREATE INDEX IF NOT EXISTS idx_watchman_items_wb ON watchman_items(workbench_id, created_at);
CREATE INDEX IF NOT EXISTS idx_watchman_items_created ON watchman_items(created_at);
COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;

-- +goose Down
-- The guard's own items cannot live in the old table: they go; a
-- superseded item reads as owner_first there.
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;
DELETE FROM watchman_items WHERE ref_kind = 'guard';
UPDATE watchman_items SET outcome = 'owner_first' WHERE outcome = 'superseded';
CREATE TABLE watchman_items_new (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    workbench_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    session_id    INTEGER,
    target_id     INTEGER,
    kind          TEXT NOT NULL CHECK (kind IN ('ask','review_doc','check','handover','permission','review_code','guard')),
    ref_kind      TEXT NOT NULL CHECK (ref_kind IN ('ask','permission','session','round')),
    ref_id        INTEGER NOT NULL,
    state         TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','deciding','done')),
    outcome       TEXT NOT NULL DEFAULT '' CHECK (outcome IN ('','answered','handed','parked','owner_first','approved','changes')),
    attempts      INTEGER NOT NULL DEFAULT 0,
    lease_until   TEXT,
    not_before    TEXT,
    question      TEXT NOT NULL DEFAULT '',  -- redacted, at most 2048 runes
    choice        TEXT NOT NULL DEFAULT '',
    rationale     TEXT NOT NULL DEFAULT '',
    precedent_ids TEXT NOT NULL DEFAULT '[]',  -- JSON array of watchman_precedents ids
    confidence    TEXT NOT NULL DEFAULT '',
    importance    TEXT NOT NULL DEFAULT '',
    category      TEXT NOT NULL DEFAULT '',
    unsure        INTEGER NOT NULL DEFAULT 1 CHECK (unsure IN (0, 1)),  -- every twin decision is journalled unsure (D43)
    park_reason   TEXT NOT NULL DEFAULT '',
    delivery      TEXT NOT NULL DEFAULT '',
    round_id      INTEGER,
    cost_usd      REAL NOT NULL DEFAULT 0,
    error         TEXT NOT NULL DEFAULT '',
    created_at    TEXT NOT NULL,
    decided_at    TEXT,
    feedback      TEXT NOT NULL DEFAULT '' CHECK (feedback IN ('','ok','corrected')),  -- written by the Desktop only
    feedback_text TEXT NOT NULL DEFAULT '',
    feedback_at   TEXT,
    check_done_at TEXT,
    UNIQUE (ref_kind, ref_id, kind)
);
INSERT INTO watchman_items_new (id, workbench_id, session_id, target_id, kind, ref_kind, ref_id, state, outcome, attempts, lease_until, not_before, question, choice, rationale, precedent_ids, confidence, importance, category, unsure, park_reason, delivery, round_id, cost_usd, error, created_at, decided_at, feedback, feedback_text, feedback_at, check_done_at)
    SELECT id, workbench_id, session_id, target_id, kind, ref_kind, ref_id, state, outcome, attempts, lease_until, not_before, question, choice, rationale, precedent_ids, confidence, importance, category, unsure, park_reason, delivery, round_id, cost_usd, error, created_at, decided_at, feedback, feedback_text, feedback_at, check_done_at FROM watchman_items;
DELETE FROM sqlite_sequence WHERE name = 'watchman_items_new';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'watchman_items_new', seq FROM sqlite_sequence WHERE name = 'watchman_items';
DROP TABLE watchman_items;
ALTER TABLE watchman_items_new RENAME TO watchman_items;
CREATE INDEX IF NOT EXISTS idx_watchman_items_queue ON watchman_items(state, not_before);
CREATE INDEX IF NOT EXISTS idx_watchman_items_wb ON watchman_items(workbench_id, created_at);
CREATE INDEX IF NOT EXISTS idx_watchman_items_created ON watchman_items(created_at);
COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;
