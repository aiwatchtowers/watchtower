-- +goose Up
-- LLM usage ledger (docs/superpowers/specs/2026-10-27-llm-usage-ledger-design.md §1):
-- one row per finished or failed model call a Watchtower process made. The
-- daemon is the only writer (its own calls + the imported spool); call_id is
-- UNIQUE so a spool import is idempotent. No foreign keys: rows outlive a
-- deleted automation. Pruned after 90 days by the daemon.
CREATE TABLE llm_calls (
    id                    INTEGER PRIMARY KEY,
    call_id               TEXT NOT NULL UNIQUE,
    at                    TEXT NOT NULL,
    surface               TEXT NOT NULL CHECK (surface IN ('watchtower','chat','workbench')),
    purpose               TEXT NOT NULL DEFAULT '',
    process               TEXT NOT NULL DEFAULT '',
    provider              TEXT NOT NULL DEFAULT '',
    model                 TEXT NOT NULL DEFAULT '',
    input_tokens          INTEGER NOT NULL DEFAULT 0,
    cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
    cache_write_5m_tokens INTEGER NOT NULL DEFAULT 0,
    cache_write_1h_tokens INTEGER NOT NULL DEFAULT 0,
    output_tokens         INTEGER NOT NULL DEFAULT 0,
    usage_estimated       INTEGER NOT NULL DEFAULT 0,
    reported_cost_usd     REAL,
    est_cost_usd          REAL,
    duration_ms           INTEGER NOT NULL DEFAULT 0,
    ok                    INTEGER NOT NULL DEFAULT 1,
    automation_id         INTEGER,
    automation_run_id     INTEGER
);
CREATE INDEX idx_llm_calls_at ON llm_calls(at);
CREATE INDEX idx_llm_calls_surface_at ON llm_calls(surface, at);

-- +goose Down
DROP INDEX IF EXISTS idx_llm_calls_surface_at;
DROP INDEX IF EXISTS idx_llm_calls_at;
DROP TABLE IF EXISTS llm_calls;
