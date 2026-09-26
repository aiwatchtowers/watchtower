-- +goose Up
-- The per-user communication-guide feature is dead top to bottom: its only
-- writer (db.UpsertCommunicationGuide) had zero non-test callers. Drop the dead
-- table. (guide_summaries is the separate sibling table — dropped in 00060.)
DROP TABLE IF EXISTS communication_guides;

-- +goose Down
CREATE TABLE IF NOT EXISTS communication_guides (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id                 TEXT NOT NULL,
    period_from             REAL NOT NULL,             -- Unix timestamp (window start)
    period_to               REAL NOT NULL,             -- Unix timestamp (window end)
    -- Computed stats (pure SQL, no AI)
    message_count           INTEGER NOT NULL DEFAULT 0,
    channels_active         INTEGER NOT NULL DEFAULT 0,
    threads_initiated       INTEGER NOT NULL DEFAULT 0,
    threads_replied         INTEGER NOT NULL DEFAULT 0,
    avg_message_length      REAL NOT NULL DEFAULT 0,
    active_hours_json       TEXT NOT NULL DEFAULT '{}',
    volume_change_pct       REAL NOT NULL DEFAULT 0,
    -- AI-generated guide (coach framing)
    summary                 TEXT NOT NULL DEFAULT '',
    communication_preferences TEXT NOT NULL DEFAULT '',
    availability_patterns   TEXT NOT NULL DEFAULT '',
    decision_process        TEXT NOT NULL DEFAULT '',
    situational_tactics     TEXT NOT NULL DEFAULT '[]',
    effective_approaches    TEXT NOT NULL DEFAULT '[]',
    recommendations         TEXT NOT NULL DEFAULT '[]',
    relationship_context    TEXT NOT NULL DEFAULT '',
    -- Metadata
    model                   TEXT NOT NULL DEFAULT '',
    input_tokens            INTEGER NOT NULL DEFAULT 0,
    output_tokens           INTEGER NOT NULL DEFAULT 0,
    cost_usd                REAL NOT NULL DEFAULT 0,
    prompt_version          INTEGER NOT NULL DEFAULT 0,
    created_at              TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(user_id, period_from, period_to)
);
CREATE INDEX IF NOT EXISTS idx_communication_guides_user ON communication_guides(user_id);
CREATE INDEX IF NOT EXISTS idx_communication_guides_period ON communication_guides(period_from, period_to);
