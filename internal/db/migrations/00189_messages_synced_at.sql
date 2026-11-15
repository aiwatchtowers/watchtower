-- +goose Up
-- Ingestion-ordered Slack inbox detection (#1709, adaptive sync task 4): when
-- a message row was first stored (unix seconds). The Slack detectors compare
-- the inbox watermark with it, so a message stored after the watermark passed
-- its post time is still detected. Existing rows take their post time; the
-- backfill runs before the trigger exists.
ALTER TABLE messages ADD COLUMN synced_at REAL NOT NULL DEFAULT 0;
UPDATE messages SET synced_at = ts_unix;
CREATE INDEX idx_messages_synced_at ON messages(synced_at);

-- The account's first sync attempt: older messages a sync stores are stamped
-- with their post time, so a first sync never floods the Inbox. Existing
-- accounts start from the migration.
ALTER TABLE slack_accounts ADD COLUMN first_cycle_at TEXT NOT NULL DEFAULT '';
UPDATE slack_accounts SET first_cycle_at = strftime('%Y-%m-%dT%H:%M:%SZ','now');

-- Any insert that does not stamp synced_at (every writer except the sync,
-- and test fixtures) takes the post time, so it is detected exactly as before
-- this column existed. An upsert's DO UPDATE branch fires UPDATE triggers
-- only, so an edit or a tombstone never moves it.
-- +goose StatementBegin
CREATE TRIGGER messages_synced_at_fill AFTER INSERT ON messages
WHEN NEW.synced_at = 0
BEGIN
  UPDATE messages SET synced_at = NEW.ts_unix WHERE rowid = NEW.rowid;
END;
-- +goose StatementEnd

-- +goose Down
DROP TRIGGER messages_synced_at_fill;
ALTER TABLE slack_accounts DROP COLUMN first_cycle_at;
DROP INDEX idx_messages_synced_at;
ALTER TABLE messages DROP COLUMN synced_at;
