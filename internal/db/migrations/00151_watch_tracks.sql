-- +goose Up
-- Custom tracks become watch recipes (plan
-- docs/superpowers/plans/2026-10-22-c3-tracks-ideas-reactions-built-ins.md,
-- spec docs/superpowers/specs/2026-10-22-inbox-built-in-automations-design.md).
--
-- 1. tracks.automation_id binds one custom track to the watch recipe that
--    scans it (NULL = unbound, the legacy custom-track scan). No SQL foreign
--    key, so the down migration can DROP the column; the unique partial
--    index keeps a recipe bound to at most one track.
-- 2. trg_automations_enabled_watch_track mirrors the recipe's enabled into
--    its track, so every reader of tracks.enabled sees Collecting/Paused.
-- 3. trg_automations_delete_watch_track unbinds and pauses the track of a
--    deleted recipe; the track and its history stay.
ALTER TABLE tracks ADD COLUMN automation_id INTEGER;
CREATE UNIQUE INDEX idx_tracks_automation_id ON tracks(automation_id) WHERE automation_id IS NOT NULL;

-- +goose StatementBegin
CREATE TRIGGER trg_automations_enabled_watch_track AFTER UPDATE OF enabled ON automations
WHEN NEW.enabled <> OLD.enabled
BEGIN
    UPDATE tracks SET enabled = NEW.enabled WHERE automation_id = NEW.id;
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER trg_automations_delete_watch_track AFTER DELETE ON automations
BEGIN
    UPDATE tracks SET automation_id = NULL, enabled = 0 WHERE automation_id = OLD.id;
END;
-- +goose StatementEnd

-- +goose Down
DROP TRIGGER IF EXISTS trg_automations_delete_watch_track;
DROP TRIGGER IF EXISTS trg_automations_enabled_watch_track;
DROP INDEX IF EXISTS idx_tracks_automation_id;
ALTER TABLE tracks DROP COLUMN automation_id;
