-- +goose Up
-- Observers: user-editable watchers attached to an entity (polymorphic via
-- entity_type/entity_id; v1 only uses entity_type='target'). Each enabled
-- observer is run by the daemon over recent cross-source activity since its
-- last_run_at watermark, producing rows in observer_events.
CREATE TABLE IF NOT EXISTS observers (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type  TEXT NOT NULL DEFAULT 'target' CHECK(entity_type IN ('target')),
    entity_id    INTEGER NOT NULL,
    name         TEXT NOT NULL DEFAULT '',
    instruction  TEXT NOT NULL DEFAULT '',
    enabled      INTEGER NOT NULL DEFAULT 1,
    last_run_at  TEXT NOT NULL DEFAULT '',   -- '' = never run; else ISO8601 watermark
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_observers_entity  ON observers(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_observers_enabled ON observers(enabled);

-- observer_events: the per-entity activity timeline produced by observers.
-- decision / proposed_action are optional JSON blobs ('' = absent). proposed_action
-- uses the same shape as the Desktop chat ProposedAction so the existing executor
-- applies it. action_status tracks the lifecycle of a proposed_action.
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

-- +goose Down
DROP TABLE IF EXISTS observer_events;
DROP TABLE IF EXISTS observers;
