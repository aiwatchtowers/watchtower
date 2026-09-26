-- +goose Up
-- Custom tracks: promote the observer engine into first-class tracks.
-- Adds custom-only columns to tracks, creates track_events (the ported
-- observer timeline), and drops the now-superseded observers tables.
PRAGMA defer_foreign_keys = ON;

-- New-column CHECK/FK are legal via ADD COLUMN because the default satisfies
-- the CHECK ('auto') and the FK column defaults to NULL.
ALTER TABLE tracks ADD COLUMN origin TEXT NOT NULL DEFAULT 'auto'
    CHECK(origin IN ('auto','custom'));
ALTER TABLE tracks ADD COLUMN instruction TEXT NOT NULL DEFAULT '';
ALTER TABLE tracks ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1;
ALTER TABLE tracks ADD COLUMN last_run_at TEXT NOT NULL DEFAULT '';
ALTER TABLE tracks ADD COLUMN linked_target_id INTEGER
    REFERENCES targets(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_tracks_origin ON tracks(origin);
CREATE INDEX IF NOT EXISTS idx_tracks_custom_enabled ON tracks(origin, enabled)
    WHERE origin = 'custom';

CREATE TABLE IF NOT EXISTS track_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    track_id        INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    summary         TEXT NOT NULL DEFAULT '',
    detail          TEXT NOT NULL DEFAULT '',
    source_type     TEXT NOT NULL DEFAULT '',
    source_id       TEXT NOT NULL DEFAULT '',
    source_refs     TEXT NOT NULL DEFAULT '[]',
    decision        TEXT NOT NULL DEFAULT '',
    proposed_action TEXT NOT NULL DEFAULT '',
    action_status   TEXT NOT NULL DEFAULT 'none'
                    CHECK(action_status IN ('none','pending','applied','dismissed')),
    read_at         TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_track_events_track ON track_events(track_id, created_at DESC);

DROP TABLE IF EXISTS observer_events;
DROP TABLE IF EXISTS observers;

-- +goose Down
PRAGMA defer_foreign_keys = ON;

DROP INDEX IF EXISTS idx_track_events_track;
DROP TABLE IF EXISTS track_events;

DROP INDEX IF EXISTS idx_tracks_custom_enabled;
DROP INDEX IF EXISTS idx_tracks_origin;
ALTER TABLE tracks DROP COLUMN linked_target_id;
ALTER TABLE tracks DROP COLUMN last_run_at;
ALTER TABLE tracks DROP COLUMN enabled;
ALTER TABLE tracks DROP COLUMN instruction;
ALTER TABLE tracks DROP COLUMN origin;

CREATE TABLE IF NOT EXISTS observers (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type  TEXT NOT NULL DEFAULT 'target' CHECK(entity_type IN ('target')),
    entity_id    INTEGER NOT NULL,
    name         TEXT NOT NULL DEFAULT '',
    instruction  TEXT NOT NULL DEFAULT '',
    enabled      INTEGER NOT NULL DEFAULT 1,
    last_run_at  TEXT NOT NULL DEFAULT '',
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_observers_entity  ON observers(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_observers_enabled ON observers(enabled);

CREATE TABLE IF NOT EXISTS observer_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    observer_id     INTEGER NOT NULL REFERENCES observers(id) ON DELETE CASCADE,
    entity_type     TEXT NOT NULL DEFAULT 'target',
    entity_id       INTEGER NOT NULL,
    summary         TEXT NOT NULL DEFAULT '',
    detail          TEXT NOT NULL DEFAULT '',
    source_type     TEXT NOT NULL DEFAULT '',
    source_id       TEXT NOT NULL DEFAULT '',
    source_refs     TEXT NOT NULL DEFAULT '[]',
    decision        TEXT NOT NULL DEFAULT '',
    proposed_action TEXT NOT NULL DEFAULT '',
    action_status   TEXT NOT NULL DEFAULT 'none'
                    CHECK(action_status IN ('none','pending','applied','dismissed')),
    read_at         TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_observer_events_entity   ON observer_events(entity_type, entity_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_observer_events_observer ON observer_events(observer_id);
