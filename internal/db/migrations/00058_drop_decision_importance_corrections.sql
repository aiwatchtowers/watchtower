-- +goose Up
-- decision_importance_corrections was a prompt-tuning training signal that is
-- never written or read anymore (only purged). Drop the dead table.
DROP TABLE IF EXISTS decision_importance_corrections;

-- +goose Down
CREATE TABLE IF NOT EXISTS decision_importance_corrections (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    digest_id            INTEGER NOT NULL,
    decision_idx         INTEGER NOT NULL,
    topic_id             INTEGER NOT NULL DEFAULT 0,  -- 0 = legacy (pre-v39), >0 = digest_topics.id
    decision_text        TEXT NOT NULL DEFAULT '',
    original_importance  TEXT NOT NULL CHECK(original_importance IN ('high', 'medium', 'low')),
    new_importance       TEXT NOT NULL CHECK(new_importance IN ('high', 'medium', 'low')),
    created_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_dic_dedup ON decision_importance_corrections(digest_id, decision_idx);
CREATE INDEX IF NOT EXISTS idx_dic_created ON decision_importance_corrections(created_at);
