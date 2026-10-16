-- +goose Up
-- The run an owner ask or a terminal session belongs to (automations P5):
-- NULL = not started by an automation. Every path that deletes runs deletes
-- their asks first, in the same transaction (deleteRunAsksSQL), so SET NULL
-- never leaves an ask looking like an external terminal's; a terminal
-- session outlives its run with the link nulled. A workbench delete removes
-- both through their project_id cascade.
ALTER TABLE owner_asks ADD COLUMN automation_run_id INTEGER REFERENCES automation_runs(id) ON DELETE SET NULL;
ALTER TABLE terminal_sessions ADD COLUMN automation_run_id INTEGER REFERENCES automation_runs(id) ON DELETE SET NULL;

-- +goose Down
ALTER TABLE terminal_sessions DROP COLUMN automation_run_id;
ALTER TABLE owner_asks DROP COLUMN automation_run_id;
