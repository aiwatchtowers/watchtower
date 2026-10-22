-- +goose NO TRANSACTION
-- +goose Up
-- Built-in automations (plan docs/superpowers/plans/2026-10-22-c2-built-in-engine-and-morning-brief.md,
-- spec docs/superpowers/specs/2026-10-22-inbox-built-in-automations-design.md §4–§5).
--
-- 1. automations gains origin ('owner' | 'builtin'), builtin_id (set exactly
--    for a built-in row), overridden (the owner's copy of a built-in) and
--    builtin_base_hash (the content hash of the shipped text that copy was
--    made from). trigger_kind gains 'sync' (at its slot in every sync
--    cycle). A built-in row is personal; the scope/slug uniqueness covers
--    owner rows only, so a personal recipe may share a built-in's slug, and
--    a built-in id is unique.
-- 2. automation_runs.trigger gains 'sync' (one in-cycle run of a built-in).
-- 3. builtin_migrations: one row per built-in whose one-time move from the
--    old pipeline settings ran (done) or failed.
--
-- SQLite cannot change a CHECK in place: both tables are rebuilt with every
-- row, its id and its AUTOINCREMENT high-water mark (sqlite_sequence carry).
-- Both are parents of ON DELETE CASCADE / SET NULL children (runs, steps,
-- state, outputs, grants, replay log, owner asks, terminal sessions,
-- rerun_of), so foreign keys are OFF around the dance: the DROPs must fire no
-- cascade. 00149's automation_runs definition, indexes and replay cleanup
-- trigger are carried verbatim.
PRAGMA foreign_keys = OFF;

CREATE TABLE automations_new (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    slug                TEXT NOT NULL,
    scope               TEXT NOT NULL CHECK (scope IN ('personal','workbench')),
    project_id          INTEGER REFERENCES projects(id) ON DELETE CASCADE,
    path                TEXT NOT NULL UNIQUE,
    name                TEXT NOT NULL DEFAULT '',
    trigger_kind        TEXT NOT NULL DEFAULT '' CHECK (trigger_kind IN ('','schedule','button','event','manual','sync')),
    trigger_spec        TEXT NOT NULL DEFAULT '{}',
    missed_policy       TEXT NOT NULL DEFAULT 'run_once' CHECK (missed_policy IN ('run_once','skip')),
    concurrency         INTEGER NOT NULL DEFAULT 1 CHECK (concurrency BETWEEN 1 AND 4),
    budget_tokens       INTEGER NOT NULL DEFAULT 50000,
    budget_minutes      INTEGER NOT NULL DEFAULT 5,
    pause_timeout_hours INTEGER NOT NULL DEFAULT 72,
    permissions_json    TEXT NOT NULL DEFAULT '[]',
    outputs_json        TEXT NOT NULL DEFAULT '[]',
    recipe_text         TEXT NOT NULL DEFAULT '',
    content_hash        TEXT NOT NULL DEFAULT '',
    approval_hash       TEXT NOT NULL DEFAULT '',
    confirmed_hash      TEXT NOT NULL DEFAULT '',
    parse_error         TEXT NOT NULL DEFAULT '',
    enabled             INTEGER NOT NULL DEFAULT 0,
    last_scheduled_for  TEXT,
    next_run_at         TEXT,
    removed_at          TEXT,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    disabled_reason     TEXT NOT NULL DEFAULT '',
    disabled_at         TEXT,
    origin              TEXT NOT NULL DEFAULT 'owner' CHECK (origin IN ('owner','builtin')),
    builtin_id          TEXT,
    overridden          INTEGER NOT NULL DEFAULT 0 CHECK (overridden IN (0,1)),
    builtin_base_hash   TEXT NOT NULL DEFAULT '',
    CHECK ((scope = 'workbench') = (project_id IS NOT NULL)),
    CHECK ((origin = 'builtin') = (builtin_id IS NOT NULL)),
    CHECK (origin = 'owner' OR scope = 'personal')
);
INSERT INTO automations_new (id, slug, scope, project_id, path, name, trigger_kind, trigger_spec, missed_policy,
    concurrency, budget_tokens, budget_minutes, pause_timeout_hours, permissions_json, outputs_json,
    recipe_text, content_hash, approval_hash, confirmed_hash, parse_error, enabled,
    last_scheduled_for, next_run_at, removed_at, created_at, updated_at, disabled_reason, disabled_at)
SELECT id, slug, scope, project_id, path, name, trigger_kind, trigger_spec, missed_policy,
    concurrency, budget_tokens, budget_minutes, pause_timeout_hours, permissions_json, outputs_json,
    recipe_text, content_hash, approval_hash, confirmed_hash, parse_error, enabled,
    last_scheduled_for, next_run_at, removed_at, created_at, updated_at, disabled_reason, disabled_at
FROM automations;
DELETE FROM sqlite_sequence WHERE name = 'automations_new';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'automations_new', seq FROM sqlite_sequence WHERE name = 'automations';
DROP TABLE automations;
ALTER TABLE automations_new RENAME TO automations;

CREATE UNIQUE INDEX IF NOT EXISTS idx_automations_scope_slug ON automations(scope, COALESCE(project_id, 0), slug)
    WHERE origin = 'owner';
CREATE UNIQUE INDEX IF NOT EXISTS idx_automations_builtin_id ON automations(builtin_id) WHERE builtin_id IS NOT NULL;

CREATE TABLE automation_runs_new (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    automation_id     INTEGER NOT NULL REFERENCES automations(id) ON DELETE CASCADE,
    trigger           TEXT NOT NULL CHECK (trigger IN ('schedule','catch_up','button','event','manual','dry_run','reply','sync')),
    scheduled_for     TEXT,
    event_cycle       TEXT,
    event_json        TEXT NOT NULL DEFAULT '',
    rerun_of          INTEGER REFERENCES automation_runs(id) ON DELETE SET NULL,
    status            TEXT NOT NULL DEFAULT 'queued'
                      CHECK (status IN ('queued','running','waiting','succeeded','failed','budget_exceeded',
                                        'timed_out','cancelled','expired')),
    waiting_reason    TEXT NOT NULL DEFAULT '' CHECK (waiting_reason IN ('','approval','ask','session','app')),
    recipe_hash       TEXT NOT NULL DEFAULT '',
    recipe_snapshot   TEXT NOT NULL DEFAULT '',
    budget_tokens     INTEGER NOT NULL DEFAULT 0,
    budget_minutes    INTEGER NOT NULL DEFAULT 0,
    input_tokens      INTEGER NOT NULL DEFAULT 0,
    output_tokens     INTEGER NOT NULL DEFAULT 0,
    tokens_estimated  INTEGER NOT NULL DEFAULT 0,
    reported_cost_usd REAL,
    active_ms         INTEGER NOT NULL DEFAULT 0,
    error             TEXT NOT NULL DEFAULT '',
    error_kind        TEXT NOT NULL DEFAULT ''
                      CHECK (error_kind IN ('','script','permission','budget','daily_cap','timeout','interrupted',
                                            'not_runnable','expired','cancelled','backend')),
    summary           TEXT NOT NULL DEFAULT '',
    queued_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    started_at        TEXT,
    finished_at       TEXT,
    resume_pending    INTEGER NOT NULL DEFAULT 0 CHECK (resume_pending IN (0, 1)),
    not_resumable     INTEGER NOT NULL DEFAULT 0 CHECK (not_resumable IN (0, 1)),
    random_seed       INTEGER NOT NULL DEFAULT 0
);
INSERT INTO automation_runs_new (id, automation_id, trigger, scheduled_for, event_cycle, event_json, rerun_of, status,
    waiting_reason, recipe_hash, recipe_snapshot, budget_tokens, budget_minutes, input_tokens, output_tokens,
    tokens_estimated, reported_cost_usd, active_ms, error, error_kind, summary, queued_at, started_at, finished_at,
    resume_pending, not_resumable, random_seed)
SELECT id, automation_id, trigger, scheduled_for, event_cycle, event_json, rerun_of, status,
    waiting_reason, recipe_hash, recipe_snapshot, budget_tokens, budget_minutes, input_tokens, output_tokens,
    tokens_estimated, reported_cost_usd, active_ms, error, error_kind, summary, queued_at, started_at, finished_at,
    resume_pending, not_resumable, random_seed
FROM automation_runs;
DELETE FROM sqlite_sequence WHERE name = 'automation_runs_new';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'automation_runs_new', seq FROM sqlite_sequence WHERE name = 'automation_runs';
DROP TABLE automation_runs;
ALTER TABLE automation_runs_new RENAME TO automation_runs;

CREATE INDEX IF NOT EXISTS idx_automation_runs_automation_status ON automation_runs(automation_id, status);
CREATE INDEX IF NOT EXISTS idx_automation_runs_status_queued ON automation_runs(status, queued_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_automation_runs_event_cycle ON automation_runs(automation_id, event_cycle)
    WHERE event_cycle IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_automation_runs_queued_trigger ON automation_runs(automation_id, trigger)
    WHERE status = 'queued' AND trigger <> 'reply';
CREATE INDEX IF NOT EXISTS idx_automation_runs_rerun_of ON automation_runs(rerun_of);
CREATE INDEX IF NOT EXISTS idx_automation_runs_started_at ON automation_runs(started_at);

-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS automation_runs_replay_cleanup AFTER UPDATE OF status ON automation_runs
WHEN NEW.status NOT IN ('queued','running','waiting')
BEGIN
    DELETE FROM automation_run_replay WHERE run_id = NEW.id;
    UPDATE automation_runs SET resume_pending = 0 WHERE id = NEW.id AND resume_pending = 1;
END;
-- +goose StatementEnd

CREATE TABLE IF NOT EXISTS builtin_migrations (
    builtin_id TEXT PRIMARY KEY,
    status     TEXT NOT NULL CHECK (status IN ('done','failed')),
    error      TEXT NOT NULL DEFAULT '',
    attempts   INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);

PRAGMA foreign_keys = ON;

-- +goose Down
-- Built-in rows and sync runs cannot live in the old tables: they go with
-- their children — steps, replay log, outputs, state, grants — and the asks,
-- sessions, reruns and card presses that point at a removed run keep their
-- row with the link cleared (foreign keys are OFF, so nothing cascades by
-- itself). An owner recipe file left by an overridden built-in is indexed as
-- an ordinary recipe again by the old indexer.
PRAGMA foreign_keys = OFF;

CREATE TEMP TABLE builtin_down_runs AS
    SELECT id FROM automation_runs
    WHERE trigger = 'sync' OR automation_id IN (SELECT id FROM automations WHERE origin = 'builtin');
DELETE FROM automation_run_steps WHERE run_id IN (SELECT id FROM builtin_down_runs);
DELETE FROM automation_run_replay WHERE run_id IN (SELECT id FROM builtin_down_runs);
DELETE FROM automation_outputs WHERE run_id IN (SELECT id FROM builtin_down_runs)
    OR automation_id IN (SELECT id FROM automations WHERE origin = 'builtin');
UPDATE automation_outputs SET pressed_run_id = NULL WHERE pressed_run_id IN (SELECT id FROM builtin_down_runs);
UPDATE owner_asks SET automation_run_id = NULL WHERE automation_run_id IN (SELECT id FROM builtin_down_runs);
UPDATE terminal_sessions SET automation_run_id = NULL WHERE automation_run_id IN (SELECT id FROM builtin_down_runs);
UPDATE automation_runs SET rerun_of = NULL WHERE rerun_of IN (SELECT id FROM builtin_down_runs);
DELETE FROM automation_runs WHERE id IN (SELECT id FROM builtin_down_runs);
DROP TABLE builtin_down_runs;
DELETE FROM automation_state WHERE automation_id IN (SELECT id FROM automations WHERE origin = 'builtin');
DELETE FROM automation_tool_grants WHERE automation_id IN (SELECT id FROM automations WHERE origin = 'builtin');
DELETE FROM automations WHERE origin = 'builtin';

CREATE TABLE automations_old (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    slug                TEXT NOT NULL,
    scope               TEXT NOT NULL CHECK (scope IN ('personal','workbench')),
    project_id          INTEGER REFERENCES projects(id) ON DELETE CASCADE,
    path                TEXT NOT NULL UNIQUE,
    name                TEXT NOT NULL DEFAULT '',
    trigger_kind        TEXT NOT NULL DEFAULT '' CHECK (trigger_kind IN ('','schedule','button','event','manual')),
    trigger_spec        TEXT NOT NULL DEFAULT '{}',
    missed_policy       TEXT NOT NULL DEFAULT 'run_once' CHECK (missed_policy IN ('run_once','skip')),
    concurrency         INTEGER NOT NULL DEFAULT 1 CHECK (concurrency BETWEEN 1 AND 4),
    budget_tokens       INTEGER NOT NULL DEFAULT 50000,
    budget_minutes      INTEGER NOT NULL DEFAULT 5,
    pause_timeout_hours INTEGER NOT NULL DEFAULT 72,
    permissions_json    TEXT NOT NULL DEFAULT '[]',
    outputs_json        TEXT NOT NULL DEFAULT '[]',
    recipe_text         TEXT NOT NULL DEFAULT '',
    content_hash        TEXT NOT NULL DEFAULT '',
    approval_hash       TEXT NOT NULL DEFAULT '',
    confirmed_hash      TEXT NOT NULL DEFAULT '',
    parse_error         TEXT NOT NULL DEFAULT '',
    enabled             INTEGER NOT NULL DEFAULT 0,
    last_scheduled_for  TEXT,
    next_run_at         TEXT,
    removed_at          TEXT,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    disabled_reason     TEXT NOT NULL DEFAULT '',
    disabled_at         TEXT,
    CHECK ((scope = 'workbench') = (project_id IS NOT NULL))
);
-- An owner row never carries 'sync' (the parser refuses it outside a
-- built-in); should one exist, it is kept as unparsable rather than failing
-- the downgrade.
INSERT INTO automations_old (id, slug, scope, project_id, path, name, trigger_kind, trigger_spec, missed_policy,
    concurrency, budget_tokens, budget_minutes, pause_timeout_hours, permissions_json, outputs_json,
    recipe_text, content_hash, approval_hash, confirmed_hash, parse_error, enabled,
    last_scheduled_for, next_run_at, removed_at, created_at, updated_at, disabled_reason, disabled_at)
SELECT id, slug, scope, project_id, path, name,
    CASE WHEN trigger_kind = 'sync' THEN '' ELSE trigger_kind END, trigger_spec, missed_policy,
    concurrency, budget_tokens, budget_minutes, pause_timeout_hours, permissions_json, outputs_json,
    recipe_text, content_hash, approval_hash, confirmed_hash,
    CASE WHEN trigger_kind = 'sync' AND parse_error = '' THEN 'trigger sync is not supported' ELSE parse_error END,
    enabled, last_scheduled_for, next_run_at, removed_at, created_at, updated_at, disabled_reason, disabled_at
FROM automations;
DELETE FROM sqlite_sequence WHERE name = 'automations_old';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'automations_old', seq FROM sqlite_sequence WHERE name = 'automations';
DROP TABLE automations;
ALTER TABLE automations_old RENAME TO automations;
CREATE UNIQUE INDEX IF NOT EXISTS idx_automations_scope_slug ON automations(scope, COALESCE(project_id, 0), slug);

CREATE TABLE automation_runs_old (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    automation_id     INTEGER NOT NULL REFERENCES automations(id) ON DELETE CASCADE,
    trigger           TEXT NOT NULL CHECK (trigger IN ('schedule','catch_up','button','event','manual','dry_run','reply')),
    scheduled_for     TEXT,
    event_cycle       TEXT,
    event_json        TEXT NOT NULL DEFAULT '',
    rerun_of          INTEGER REFERENCES automation_runs(id) ON DELETE SET NULL,
    status            TEXT NOT NULL DEFAULT 'queued'
                      CHECK (status IN ('queued','running','waiting','succeeded','failed','budget_exceeded',
                                        'timed_out','cancelled','expired')),
    waiting_reason    TEXT NOT NULL DEFAULT '' CHECK (waiting_reason IN ('','approval','ask','session','app')),
    recipe_hash       TEXT NOT NULL DEFAULT '',
    recipe_snapshot   TEXT NOT NULL DEFAULT '',
    budget_tokens     INTEGER NOT NULL DEFAULT 0,
    budget_minutes    INTEGER NOT NULL DEFAULT 0,
    input_tokens      INTEGER NOT NULL DEFAULT 0,
    output_tokens     INTEGER NOT NULL DEFAULT 0,
    tokens_estimated  INTEGER NOT NULL DEFAULT 0,
    reported_cost_usd REAL,
    active_ms         INTEGER NOT NULL DEFAULT 0,
    error             TEXT NOT NULL DEFAULT '',
    error_kind        TEXT NOT NULL DEFAULT ''
                      CHECK (error_kind IN ('','script','permission','budget','daily_cap','timeout','interrupted',
                                            'not_runnable','expired','cancelled','backend')),
    summary           TEXT NOT NULL DEFAULT '',
    queued_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    started_at        TEXT,
    finished_at       TEXT,
    resume_pending    INTEGER NOT NULL DEFAULT 0 CHECK (resume_pending IN (0, 1)),
    not_resumable     INTEGER NOT NULL DEFAULT 0 CHECK (not_resumable IN (0, 1)),
    random_seed       INTEGER NOT NULL DEFAULT 0
);
INSERT INTO automation_runs_old (id, automation_id, trigger, scheduled_for, event_cycle, event_json, rerun_of, status,
    waiting_reason, recipe_hash, recipe_snapshot, budget_tokens, budget_minutes, input_tokens, output_tokens,
    tokens_estimated, reported_cost_usd, active_ms, error, error_kind, summary, queued_at, started_at, finished_at,
    resume_pending, not_resumable, random_seed)
SELECT id, automation_id, trigger, scheduled_for, event_cycle, event_json, rerun_of, status,
    waiting_reason, recipe_hash, recipe_snapshot, budget_tokens, budget_minutes, input_tokens, output_tokens,
    tokens_estimated, reported_cost_usd, active_ms, error, error_kind, summary, queued_at, started_at, finished_at,
    resume_pending, not_resumable, random_seed
FROM automation_runs;
DELETE FROM sqlite_sequence WHERE name = 'automation_runs_old';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'automation_runs_old', seq FROM sqlite_sequence WHERE name = 'automation_runs';
DROP TABLE automation_runs;
ALTER TABLE automation_runs_old RENAME TO automation_runs;

CREATE INDEX IF NOT EXISTS idx_automation_runs_automation_status ON automation_runs(automation_id, status);
CREATE INDEX IF NOT EXISTS idx_automation_runs_status_queued ON automation_runs(status, queued_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_automation_runs_event_cycle ON automation_runs(automation_id, event_cycle)
    WHERE event_cycle IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_automation_runs_queued_trigger ON automation_runs(automation_id, trigger)
    WHERE status = 'queued' AND trigger <> 'reply';
CREATE INDEX IF NOT EXISTS idx_automation_runs_rerun_of ON automation_runs(rerun_of);
CREATE INDEX IF NOT EXISTS idx_automation_runs_started_at ON automation_runs(started_at);

-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS automation_runs_replay_cleanup AFTER UPDATE OF status ON automation_runs
WHEN NEW.status NOT IN ('queued','running','waiting')
BEGIN
    DELETE FROM automation_run_replay WHERE run_id = NEW.id;
    UPDATE automation_runs SET resume_pending = 0 WHERE id = NEW.id AND resume_pending = 1;
END;
-- +goose StatementEnd

DROP TABLE IF EXISTS builtin_migrations;

PRAGMA foreign_keys = ON;
