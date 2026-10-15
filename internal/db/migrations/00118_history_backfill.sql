-- +goose Up
-- One row per source that started a history backfill after its first sync
-- (docs/features/history-backfill.md). reached_ts only moves down, from
-- upper_ts (the first instant the first sync covered) to floor_ts.
CREATE TABLE history_backfill (
    id             INTEGER PRIMARY KEY,
    source_kind    TEXT    NOT NULL CHECK (source_kind IN ('slack', 'gmail', 'imap', 'jira')),
    account_id     INTEGER NOT NULL,
    floor_ts       REAL    NOT NULL,
    upper_ts       REAL    NOT NULL,
    reached_ts     REAL    NOT NULL,
    status         TEXT    NOT NULL DEFAULT 'running'
                   CHECK (status IN ('running', 'paused', 'done', 'off')),
    waiting        TEXT    NOT NULL DEFAULT '' CHECK (waiting IN ('', 'plan_limit')),
    chunk_failures INTEGER NOT NULL DEFAULT 0,
    last_error     TEXT    NOT NULL DEFAULT '',
    started_at     TEXT    NOT NULL,
    updated_at     TEXT    NOT NULL,
    done_at        TEXT,
    UNIQUE (source_kind, account_id)
);

-- +goose Down
DROP TABLE history_backfill;
