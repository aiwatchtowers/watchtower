-- +goose Up
-- Workbench board columns (board #267, PROJ-19, spec
-- 2026-10-16-workbench-board-columns-design.md §3–§4): named columns inside
-- the fixed status categories of one workbench. A target's column
-- (targets.board_column_id) belongs to its workbench and its current status;
-- NULL = the status's first column. Written only by
-- `watchtower workbench columns` (the definition) and the target writers
-- (card moves, status and column in one statement).
CREATE TABLE workbench_board_columns (
    id          INTEGER PRIMARY KEY,
    project_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    status      TEXT NOT NULL CHECK(status IN ('todo','in_progress','in_review','blocked','done','dismissed')),
    title       TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    position    INTEGER NOT NULL,
    created_at  TEXT NOT NULL
);
CREATE INDEX idx_workbench_board_columns_project ON workbench_board_columns(project_id, status, position);

-- A deleted column drops its cards to the status's first column.
ALTER TABLE targets ADD COLUMN board_column_id INTEGER NULL REFERENCES workbench_board_columns(id) ON DELETE SET NULL;
-- JSON array, a subset of ["in_review","blocked"]; NULL = nothing hidden.
ALTER TABLE projects ADD COLUMN board_hidden_statuses TEXT NULL;

-- Check: a written column must be of the target's workbench and status. It
-- fires only when the column itself is written, so a plain status change
-- never aborts (the clear below handles it).
-- +goose StatementBegin
CREATE TRIGGER targets_board_column_check_ai BEFORE INSERT ON targets
WHEN NEW.board_column_id IS NOT NULL
 AND NOT EXISTS (SELECT 1 FROM workbench_board_columns c
                 WHERE c.id = NEW.board_column_id
                   AND c.project_id IS NEW.project_id
                   AND c.status = NEW.status)
BEGIN
    SELECT RAISE(ABORT, 'board column does not match the target');
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER targets_board_column_check_bu BEFORE UPDATE OF board_column_id ON targets
WHEN NEW.board_column_id IS NOT OLD.board_column_id
 AND NEW.board_column_id IS NOT NULL
 AND NOT EXISTS (SELECT 1 FROM workbench_board_columns c
                 WHERE c.id = NEW.board_column_id
                   AND c.project_id IS NEW.project_id
                   AND c.status = NEW.status)
BEGIN
    SELECT RAISE(ABORT, 'board column does not match the target');
END;
-- +goose StatementEnd

-- Clear: a status (or workbench) change that leaves the column's category
-- lands the card in the new category's first column. The inner UPDATE
-- touches only board_column_id, so neither the PROJ-05 rollup nor the PROJ-06
-- history triggers (both OF status…) fire again: column changes never write
-- target_status_history.
-- +goose StatementBegin
CREATE TRIGGER targets_board_column_clear_au AFTER UPDATE OF status, project_id ON targets
WHEN NEW.board_column_id IS NOT NULL
 AND NOT EXISTS (SELECT 1 FROM workbench_board_columns c
                 WHERE c.id = NEW.board_column_id
                   AND c.project_id IS NEW.project_id
                   AND c.status = NEW.status)
BEGIN
    UPDATE targets SET board_column_id = NULL WHERE id = NEW.id;
END;
-- +goose StatementEnd

-- +goose Down
DROP TRIGGER IF EXISTS targets_board_column_clear_au;
DROP TRIGGER IF EXISTS targets_board_column_check_bu;
DROP TRIGGER IF EXISTS targets_board_column_check_ai;
ALTER TABLE projects DROP COLUMN board_hidden_statuses;
ALTER TABLE targets DROP COLUMN board_column_id;
DROP INDEX IF EXISTS idx_workbench_board_columns_project;
DROP TABLE IF EXISTS workbench_board_columns;
