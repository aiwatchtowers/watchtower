-- +goose Up
CREATE TABLE IF NOT EXISTS situations (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    title           TEXT NOT NULL,
    kind            TEXT NOT NULL DEFAULT 'external' CHECK(kind IN ('external','target_update','track_update','mixed')),
    status          TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','done','dismissed','converted','stale','snoozed')),
    snooze_until    TEXT NOT NULL DEFAULT '',
    priority        TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('high','medium','low')),
    rank            REAL NOT NULL DEFAULT 0,
    ai_reason       TEXT NOT NULL DEFAULT '',
    summary         TEXT NOT NULL DEFAULT '',
    why_matters     TEXT NOT NULL DEFAULT '',
    chronology      TEXT NOT NULL DEFAULT '',
    card_status     TEXT NOT NULL DEFAULT 'none' CHECK(card_status IN ('none','ready','failed')),
    card_generated_at TEXT,
    target_id       INTEGER,
    track_id        INTEGER,
    converted_target_id INTEGER,
    converted_track_id  INTEGER,
    last_signal_at  TEXT NOT NULL DEFAULT '',
    resolved_reason TEXT NOT NULL DEFAULT '',
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_situations_status_rank ON situations(status, rank DESC);
CREATE INDEX IF NOT EXISTS idx_situations_updated ON situations(updated_at DESC);

CREATE TABLE IF NOT EXISTS situation_signals (
    situation_id   INTEGER NOT NULL REFERENCES situations(id) ON DELETE CASCADE,
    inbox_item_id  INTEGER NOT NULL REFERENCES inbox_items(id) ON DELETE CASCADE,
    UNIQUE(situation_id, inbox_item_id)
);
CREATE INDEX IF NOT EXISTS idx_situation_signals_item ON situation_signals(inbox_item_id);

ALTER TABLE inbox_items ADD COLUMN composed_at TEXT;
ALTER TABLE workspace ADD COLUMN compose_last_run_ts REAL NOT NULL DEFAULT 0;

-- +goose Down
DROP TABLE IF EXISTS situation_signals;
DROP TABLE IF EXISTS situations;
ALTER TABLE inbox_items DROP COLUMN composed_at;
ALTER TABLE workspace DROP COLUMN compose_last_run_ts;
