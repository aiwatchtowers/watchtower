-- +goose Up
CREATE TABLE IF NOT EXISTS kb_dirty (
    source TEXT NOT NULL,              -- KB source name: slack | gmail | jira
    key    TEXT NOT NULL,              -- that source's document key (kb_documents.id)
    gen    INTEGER NOT NULL DEFAULT 0, -- bumped on every re-mark; the drain deletes only the gen it rendered
    PRIMARY KEY (source, key)
);
ALTER TABLE slack_accounts ADD COLUMN deletion_sweep_day TEXT NOT NULL DEFAULT '';
ALTER TABLE google_accounts ADD COLUMN deletions_checked_at TEXT NOT NULL DEFAULT '';

-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS messages_kb_dirty AFTER UPDATE OF text, is_deleted ON messages
WHEN OLD.text != NEW.text OR OLD.is_deleted != NEW.is_deleted
BEGIN
    INSERT INTO kb_dirty (source, key) VALUES ('slack',
        CASE WHEN COALESCE(NEW.thread_ts, '') != '' THEN 'slack:thread:' || NEW.channel_id || ':' || NEW.thread_ts
             ELSE 'slack:day:' || NEW.channel_id || ':' || date(NEW.ts_unix, 'unixepoch') END)
        ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1;
    INSERT INTO kb_dirty (source, key) VALUES ('slack',
        CASE WHEN COALESCE(OLD.thread_ts, '') != '' THEN 'slack:thread:' || OLD.channel_id || ':' || OLD.thread_ts
             ELSE 'slack:day:' || OLD.channel_id || ':' || date(OLD.ts_unix, 'unixepoch') END)
        ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1;
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS gmail_messages_kb_dirty AFTER DELETE ON gmail_messages
BEGIN
    INSERT INTO kb_dirty (source, key) VALUES ('gmail',
        'gmail:' || OLD.account_id || ':' || CASE WHEN OLD.thread_id = '' THEN 'm:' || OLD.id ELSE OLD.thread_id END)
        ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1;
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER IF NOT EXISTS jira_comments_kb_dirty AFTER DELETE ON jira_comments
BEGIN
    INSERT INTO kb_dirty (source, key) VALUES ('jira', 'jira:' || OLD.account_id || ':' || OLD.issue_key)
        ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1;
END;
-- +goose StatementEnd

-- +goose Down
DROP TRIGGER IF EXISTS jira_comments_kb_dirty;
DROP TRIGGER IF EXISTS gmail_messages_kb_dirty;
DROP TRIGGER IF EXISTS messages_kb_dirty;
ALTER TABLE google_accounts DROP COLUMN deletions_checked_at;
ALTER TABLE slack_accounts DROP COLUMN deletion_sweep_day;
DROP TABLE IF EXISTS kb_dirty;
