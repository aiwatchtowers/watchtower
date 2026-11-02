-- +goose Up
ALTER TABLE plan_usage_status ADD COLUMN plot_json TEXT NOT NULL DEFAULT '{}';

CREATE TABLE codex_plan_usage_status (
    id                     INTEGER PRIMARY KEY CHECK (id = 1),
    state                  TEXT NOT NULL CHECK (state IN ('ok','stale','unavailable','error','disabled')),
    reason                 TEXT NOT NULL DEFAULT '',
    plan                   TEXT NOT NULL DEFAULT '',
    fetched_at             TEXT,
    last_error             TEXT NOT NULL DEFAULT '',
    last_error_at          TEXT,
    limits_json            TEXT NOT NULL DEFAULT '[]',
    breakdown_json         TEXT NOT NULL DEFAULT '[]',
    updated_at             TEXT NOT NULL,
    plot_json              TEXT NOT NULL DEFAULT '{}',
    scope                  TEXT NOT NULL DEFAULT '',
    identity_known         INTEGER NOT NULL DEFAULT 0 CHECK (identity_known IN (0,1)),
    ordinary_usage_allowed INTEGER CHECK (ordinary_usage_allowed IN (0,1)),
    CHECK ((identity_known = 0 AND scope = '') OR (identity_known = 1 AND length(scope) = 64))
);

CREATE TABLE codex_plan_usage_samples (
    scope      TEXT NOT NULL CHECK (length(scope) = 64),
    limit_key  TEXT NOT NULL,
    taken_at   TEXT NOT NULL,
    percent    REAL NOT NULL CHECK (percent >= 0 AND percent <= 100),
    resets_at  TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (scope, limit_key, taken_at)
);

-- +goose Down
DROP TABLE codex_plan_usage_samples;
DROP TABLE codex_plan_usage_status;
ALTER TABLE plan_usage_status DROP COLUMN plot_json;
