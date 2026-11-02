-- +goose Up
-- Session progress scope, final review (docs/superpowers/specs/2026-10-31-session-progress-scope-design.md):
-- target_bound_at is when Go last bound the session to target_id (set_session_target or
-- `workbench session-target`); NULL = never re-bound after launch, the binding stamp is then
-- created_at. A binding takes the target's leaves for the progress count without writing a link
-- row per leaf (link rows mean "this session touched it" to other readers).
ALTER TABLE terminal_sessions ADD COLUMN target_bound_at TEXT;

-- +goose Down
ALTER TABLE terminal_sessions DROP COLUMN target_bound_at;
