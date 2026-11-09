-- +goose Up
-- Go hub 3 Task 8: a Desktop New Session runs `workbench session start`, whose detached
-- finish places the row in another process. The owner's line about the place (worktree
-- warnings, "Started in the folder: …", the setup command that did not run, a failed move)
-- reaches the Desktop on the row. NULL or '' = nothing to say. Go writes it; the Desktop reads.
ALTER TABLE terminal_sessions ADD COLUMN start_notice TEXT;

-- +goose Down
ALTER TABLE terminal_sessions DROP COLUMN start_notice;
