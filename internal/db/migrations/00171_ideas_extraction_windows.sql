-- +goose Up
-- Local input bounds/completion receipts for routed email/Jira extraction.
-- Outputs and progress commit together, including a valid empty extraction.
CREATE TABLE ideas_extraction_windows (
    source TEXT NOT NULL CHECK (source IN ('gmail', 'imap', 'jira')),
    account_id INTEGER NOT NULL,
    window_key TEXT NOT NULL,
    from_value TEXT NOT NULL,
    to_value TEXT NOT NULL,
    reached_value TEXT NOT NULL,
    complete INTEGER NOT NULL DEFAULT 0 CHECK (complete IN (0, 1)),
    PRIMARY KEY (source, account_id, window_key)
);


-- +goose StatementBegin
CREATE TRIGGER ideas_extraction_gmail_delete AFTER DELETE ON google_accounts
BEGIN
 DELETE FROM ideas_extraction_windows WHERE source='gmail' AND account_id=OLD.id;
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER ideas_extraction_gmail_reset AFTER UPDATE OF ideas_email_floor ON google_accounts WHEN NEW.ideas_email_floor = 0
BEGIN
 DELETE FROM ideas_extraction_windows WHERE source='gmail' AND account_id=OLD.id;
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER ideas_extraction_imap_delete AFTER DELETE ON email_accounts
BEGIN
 DELETE FROM ideas_extraction_windows WHERE source='imap' AND account_id=OLD.id;
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER ideas_extraction_imap_reset AFTER UPDATE OF ideas_email_floor ON email_accounts WHEN NEW.ideas_email_floor = 0
BEGIN
 DELETE FROM ideas_extraction_windows WHERE source='imap' AND account_id=OLD.id;
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER ideas_extraction_jira_delete AFTER DELETE ON jira_accounts
BEGIN
 DELETE FROM ideas_extraction_windows WHERE source='jira' AND account_id=OLD.id;
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER ideas_extraction_jira_reset AFTER UPDATE OF ideas_jira_floor ON jira_accounts WHEN NEW.ideas_jira_floor = ''
BEGIN
 DELETE FROM ideas_extraction_windows WHERE source='jira' AND account_id=OLD.id;
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER ideas_extraction_history_reset AFTER DELETE ON history_backfill
BEGIN
 DELETE FROM ideas_extraction_windows WHERE source=OLD.source_kind AND account_id=OLD.account_id AND window_key <> 'forward';
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER ideas_extraction_output_reset AFTER DELETE ON stream_digests
BEGIN
 DELETE FROM ideas_extraction_windows WHERE source=OLD.source AND account_id=OLD.account_id;
END;
-- +goose StatementEnd


CREATE TABLE history_backfill_considered (
 account_id INTEGER NOT NULL,
 channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
 from_ts REAL NOT NULL,
 to_ts REAL NOT NULL,
 reached_ts REAL NOT NULL,
 PRIMARY KEY(account_id, channel_id, from_ts, to_ts)
);

-- +goose StatementBegin
CREATE TRIGGER history_backfill_considered_reset AFTER DELETE ON history_backfill
BEGIN
 DELETE FROM history_backfill_considered WHERE OLD.source_kind='slack' AND account_id=OLD.account_id;
END;
-- +goose StatementEnd


CREATE TABLE history_backfill_daily (
 account_id INTEGER NOT NULL,
 chunk_from REAL NOT NULL,
 chunk_to REAL NOT NULL,
 day_from REAL NOT NULL,
 digest_id INTEGER NOT NULL REFERENCES digests(id) ON DELETE CASCADE,
 PRIMARY KEY(account_id,chunk_from,chunk_to,day_from)
);

-- +goose StatementBegin
CREATE TRIGGER history_backfill_daily_reset AFTER DELETE ON history_backfill
BEGIN
 DELETE FROM history_backfill_daily WHERE OLD.source_kind='slack' AND account_id=OLD.account_id AND chunk_from >= OLD.floor_ts AND chunk_to <= OLD.upper_ts;
END;
-- +goose StatementEnd

-- +goose Down
DROP TRIGGER history_backfill_daily_reset;
DROP TABLE history_backfill_daily;

DROP TRIGGER history_backfill_considered_reset;
DROP TABLE history_backfill_considered;

DROP TRIGGER ideas_extraction_output_reset;
DROP TRIGGER ideas_extraction_history_reset;
DROP TRIGGER ideas_extraction_jira_reset;
DROP TRIGGER ideas_extraction_jira_delete;
DROP TRIGGER ideas_extraction_imap_reset;
DROP TRIGGER ideas_extraction_imap_delete;
DROP TRIGGER ideas_extraction_gmail_reset;
DROP TRIGGER ideas_extraction_gmail_delete;

DROP TABLE ideas_extraction_windows;
