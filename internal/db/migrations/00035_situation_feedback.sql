-- +goose Up
-- Expand feedback.entity_type CHECK to include 'situation' so dashboard
-- thumbs up/down can persist a per-situation rating (table recreate — SQLite
-- has no ALTER TABLE ... ADD CONSTRAINT). feedback has no inbound FKs, so no
-- foreign-key pragma handling is needed around the recreate.
CREATE TABLE feedback_new (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL CHECK(entity_type IN ('digest','track','decision','user_analysis','briefing','target','inbox','catchup_theme','situation')),
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
CREATE TABLE feedback_old (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL CHECK(entity_type IN ('digest','track','decision','user_analysis','briefing','target','inbox','catchup_theme')),
    entity_id   TEXT NOT NULL,
    rating      INTEGER NOT NULL CHECK(rating IN (-1, 1)),
    comment     TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT INTO feedback_old SELECT id, entity_type, entity_id, rating, comment, created_at FROM feedback WHERE entity_type <> 'situation';
DROP TABLE feedback;
ALTER TABLE feedback_old RENAME TO feedback;
CREATE INDEX IF NOT EXISTS idx_feedback_entity ON feedback(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_feedback_rating ON feedback(entity_type, rating);
