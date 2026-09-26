-- +goose Up
-- The per-item secretary card stage (inbox.card) was replaced by the dashboard
-- composer + situation-card stages (inbox.compose / inbox.situation_card), so
-- the inbox.card prompt is no longer used anywhere in Go. Drop its DB row.
DELETE FROM prompts WHERE id = 'inbox.card';

-- +goose Down
-- prompt re-seeds from defaults on downgrade builds
