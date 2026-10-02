-- +goose Up
-- When this account's full workspace roster (users.list, every page) was last
-- fetched; '' = never. The search sync refreshes the roster at most once a day
-- and `sync --users-only` (the onboarding people picker) fetches it on demand:
-- both read and stamp this one marker, so a users-only fetch is not repeated
-- by the daemon's next cycle, across processes and restarts.
ALTER TABLE slack_accounts ADD COLUMN roster_synced_at TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE slack_accounts DROP COLUMN roster_synced_at;
