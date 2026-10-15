-- +goose Up
CREATE TABLE plan_usage_samples (
    taken_at   TEXT NOT NULL,
    limit_key  TEXT NOT NULL,
    percent    REAL NOT NULL,
    resets_at  TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (limit_key, taken_at)
);

CREATE TABLE plan_usage_status (
    id             INTEGER PRIMARY KEY CHECK (id = 1),
    state          TEXT NOT NULL CHECK (state IN ('ok','stale','unavailable','error','disabled')),
    reason         TEXT NOT NULL DEFAULT '',
    plan           TEXT NOT NULL DEFAULT '',
    fetched_at     TEXT,
    last_error     TEXT NOT NULL DEFAULT '',
    last_error_at  TEXT,
    limits_json    TEXT NOT NULL DEFAULT '[]',
    breakdown_json TEXT NOT NULL DEFAULT '[]',
    updated_at     TEXT NOT NULL
);

-- +goose Down
DROP TABLE plan_usage_status;
DROP TABLE plan_usage_samples;
