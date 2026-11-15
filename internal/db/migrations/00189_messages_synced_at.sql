-- +goose Up
-- Ingestion-ordered Slack inbox detection (#1709, adaptive sync task 4): when
-- a message row was first stored (unix seconds), written by the Slack sync on
-- insert only. 0 means unstamped (every row stored before this migration, any
-- other writer) and reads as the post time, so existing rows are not rewritten:
-- a rewrite of every message took 5-7 s on a synthetic 2M-row plaintext file,
-- too close to the Desktop's 30 s `db migrate` limit once SQLCipher and WAL
-- are added. The Slack detectors compare the inbox watermark with the
-- expression this index covers (sinceStored in internal/db/inbox.go).
ALTER TABLE messages ADD COLUMN synced_at REAL NOT NULL DEFAULT 0;
CREATE INDEX idx_messages_synced_at ON messages(CASE WHEN synced_at = 0 THEN ts_unix ELSE synced_at END);

-- The account's first sync attempt: older messages a sync stores are stamped
-- with their post time, so a first sync never floods the Inbox. Existing
-- accounts start from the migration.
ALTER TABLE slack_accounts ADD COLUMN first_cycle_at TEXT NOT NULL DEFAULT '';
UPDATE slack_accounts SET first_cycle_at = strftime('%Y-%m-%dT%H:%M:%SZ','now');

-- +goose Down
ALTER TABLE slack_accounts DROP COLUMN first_cycle_at;
DROP INDEX idx_messages_synced_at;
ALTER TABLE messages DROP COLUMN synced_at;
