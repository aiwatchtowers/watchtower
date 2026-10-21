-- +goose Up
-- A waiting automation run survives a daemon restart (board #795, spec
-- docs/superpowers/specs/2026-10-21-automation-wait-survives-restart-design.md).
-- The run is resumed by re-executing its recipe_snapshot and answering every
-- SDK call that had completed from this replay log; the call it waited in
-- re-enters its wait.
--   resume_pending  1 = a waiting run the daemon start kept for a resume (the
--                   status stays 'waiting'); the executor claims it before
--                   queued runs and clears it
--   not_resumable   1 = the run's replay log is incomplete (a result or the
--                   whole log too large): a restart ends it as before
--   random_seed     the run's Math.random seed, set at claim
ALTER TABLE automation_runs ADD COLUMN resume_pending INTEGER NOT NULL DEFAULT 0 CHECK (resume_pending IN (0, 1));
ALTER TABLE automation_runs ADD COLUMN not_resumable INTEGER NOT NULL DEFAULT 0 CHECK (not_resumable IN (0, 1));
ALTER TABLE automation_runs ADD COLUMN random_seed INTEGER NOT NULL DEFAULT 0;

-- One row per completed SDK call of a live (non-dry) run, plus one pending
-- row (pending = 1, no result) for the call the run waits in. seq is the
-- journal step's seq; args_hash the sha256 of the call's whole args JSON;
-- result_json the whole result the script got (NULL = undefined);
-- error_json {name, message, needed} of a thrown call; clock_json the
-- Date.now() values (ms) the script read since the previous call.
CREATE TABLE IF NOT EXISTS automation_run_replay (
    run_id      INTEGER NOT NULL REFERENCES automation_runs(id) ON DELETE CASCADE,
    seq         INTEGER NOT NULL,
    kind        TEXT NOT NULL,
    name        TEXT NOT NULL,
    args_hash   TEXT NOT NULL,
    result_json TEXT,
    error_json  TEXT,
    clock_json  TEXT NOT NULL DEFAULT '[]',
    pending     INTEGER NOT NULL DEFAULT 0 CHECK (pending IN (0, 1)),
    PRIMARY KEY (run_id, seq)
);

-- The log lives only while its run is active: any terminal status deletes
-- it, and clears resume_pending, in the same statement's transaction.
-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS automation_runs_replay_cleanup AFTER UPDATE OF status ON automation_runs
WHEN NEW.status NOT IN ('queued','running','waiting')
BEGIN
    DELETE FROM automation_run_replay WHERE run_id = NEW.id;
    UPDATE automation_runs SET resume_pending = 0 WHERE id = NEW.id AND resume_pending = 1;
END;
-- +goose StatementEnd

-- +goose Down
DROP TRIGGER IF EXISTS automation_runs_replay_cleanup;
DROP TABLE IF EXISTS automation_run_replay;
ALTER TABLE automation_runs DROP COLUMN random_seed;
ALTER TABLE automation_runs DROP COLUMN not_resumable;
ALTER TABLE automation_runs DROP COLUMN resume_pending;
