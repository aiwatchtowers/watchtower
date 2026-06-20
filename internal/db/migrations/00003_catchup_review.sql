-- +goose Up
-- Catch-Up v2 — persisted review sessions + per-theme rows, pipeline-scoped
-- learned rules, and a feedback entity_type for catch-up themes.

-- Defer FK checks so the feedback table recreate (DROP/RENAME) survives any
-- inbound references; SQLite re-validates at COMMIT once the table exists again.
PRAGMA defer_foreign_keys = ON;

CREATE TABLE IF NOT EXISTS catchup_sessions (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at     TEXT NOT NULL,
    status         TEXT NOT NULL CHECK(status IN ('building','active','done','failed')),
    oldest_unread  TEXT NOT NULL DEFAULT '',
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

ALTER TABLE inbox_learned_rules ADD COLUMN pipeline TEXT NOT NULL DEFAULT 'inbox';

-- Expand feedback.entity_type CHECK to include 'catchup_theme' (table recreate).
CREATE TABLE feedback_new (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL CHECK(entity_type IN ('digest','track','decision','user_analysis','briefing','target','inbox','catchup_theme')),
    entity_id   TEXT NOT NULL,
    rating      INTEGER NOT NULL CHECK(rating IN (-1, 1)),
    comment     TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT INTO feedback_new SELECT id, entity_type, entity_id, rating, comment, created_at FROM feedback;
DROP TABLE feedback;
ALTER TABLE feedback_new RENAME TO feedback;
CREATE INDEX IF NOT EXISTS idx_feedback_entity ON feedback(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_feedback_rating ON feedback(entity_type, rating);

-- +goose Down
PRAGMA defer_foreign_keys = ON;
DROP TABLE IF EXISTS catchup_themes;
DROP TABLE IF EXISTS catchup_sessions;
ALTER TABLE inbox_learned_rules DROP COLUMN pipeline;

CREATE TABLE feedback_old (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL CHECK(entity_type IN ('digest','track','decision','user_analysis','briefing','target','inbox')),
    entity_id   TEXT NOT NULL,
    rating      INTEGER NOT NULL CHECK(rating IN (-1, 1)),
    comment     TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT INTO feedback_old SELECT id, entity_type, entity_id, rating, comment, created_at FROM feedback WHERE entity_type <> 'catchup_theme';
DROP TABLE feedback;
ALTER TABLE feedback_old RENAME TO feedback;
CREATE INDEX IF NOT EXISTS idx_feedback_entity ON feedback(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_feedback_rating ON feedback(entity_type, rating);
