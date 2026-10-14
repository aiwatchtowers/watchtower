-- +goose Up
-- Automations P1 (design spec 2026-10-14 §9.1–§9.4): recipe index, runs, the
-- step journal, per-automation state and outputs. Go writes every table; the
-- Desktop writes only automation_outputs.read_at/dismissed_at. Timestamps are
-- UTC RFC 3339 seconds ('2006-01-02T15:04:05Z'). Budgets are tokens, never USD;
-- reported_cost_usd is display only.

-- One row per recipe file. The executor runs recipe_text (the parsed copy), not
-- the file. A row is runnable iff parse_error = '', enabled = 1, removed_at IS
-- NULL and confirmed_hash = approval_hash (confirmed_hash '' = never confirmed).
CREATE TABLE automations (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    slug                TEXT NOT NULL,                       -- filename stem
    scope               TEXT NOT NULL CHECK (scope IN ('personal','workbench')),
    project_id          INTEGER REFERENCES projects(id) ON DELETE CASCADE, -- workbench id; NULL = personal
    path                TEXT NOT NULL UNIQUE,                -- absolute recipe path
    name                TEXT NOT NULL DEFAULT '',
    trigger_kind        TEXT NOT NULL DEFAULT '' CHECK (trigger_kind IN ('','schedule','button','event','manual')), -- '' while unparsable
    trigger_spec        TEXT NOT NULL DEFAULT '{}',          -- JSON of the recipe's trigger
    missed_policy       TEXT NOT NULL DEFAULT 'run_once' CHECK (missed_policy IN ('run_once','skip')),
    concurrency         INTEGER NOT NULL DEFAULT 1 CHECK (concurrency BETWEEN 1 AND 4),
    budget_tokens       INTEGER NOT NULL DEFAULT 50000,
    budget_minutes      INTEGER NOT NULL DEFAULT 5,
    pause_timeout_hours INTEGER NOT NULL DEFAULT 72,
    permissions_json    TEXT NOT NULL DEFAULT '[]',          -- normalised manifest
    outputs_json        TEXT NOT NULL DEFAULT '[]',
    recipe_text         TEXT NOT NULL DEFAULT '',            -- the indexed copy the executor runs
    content_hash        TEXT NOT NULL DEFAULT '',
    approval_hash       TEXT NOT NULL DEFAULT '',
    confirmed_hash      TEXT NOT NULL DEFAULT '',            -- '' = never confirmed; set only by a confirm
    parse_error         TEXT NOT NULL DEFAULT '',
    enabled             INTEGER NOT NULL DEFAULT 0,
    last_scheduled_for  TEXT,                                -- RFC 3339 UTC
    next_run_at         TEXT,                                -- derived by the scheduler, for the list
    removed_at          TEXT,                                -- the file is gone
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    CHECK ((scope = 'workbench') = (project_id IS NOT NULL))
);
CREATE UNIQUE INDEX idx_automations_scope_slug ON automations(scope, COALESCE(project_id, 0), slug);

-- One row per run. Triggers only insert queued rows; the executor claims them.
-- event_json: '' for every non-event run; for trigger = 'event' exactly
-- {"cycles": ["<cycle id>", ...], "events": [<event>, ... at most 100],
--  "count": <total matched>, "truncated": <bool>} (spec §8).
CREATE TABLE automation_runs (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    automation_id     INTEGER NOT NULL REFERENCES automations(id) ON DELETE CASCADE,
    trigger           TEXT NOT NULL CHECK (trigger IN ('schedule','catch_up','button','event','manual','dry_run')),
    scheduled_for     TEXT,
    event_cycle       TEXT,
    event_json        TEXT NOT NULL DEFAULT '',
    rerun_of          INTEGER REFERENCES automation_runs(id) ON DELETE SET NULL,
    status            TEXT NOT NULL DEFAULT 'queued'
                      CHECK (status IN ('queued','running','waiting','succeeded','failed','budget_exceeded',
                                        'timed_out','cancelled','expired')),
    waiting_reason    TEXT NOT NULL DEFAULT '' CHECK (waiting_reason IN ('','approval','ask','session','app')),
    recipe_hash       TEXT NOT NULL DEFAULT '',              -- approval_hash at claim
    recipe_snapshot   TEXT NOT NULL DEFAULT '',              -- recipe_text at claim
    budget_tokens     INTEGER NOT NULL DEFAULT 0,            -- snapshotted at claim
    budget_minutes    INTEGER NOT NULL DEFAULT 0,            -- snapshotted at claim
    input_tokens      INTEGER NOT NULL DEFAULT 0,
    output_tokens     INTEGER NOT NULL DEFAULT 0,
    tokens_estimated  INTEGER NOT NULL DEFAULT 0,            -- 1 when any call's usage was estimated
    reported_cost_usd REAL,                                  -- display only; NULL when no provider reported one
    active_ms         INTEGER NOT NULL DEFAULT 0,
    error             TEXT NOT NULL DEFAULT '',
    error_kind        TEXT NOT NULL DEFAULT ''
                      CHECK (error_kind IN ('','script','permission','budget','daily_cap','timeout','interrupted',
                                            'not_runnable','expired','cancelled','backend')),
    summary           TEXT NOT NULL DEFAULT '',              -- clipped 1 KiB
    queued_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    started_at        TEXT,
    finished_at       TEXT
);
CREATE INDEX idx_automation_runs_automation_status ON automation_runs(automation_id, status);
CREATE INDEX idx_automation_runs_status_queued ON automation_runs(status, queued_at);
CREATE UNIQUE INDEX idx_automation_runs_event_cycle ON automation_runs(automation_id, event_cycle)
    WHERE event_cycle IS NOT NULL;
