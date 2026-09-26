-- +goose Up
-- Multi-account IMAP/Outlook email source: one row per connected mailbox
-- (email_accounts) plus its synced messages (imap_messages). Purely additive
-- — the existing gmail_messages/gmail_auth_state tables and the Gmail
-- singleton flow are untouched. inbox_items.trigger_type already has
-- 'email_received'/'email_cc' (added by 00016), reused as-is.

CREATE TABLE IF NOT EXISTS email_accounts (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    provider       TEXT NOT NULL CHECK(provider IN ('imap','outlook')),
    email_address  TEXT NOT NULL DEFAULT '',
    host           TEXT NOT NULL DEFAULT '',
    port           INTEGER NOT NULL DEFAULT 0,
    security       TEXT NOT NULL DEFAULT 'ssl' CHECK(security IN ('ssl','starttls','none')),
    folder         TEXT NOT NULL DEFAULT 'INBOX',
    label          TEXT NOT NULL DEFAULT '',      -- user-facing display name
    status         TEXT NOT NULL DEFAULT 'ok',    -- ok | error | revoked
    error          TEXT NOT NULL DEFAULT '',
    last_uid       INTEGER NOT NULL DEFAULT 0,    -- sync watermark: highest IMAP UID synced
    uidvalidity    INTEGER NOT NULL DEFAULT 0,    -- IMAP UIDVALIDITY; a change means last_uid must reset
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE IF NOT EXISTS imap_messages (
    account_id     INTEGER NOT NULL REFERENCES email_accounts(id) ON DELETE CASCADE,
    uid            INTEGER NOT NULL,              -- IMAP UID; unique within (account_id, uidvalidity, uid)
    uidvalidity    INTEGER NOT NULL DEFAULT 0,    -- IMAP UIDVALIDITY epoch this uid was assigned under
    from_email     TEXT NOT NULL DEFAULT '',
    from_name      TEXT NOT NULL DEFAULT '',
    to_json        TEXT NOT NULL DEFAULT '[]',    -- JSON array of recipient emails (To)
    cc_json        TEXT NOT NULL DEFAULT '[]',    -- JSON array of recipient emails (Cc)
    subject        TEXT NOT NULL DEFAULT '',
    snippet        TEXT NOT NULL DEFAULT '',
    body_text      TEXT NOT NULL DEFAULT '',      -- full plain-text body (truncated at sync)
    internal_date  TEXT NOT NULL DEFAULT '',      -- ISO8601 message time
    is_unread      INTEGER NOT NULL DEFAULT 0,
    permalink      TEXT NOT NULL DEFAULT '',
    synced_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (account_id, uidvalidity, uid)
);
CREATE INDEX IF NOT EXISTS idx_imap_messages_synced ON imap_messages(synced_at);

-- +goose Down
DROP INDEX IF EXISTS idx_imap_messages_synced;
DROP TABLE IF EXISTS imap_messages;
DROP TABLE IF EXISTS email_accounts;
