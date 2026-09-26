-- +goose Up
-- Catch-Up becomes an absence recap (spec 2026-09-04): one persisted recap per
-- time window replaces the unread-driven review session + per-theme rows.
-- The old tables held only review state (no history), so they are dropped, not
-- migrated.
DROP TABLE IF EXISTS catchup_themes;
DROP TABLE IF EXISTS catchup_sessions;

CREATE TABLE catchup_recaps (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    period_from     REAL NOT NULL,
    period_to       REAL NOT NULL,
    status          TEXT NOT NULL CHECK(status IN ('building','ready','failed')),
    tldr            TEXT NOT NULL DEFAULT '',
    body_json       TEXT NOT NULL DEFAULT '{}',
    coverage_json   TEXT NOT NULL DEFAULT '{}',
    error           TEXT NOT NULL DEFAULT '',
    regen_of_id     INTEGER REFERENCES catchup_recaps(id) ON DELETE SET NULL,
    acknowledged_at TEXT,
    model           TEXT NOT NULL DEFAULT '',
    input_tokens    INTEGER NOT NULL DEFAULT 0,
    output_tokens   INTEGER NOT NULL DEFAULT 0,
    cost_usd        REAL NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX idx_catchup_recaps_ack ON catchup_recaps(acknowledged_at, period_to DESC);

-- +goose Down
DROP TABLE IF EXISTS catchup_recaps;

CREATE TABLE IF NOT EXISTS catchup_sessions (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at     TEXT NOT NULL,
    status         TEXT NOT NULL CHECK(status IN ('building','active','done','failed')),
    total_themes   INTEGER NOT NULL DEFAULT 0,
    reviewed_count INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS catchup_themes (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id       INTEGER NOT NULL REFERENCES catchup_sessions(id) ON DELETE CASCADE,
    order_idx        INTEGER NOT NULL DEFAULT 0,
    title            TEXT NOT NULL DEFAULT '',
    narrative        TEXT NOT NULL DEFAULT '',
    priority         TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('high','medium','low')),
    needs_you        INTEGER NOT NULL DEFAULT 0,
    suggested_action TEXT NOT NULL DEFAULT '',
    refs             TEXT NOT NULL DEFAULT '[]',
    gen_state        TEXT NOT NULL DEFAULT 'skeleton' CHECK(gen_state IN ('skeleton','expanding','ready','failed')),
    review_state     TEXT NOT NULL DEFAULT 'pending' CHECK(review_state IN ('pending','reviewed','snoozed')),
    snooze_until     TEXT NOT NULL DEFAULT '',
    task_id          INTEGER NOT NULL DEFAULT 0,
    created_at       TEXT NOT NULL,
    updated_at       TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_catchup_themes_session ON catchup_themes(session_id, order_idx);
