-- +goose Up
-- Agent coach Plan 2 (docs/superpowers/specs/2026-10-28-agent-coach-screen-design.md §6):
-- the daily instruction miner folds into the coach once. moved_to is NULL for a row never
-- moved, a coach_proposals id for a row carried into that proposal, -1 for a row retired at
-- the fold (its owner lines stay coach signals). A moved row is decided only in the coach.
ALTER TABLE instruction_suggestions ADD COLUMN moved_to INTEGER;

-- +goose Down
ALTER TABLE instruction_suggestions DROP COLUMN moved_to;
