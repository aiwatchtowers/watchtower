-- +goose Up
-- guide_summaries (cross-user team communication-health summaries) is dead: its
-- only accessors (db.UpsertGuideSummary/GetGuideSummary) have zero callers — it
-- shares the retired communication-guide feature's fate. The `internal/guide`
-- package is the unrelated People-cards pipeline (name collision), untouched.
DROP TABLE IF EXISTS guide_summaries;

-- +goose Down
CREATE TABLE IF NOT EXISTS guide_summaries (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    period_from   REAL NOT NULL,
    period_to     REAL NOT NULL,
    summary       TEXT NOT NULL DEFAULT '',     -- team communication health overview
    tips          TEXT NOT NULL DEFAULT '[]',   -- JSON array: team-level communication tips
    model         TEXT NOT NULL DEFAULT '',
    input_tokens  INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cost_usd      REAL NOT NULL DEFAULT 0,
    prompt_version INTEGER NOT NULL DEFAULT 0,
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(period_from, period_to)
);
