-- +goose Up
-- Workbench methodology (board #266, spec 2026-10-15-workbench-configurable-methodology-design.md §8):
-- the owner's personal overrides; NULL = use the folder's .watchtower/workflow.md, else the built-in
-- default (watchtower-flow, strict, on). Written only by `watchtower workbench methodology`.
ALTER TABLE projects ADD COLUMN methodology_preset TEXT NULL CHECK (methodology_preset IS NULL OR methodology_preset IN ('watchtower-flow','none'));
ALTER TABLE projects ADD COLUMN ask_guard_mode TEXT NULL CHECK (ask_guard_mode IS NULL OR ask_guard_mode IN ('strict','soft','off'));
ALTER TABLE projects ADD COLUMN finish_check TEXT NULL CHECK (finish_check IS NULL OR finish_check IN ('on','off'));

-- +goose Down
ALTER TABLE projects DROP COLUMN finish_check;
ALTER TABLE projects DROP COLUMN ask_guard_mode;
ALTER TABLE projects DROP COLUMN methodology_preset;
