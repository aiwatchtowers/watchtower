-- +goose Up
-- Stop syncing a channel (#1709, adaptive sync task 5; SYNCEX-01). Written
-- only by `watchtower channels exclude|include` (db.SetSyncExcluded), except
-- that the sync's catch-up moves catchup_to down and clears both bounds.
--   sync_excluded      1 = the sync stores no new messages of the channel,
--                      except those mentioning the account's user
--   excluded_at        when Stop syncing began (UTC, RFC 3339)
--   catchup_from       Sync again's pending catch-up: its fixed lower bound
--                      (unix seconds); NULL = no catch-up pending
--   catchup_to         its moving upper bound, walked down page by page
--   muted_by_exclusion 1 = Stop syncing set the AI mute, so Sync again lifts it
--   muted_at           when the AI mute turned on ('' = not muted)
ALTER TABLE channel_settings ADD COLUMN sync_excluded INTEGER NOT NULL DEFAULT 0;
ALTER TABLE channel_settings ADD COLUMN excluded_at TEXT NOT NULL DEFAULT '';
ALTER TABLE channel_settings ADD COLUMN catchup_from REAL;
ALTER TABLE channel_settings ADD COLUMN catchup_to REAL;
ALTER TABLE channel_settings ADD COLUMN muted_by_exclusion INTEGER NOT NULL DEFAULT 0;
ALTER TABLE channel_settings ADD COLUMN muted_at TEXT NOT NULL DEFAULT '';
-- A channel muted before this migration gets the migration time: the old
-- mute writers did not always touch updated_at, so it may be far older than
-- the mute and would bring the "muted 30+ days" suggestion too early.
UPDATE channel_settings SET muted_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE is_muted_for_llm = 1;

-- +goose Down
ALTER TABLE channel_settings DROP COLUMN muted_at;
ALTER TABLE channel_settings DROP COLUMN muted_by_exclusion;
ALTER TABLE channel_settings DROP COLUMN catchup_to;
ALTER TABLE channel_settings DROP COLUMN catchup_from;
ALTER TABLE channel_settings DROP COLUMN excluded_at;
ALTER TABLE channel_settings DROP COLUMN sync_excluded;