CREATE UNIQUE INDEX idx_automation_runs_queued_trigger ON automation_runs(automation_id, trigger)
    WHERE status = 'queued';
CREATE INDEX idx_automation_runs_rerun_of ON automation_runs(rerun_of);

-- One row per SDK call of a run (the journal).
CREATE TABLE automation_run_steps (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id            INTEGER NOT NULL REFERENCES automation_runs(id) ON DELETE CASCADE,
    seq               INTEGER NOT NULL,
    kind              TEXT NOT NULL CHECK (kind IN ('llm','tool','mcp','agent','ask','state','output','session','shell','log')),
    name              TEXT NOT NULL DEFAULT '',              -- tool/output/server name
    args_json         TEXT NOT NULL DEFAULT '',              -- clipped 4 KiB; never holds secrets
    result_summary    TEXT NOT NULL DEFAULT '',              -- clipped 4 KiB
    status            TEXT NOT NULL
                      CHECK (status IN ('ok','error','denied','proposed','applied','rejected','failed','waiting','dry_run')),
    auto              INTEGER NOT NULL DEFAULT 0,
    permission        TEXT NOT NULL DEFAULT '',              -- the entry that admitted it, or the one it lacked
    action_id         INTEGER,                               -- agent_actions id, no FK
    ask_id            INTEGER,                               -- owner_asks id, no FK (P5)
    session_id        INTEGER,                               -- terminal_sessions id, no FK (P5)
    input_tokens      INTEGER NOT NULL DEFAULT 0,
    output_tokens     INTEGER NOT NULL DEFAULT 0,
    tokens_estimated  INTEGER NOT NULL DEFAULT 0,
    reported_cost_usd REAL,                                  -- display only
    duration_ms       INTEGER NOT NULL DEFAULT 0,
    error             TEXT NOT NULL DEFAULT '',
    started_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    finished_at       TEXT,
    UNIQUE (run_id, seq)
);

-- The state a script keeps between runs; replaced only by a succeeded run.
CREATE TABLE automation_state (
    automation_id INTEGER PRIMARY KEY REFERENCES automations(id) ON DELETE CASCADE,
    state_json    TEXT NOT NULL DEFAULT '{}',
    run_id        INTEGER,                                   -- the run that wrote it; no FK
    updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- What succeeded runs produced (inbox items, briefing blocks, reports).
CREATE TABLE automation_outputs (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    automation_id INTEGER NOT NULL REFERENCES automations(id) ON DELETE CASCADE,
    run_id        INTEGER NOT NULL REFERENCES automation_runs(id) ON DELETE CASCADE,
    kind          TEXT NOT NULL CHECK (kind IN ('inbox','briefing','report')),
    title         TEXT NOT NULL,
    body          TEXT NOT NULL,
    priority      TEXT NOT NULL DEFAULT 'medium' CHECK (priority IN ('high','medium','low')),
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    read_at       TEXT,                                      -- Desktop-written
    dismissed_at  TEXT                                       -- Desktop-written
);
CREATE INDEX idx_automation_outputs_kind ON automation_outputs(kind, created_at);
CREATE INDEX idx_automation_outputs_automation ON automation_outputs(automation_id);
CREATE INDEX idx_automation_outputs_run ON automation_outputs(run_id);

-- +goose Down
DROP TABLE IF EXISTS automation_outputs;
DROP TABLE IF EXISTS automation_state;
DROP TABLE IF EXISTS automation_run_steps;
DROP TABLE IF EXISTS automation_runs;
DROP TABLE IF EXISTS automations;
