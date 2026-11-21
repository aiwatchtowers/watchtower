-- +goose NO TRANSACTION
-- +goose Up
-- Watchman tuning §4b (#2145): the stall watch. A handed session whose agent
-- stopped with nothing in the background is pinged after 3 minutes, at most
-- 3 times without progress; then a journal item kind 'stall' (ref 'session',
-- outcome 'parked') waits for the owner. watchman_items.kind gains 'stall':
-- SQLite cannot change a CHECK in place, so the table is rebuilt with every
-- row, its id and its AUTOINCREMENT high-water mark (sqlite_sequence carry),
-- every column of 00202/00205–00207 and its three indexes (00202's two and
-- 00204's created_at, which the DROP removes). One transaction as one goose
-- statement (see 00150); foreign keys are OFF around it so the DROP fires no
-- cascade (nothing references the table).
-- watchman_stalls is the twin worker's count per session (written only by
-- it, pruned with the arming): when its agent stopped, the pings since the
-- last progress, the worktree HEAD and the session's ask count at the last
-- ping, and when the stall was journalled.
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;
CREATE TABLE watchman_items_new (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    workbench_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    session_id    INTEGER,
    target_id     INTEGER,
    kind          TEXT NOT NULL CHECK (kind IN ('ask','review_doc','check','handover','permission','review_code','guard','stall')),
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
    owner_done_at TEXT,
    correction_sent_at TEXT,
    moves         INTEGER,
    UNIQUE (ref_kind, ref_id, kind)
);
INSERT INTO watchman_items_new (id, workbench_id, session_id, target_id, kind, ref_kind, ref_id, state, outcome, attempts, lease_until, not_before, question, choice, rationale, precedent_ids, confidence, importance, category, unsure, park_reason, delivery, round_id, cost_usd, error, created_at, decided_at, feedback, feedback_text, feedback_at, check_done_at, owner_done_at, correction_sent_at, moves)
    SELECT id, workbench_id, session_id, target_id, kind, ref_kind, ref_id, state, outcome, attempts, lease_until, not_before, question, choice, rationale, precedent_ids, confidence, importance, category, unsure, park_reason, delivery, round_id, cost_usd, error, created_at, decided_at, feedback, feedback_text, feedback_at, check_done_at, owner_done_at, correction_sent_at, moves FROM watchman_items;
DELETE FROM sqlite_sequence WHERE name = 'watchman_items_new';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'watchman_items_new', seq FROM sqlite_sequence WHERE name = 'watchman_items';
DROP TABLE watchman_items;
ALTER TABLE watchman_items_new RENAME TO watchman_items;
CREATE INDEX IF NOT EXISTS idx_watchman_items_queue ON watchman_items(state, not_before);
CREATE INDEX IF NOT EXISTS idx_watchman_items_wb ON watchman_items(workbench_id, created_at);
CREATE INDEX IF NOT EXISTS idx_watchman_items_created ON watchman_items(created_at);
CREATE TABLE IF NOT EXISTS watchman_stalls (
    session_id   INTEGER PRIMARY KEY REFERENCES terminal_sessions(id) ON DELETE CASCADE,
    stopped_at   TEXT NOT NULL,                -- RFC 3339 UTC: when the stopped state began (the turn end, or later the end of background work)
    pings        INTEGER NOT NULL DEFAULT 0,   -- pings delivered since the last progress
    last_ping_at TEXT,                         -- RFC 3339 UTC
    head         TEXT NOT NULL DEFAULT '',     -- the worktree's HEAD at the last ping
    asks_seen    INTEGER NOT NULL DEFAULT 0,   -- the session's ask count at the last ping
    parked_at    TEXT,                         -- the stall was journalled (kind 'stall')
    last_delivery TEXT NOT NULL DEFAULT '',    -- the last counted ping: 'submitted' or 'typed'
    reset_at     TEXT                          -- the last progress or Mark done (the stuck clock's floor)
);
COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;

-- +goose Down
-- The stall items cannot live in the old table: they go.
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;
DROP TABLE IF EXISTS watchman_stalls;
DELETE FROM watchman_items WHERE kind = 'stall';
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
    owner_done_at TEXT,
    correction_sent_at TEXT,
    moves         INTEGER,
    UNIQUE (ref_kind, ref_id, kind)
);
INSERT INTO watchman_items_new (id, workbench_id, session_id, target_id, kind, ref_kind, ref_id, state, outcome, attempts, lease_until, not_before, question, choice, rationale, precedent_ids, confidence, importance, category, unsure, park_reason, delivery, round_id, cost_usd, error, created_at, decided_at, feedback, feedback_text, feedback_at, check_done_at, owner_done_at, correction_sent_at, moves)
    SELECT id, workbench_id, session_id, target_id, kind, ref_kind, ref_id, state, outcome, attempts, lease_until, not_before, question, choice, rationale, precedent_ids, confidence, importance, category, unsure, park_reason, delivery, round_id, cost_usd, error, created_at, decided_at, feedback, feedback_text, feedback_at, check_done_at, owner_done_at, correction_sent_at, moves FROM watchman_items;
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
