-- +goose Up
-- builtin_migrations.first_attempted_at: when a move was first attempted,
-- kept by every later attempt (updated_at is the latest). The custom-track
-- move lists only the tracks created by then (plan
-- docs/superpowers/plans/2026-10-22-c3-tracks-ideas-reactions-built-ins.md,
-- Task 12): a track made afterwards is never confirmed by the move. A row
-- from before this migration takes its updated_at, the best known moment.
ALTER TABLE builtin_migrations ADD COLUMN first_attempted_at TEXT NOT NULL DEFAULT '';
UPDATE builtin_migrations SET first_attempted_at = updated_at;

-- +goose Down
ALTER TABLE builtin_migrations DROP COLUMN first_attempted_at;
