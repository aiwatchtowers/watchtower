-- +goose Up
-- Workbench session report (spec
-- docs/superpowers/specs/2026-10-03-workbench-session-report-design.md
-- Part 2). Go is the only writer of every column and table here; the Desktop
-- reads them.
--
-- finished_at/finish_summary: finish_session marks the session finished; a
-- `working` state write clears finished_at and keeps the summary.
-- agent_failed_at/agent_error: a StopFailure stores waiting plus this flag
-- (agent_failed_at = that write's agent_state_at); every other state write
-- clears it. Two columns rather than a new agent_state value: widening the
-- 00098 CHECK would mean rebuilding terminal_sessions.
ALTER TABLE terminal_sessions ADD COLUMN finished_at TEXT;
ALTER TABLE terminal_sessions ADD COLUMN finish_summary TEXT NOT NULL DEFAULT '';
ALTER TABLE terminal_sessions ADD COLUMN agent_failed_at TEXT;
ALTER TABLE terminal_sessions ADD COLUMN agent_error TEXT NOT NULL DEFAULT '';

-- Which targets a session's agent wrote to (the workbench write tools).
CREATE TABLE terminal_session_targets (
    session_id INTEGER NOT NULL REFERENCES terminal_sessions(id) ON DELETE CASCADE,
    target_id  INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    first_at   TEXT NOT NULL,
    last_at    TEXT NOT NULL,
    PRIMARY KEY (session_id, target_id)
);
CREATE INDEX idx_terminal_session_targets_target ON terminal_session_targets(target_id);

-- Go-only cache of PR/branch state for session reports.
CREATE TABLE workbench_pr_states (
    project_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    ref         TEXT NOT NULL,
    state       TEXT NOT NULL CHECK(state IN ('merged','open','closed','none','unknown')),
    pr_number   INTEGER,
    title       TEXT NOT NULL DEFAULT '',
    additions   INTEGER,
    deletions   INTEGER,
    merged_at   TEXT NOT NULL DEFAULT '',
    checked_at  TEXT NOT NULL,
    PRIMARY KEY (project_id, ref)
);

-- +goose Down
DROP TABLE workbench_pr_states;
DROP INDEX idx_terminal_session_targets_target;
DROP TABLE terminal_session_targets;
ALTER TABLE terminal_sessions DROP COLUMN agent_error;
ALTER TABLE terminal_sessions DROP COLUMN agent_failed_at;
ALTER TABLE terminal_sessions DROP COLUMN finish_summary;
ALTER TABLE terminal_sessions DROP COLUMN finished_at;
