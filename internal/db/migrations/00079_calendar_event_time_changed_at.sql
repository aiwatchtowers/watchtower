-- +goose Up
-- When the sync last saw this event's start_time or end_time change (the
-- sync pass's own synced_at), '' when it never has. The inbox's
-- calendar_time_change trigger keys on it: synced_at is rewritten on every
-- pass and updated_at is the provider's stamp, which always precedes the pass
-- that fetched it, so neither can tell a rescheduled meeting apart.
ALTER TABLE calendar_events ADD COLUMN time_changed_at TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE calendar_events DROP COLUMN time_changed_at;
