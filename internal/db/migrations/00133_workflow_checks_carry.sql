-- +goose Up
-- Board #558: the folder's .watchtower/workflow.md no longer sets the ask guard or the finish check.
-- Workbenches that exist at this upgrade are marked carry-pending: once, an owner process copies a
-- weaker check from their folder file into the owner's setting where none is set (so setups made
-- before the change keep working) and clears the mark. Workbenches created later never get the mark,
-- and a fresh install has none. *_carried_at = when a check was carried over (NULL = picked by the
-- owner, or never carried); an owner write of that check clears it.
ALTER TABLE projects ADD COLUMN methodology_carry_pending INTEGER NOT NULL DEFAULT 0 CHECK (methodology_carry_pending IN (0, 1));
ALTER TABLE projects ADD COLUMN ask_guard_carried_at TEXT NULL;
ALTER TABLE projects ADD COLUMN finish_check_carried_at TEXT NULL;
UPDATE projects SET methodology_carry_pending = 1;

-- +goose Down
ALTER TABLE projects DROP COLUMN finish_check_carried_at;
ALTER TABLE projects DROP COLUMN ask_guard_carried_at;
ALTER TABLE projects DROP COLUMN methodology_carry_pending;
