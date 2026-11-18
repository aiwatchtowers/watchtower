-- +goose Up
-- Watchman phase 2 (spec §§2, 4, 6): arming rows, the twin's work items, the
-- Mac's sleep gaps and the owner's extra limits.
CREATE TABLE IF NOT EXISTS watchman_arming (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    scope    TEXT NOT NULL CHECK (scope IN ('session','target')),
    ref_id   INTEGER NOT NULL,            -- session or target id
    armed_at TEXT NOT NULL,               -- RFC 3339 UTC
    armed_by TEXT NOT NULL,               -- 'desktop' | 'cli'
    UNIQUE (scope, ref_id)
);

CREATE TABLE IF NOT EXISTS watchman_items (
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
CREATE INDEX IF NOT EXISTS idx_watchman_items_queue ON watchman_items(state, not_before);
CREATE INDEX IF NOT EXISTS idx_watchman_items_wb ON watchman_items(workbench_id, created_at);

CREATE TABLE IF NOT EXISTS watchman_gaps (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at TEXT NOT NULL,
    ended_at   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS watchman_extra_limits (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    kind       TEXT NOT NULL CHECK (kind IN ('command','tool')),
    pattern    TEXT NOT NULL,
    created_at TEXT NOT NULL,
    UNIQUE (kind, pattern)
);

-- +goose Down
DROP TABLE watchman_extra_limits;
DROP TABLE watchman_gaps;
DROP TABLE watchman_items;
DROP TABLE watchman_arming;
