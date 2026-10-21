-- +goose NO TRANSACTION
-- +goose Up
-- Inbox cards with a link and action buttons, a Done state, and the reply
-- trigger (plan docs/superpowers/plans/2026-10-21-inbox-reading-pane-and-card-actions.md).
--
-- 1. automation_runs.trigger gains 'reply': one owner press of a card's
--    Reply button queues one run that is never coalesced with another, so
--    the partial unique index on queued (automation, trigger) leaves reply
--    runs out. SQLite cannot change a CHECK in place: the table is rebuilt
--    with every row, its id and its AUTOINCREMENT high-water mark (00144's
--    sqlite_sequence carry). automation_runs is the parent of ON DELETE
--    CASCADE / SET NULL children (steps, outputs, replay log, owner asks,
--    terminal sessions, rerun_of), so foreign keys are OFF around the dance:
--    the DROP must fire no cascade. The 00146 columns, CHECKs and the replay
--    cleanup trigger are carried verbatim.
-- 2. automation_outputs gains the card's link, its actions, done_at and the
--    press record. Every card already read is done (the old Inbox had only
--    read and dismissed; read meant handled).
PRAGMA foreign_keys = OFF;

CREATE TABLE automation_runs_new (
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

PRAGMA foreign_keys = ON;

ALTER TABLE automation_outputs ADD COLUMN link TEXT NOT NULL DEFAULT '';
ALTER TABLE automation_outputs ADD COLUMN actions_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE automation_outputs ADD COLUMN done_at TEXT;
ALTER TABLE automation_outputs ADD COLUMN pressed_action INTEGER;
ALTER TABLE automation_outputs ADD COLUMN pressed_run_id INTEGER REFERENCES automation_runs(id) ON DELETE SET NULL;
ALTER TABLE automation_outputs ADD COLUMN pressed_at TEXT;
UPDATE automation_outputs SET done_at = read_at WHERE read_at IS NOT NULL;

-- +goose Down
-- Reply runs cannot live in the old table: they go with their steps, replay
-- log and outputs, and the asks, sessions and reruns that point at them keep
-- their row with the link cleared (foreign keys are OFF, so nothing cascades
-- by itself). A done card that was never opened reads as read again.
PRAGMA foreign_keys = OFF;

DELETE FROM automation_run_steps WHERE run_id IN (SELECT id FROM automation_runs WHERE trigger = 'reply');
DELETE FROM automation_run_replay WHERE run_id IN (SELECT id FROM automation_runs WHERE trigger = 'reply');
DELETE FROM automation_outputs WHERE run_id IN (SELECT id FROM automation_runs WHERE trigger = 'reply');
UPDATE owner_asks SET automation_run_id = NULL
    WHERE automation_run_id IN (SELECT id FROM automation_runs WHERE trigger = 'reply');
UPDATE terminal_sessions SET automation_run_id = NULL
    WHERE automation_run_id IN (SELECT id FROM automation_runs WHERE trigger = 'reply');
UPDATE automation_runs SET rerun_of = NULL
    WHERE rerun_of IN (SELECT id FROM automation_runs WHERE trigger = 'reply');
DELETE FROM automation_runs WHERE trigger = 'reply';

CREATE TABLE automation_runs_old (
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
    WHERE status = 'queued';
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

-- pressed_run_id is a foreign key, which DROP COLUMN refuses: the table is
-- rebuilt without the six columns. Nothing references automation_outputs.
UPDATE automation_outputs SET read_at = done_at WHERE read_at IS NULL AND done_at IS NOT NULL;
CREATE TABLE automation_outputs_old (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    automation_id INTEGER NOT NULL REFERENCES automations(id) ON DELETE CASCADE,
    run_id        INTEGER NOT NULL REFERENCES automation_runs(id) ON DELETE CASCADE,
    kind          TEXT NOT NULL CHECK (kind IN ('inbox','briefing','report')),
    title         TEXT NOT NULL,
    body          TEXT NOT NULL,
    priority      TEXT NOT NULL DEFAULT 'medium' CHECK (priority IN ('high','medium','low')),
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    read_at       TEXT,
    dismissed_at  TEXT
);
INSERT INTO automation_outputs_old (id, automation_id, run_id, kind, title, body, priority, created_at, read_at, dismissed_at)
SELECT id, automation_id, run_id, kind, title, body, priority, created_at, read_at, dismissed_at
FROM automation_outputs;
DELETE FROM sqlite_sequence WHERE name = 'automation_outputs_old';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'automation_outputs_old', seq FROM sqlite_sequence WHERE name = 'automation_outputs';
DROP TABLE automation_outputs;
ALTER TABLE automation_outputs_old RENAME TO automation_outputs;
CREATE INDEX IF NOT EXISTS idx_automation_outputs_kind ON automation_outputs(kind, created_at);
CREATE INDEX IF NOT EXISTS idx_automation_outputs_automation ON automation_outputs(automation_id);
CREATE INDEX IF NOT EXISTS idx_automation_outputs_run ON automation_outputs(run_id);

PRAGMA foreign_keys = ON;
