-- +goose Up
-- Feed index for the dashboard's social-wall feed: one row per feed item,
-- holding chronology and per-item user state only. Content is always joined
-- live from the source tables (situations, calendar_events, briefings,
-- meeting_recaps, day_plans) — never duplicated here.
CREATE TABLE feed_items (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    item_type   TEXT NOT NULL CHECK (item_type IN ('situation','meeting','briefing','meeting_recap','day_plan')),
    source_id   TEXT NOT NULL,
    event_ts    TEXT NOT NULL,
    importance  INTEGER NOT NULL DEFAULT 50,
    hidden_at   TEXT,
    seen_at     TEXT,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(item_type, source_id)
);
CREATE INDEX idx_feed_items_event_ts ON feed_items(event_ts DESC);

-- Bootstrap cutoff: the moment this migration ran. The publisher only feeds
-- briefings/recaps/day-plans created after this, so an old backlog doesn't
-- flood the feed on first publish.
CREATE TABLE feed_state (
    id               INTEGER PRIMARY KEY CHECK (id = 1),
    bootstrap_cutoff TEXT NOT NULL
);
INSERT INTO feed_state (id, bootstrap_cutoff) VALUES (1, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));

-- +goose Down
DROP TABLE feed_state;
DROP TABLE feed_items;
