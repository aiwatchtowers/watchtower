-- +goose NO TRANSACTION
-- +goose Up
PRAGMA foreign_keys = OFF;

-- 1. Account table (the Google analog of email_accounts; status/error here
--    replace the calendar_auth_state / gmail_auth_state singletons).
CREATE TABLE IF NOT EXISTS google_accounts (
    id                             INTEGER PRIMARY KEY AUTOINCREMENT,
    email                          TEXT NOT NULL DEFAULT '',
    label                          TEXT NOT NULL DEFAULT '',
    client_id                      TEXT NOT NULL DEFAULT '',  -- non-secret half of a custom OAuth client; '' = build-time default
    calendar_enabled               INTEGER NOT NULL DEFAULT 0,
    gmail_enabled                  INTEGER NOT NULL DEFAULT 0,
    status                         TEXT NOT NULL DEFAULT 'ok',  -- ok | error | revoked
    error                          TEXT NOT NULL DEFAULT '',
    gmail_last_internal_date       REAL NOT NULL DEFAULT 0,   -- per-account Gmail sync watermark (was workspace.gmail_last_internal_date)
    memory_gmail_last_extracted_ts REAL NOT NULL DEFAULT 0,   -- per-account memory extraction watermark (was workspace.memory_gmail_last_extracted_ts)
    created_at                     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at                     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- 2. Seed account #1 when legacy Google data exists (token-only installs are
--    seeded in Go by ensureLegacyGoogleAccount — SQL can't see token files).
INSERT INTO google_accounts (email, label, calendar_enabled, gmail_enabled,
                             gmail_last_internal_date, memory_gmail_last_extracted_ts)
SELECT '', '',
       CASE WHEN EXISTS (SELECT 1 FROM calendar_calendars
                         WHERE id NOT LIKE 'caldav:%' AND id NOT LIKE 'ics:%') THEN 1 ELSE 0 END,
       CASE WHEN EXISTS (SELECT 1 FROM gmail_messages) THEN 1 ELSE 0 END,
       COALESCE((SELECT gmail_last_internal_date FROM workspace LIMIT 1), 0),
       COALESCE((SELECT memory_gmail_last_extracted_ts FROM workspace LIMIT 1), 0)
WHERE EXISTS (SELECT 1 FROM gmail_messages)
   OR EXISTS (SELECT 1 FROM calendar_calendars WHERE id NOT LIKE 'caldav:%' AND id NOT LIKE 'ics:%')
   OR COALESCE((SELECT gmail_last_internal_date FROM workspace LIMIT 1), 0) > 0;

-- 3. gmail_messages: add account_id, PK becomes (account_id, id).
CREATE TABLE gmail_messages_new (
    account_id     INTEGER NOT NULL REFERENCES google_accounts(id) ON DELETE CASCADE,
    id             TEXT NOT NULL,
    thread_id      TEXT NOT NULL DEFAULT '',
    from_email     TEXT NOT NULL DEFAULT '',
    from_name      TEXT NOT NULL DEFAULT '',
    to_json        TEXT NOT NULL DEFAULT '[]',
    cc_json        TEXT NOT NULL DEFAULT '[]',
    subject        TEXT NOT NULL DEFAULT '',
    snippet        TEXT NOT NULL DEFAULT '',
    body_text      TEXT NOT NULL DEFAULT '',
    internal_date  TEXT NOT NULL DEFAULT '',
    labels_json    TEXT NOT NULL DEFAULT '[]',
    is_unread      INTEGER NOT NULL DEFAULT 0,
    permalink      TEXT NOT NULL DEFAULT '',
    synced_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (account_id, id)
);
INSERT INTO gmail_messages_new
SELECT 1, id, thread_id, from_email, from_name, to_json, cc_json, subject, snippet,
       body_text, internal_date, labels_json, is_unread, permalink, synced_at, updated_at
FROM gmail_messages;
DROP TABLE gmail_messages;
ALTER TABLE gmail_messages_new RENAME TO gmail_messages;
CREATE INDEX IF NOT EXISTS idx_gmail_messages_thread ON gmail_messages(thread_id);
CREATE INDEX IF NOT EXISTS idx_gmail_messages_synced ON gmail_messages(synced_at);

-- 4. calendar_calendars: add account_id (NULL for caldav/ics rows).
ALTER TABLE calendar_calendars ADD COLUMN account_id INTEGER REFERENCES google_accounts(id);
UPDATE calendar_calendars SET account_id = 1
WHERE id NOT LIKE 'caldav:%' AND id NOT LIKE 'ics:%'
  AND EXISTS (SELECT 1 FROM google_accounts WHERE id = 1);

-- 5. calendar_events: dedup enabler.
ALTER TABLE calendar_events ADD COLUMN ical_uid TEXT NOT NULL DEFAULT '';

-- 6. Inbox rewrite: Gmail items get account-scoped channel ids.
UPDATE inbox_items SET channel_id = 'gmail:1:' || channel_id
WHERE trigger_type IN ('email_received', 'email_cc')
  AND channel_id NOT LIKE 'imap:%' AND channel_id NOT LIKE 'gmail:%';
UPDATE inbox_learned_rules SET scope_key = 'channel:gmail:1:' || substr(scope_key, 9)
WHERE scope_key LIKE 'channel:%'
  AND EXISTS (SELECT 1 FROM inbox_items
              WHERE inbox_items.channel_id = 'gmail:1:' || substr(inbox_learned_rules.scope_key, 9)
                AND inbox_items.trigger_type IN ('email_received', 'email_cc'));

-- 7. Retire singletons and workspace scalars.
DROP TABLE IF EXISTS calendar_auth_state;
DROP TABLE IF EXISTS gmail_auth_state;
ALTER TABLE workspace DROP COLUMN gmail_last_internal_date;
ALTER TABLE workspace DROP COLUMN memory_gmail_last_extracted_ts;

PRAGMA foreign_keys = ON;

-- +goose Down
PRAGMA foreign_keys = OFF;
ALTER TABLE workspace ADD COLUMN gmail_last_internal_date REAL NOT NULL DEFAULT 0;
ALTER TABLE workspace ADD COLUMN memory_gmail_last_extracted_ts REAL NOT NULL DEFAULT 0;
UPDATE workspace SET
    gmail_last_internal_date = COALESCE((SELECT gmail_last_internal_date FROM google_accounts WHERE id = 1), 0),
    memory_gmail_last_extracted_ts = COALESCE((SELECT memory_gmail_last_extracted_ts FROM google_accounts WHERE id = 1), 0);
CREATE TABLE IF NOT EXISTS calendar_auth_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    status TEXT NOT NULL DEFAULT 'ok',
    error TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE TABLE IF NOT EXISTS gmail_auth_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    status TEXT NOT NULL DEFAULT 'ok',
    error TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT OR IGNORE INTO gmail_auth_state (id, status, error) VALUES (1, 'ok', '');
UPDATE inbox_learned_rules SET scope_key = 'channel:' || substr(scope_key, 17)
WHERE scope_key LIKE 'channel:gmail:1:%';
UPDATE inbox_items SET channel_id = substr(channel_id, 9)
WHERE channel_id LIKE 'gmail:1:%';
CREATE TABLE gmail_messages_old (
    id             TEXT PRIMARY KEY,
    thread_id      TEXT NOT NULL DEFAULT '',
    from_email     TEXT NOT NULL DEFAULT '',
    from_name      TEXT NOT NULL DEFAULT '',
    to_json        TEXT NOT NULL DEFAULT '[]',
    cc_json        TEXT NOT NULL DEFAULT '[]',
    subject        TEXT NOT NULL DEFAULT '',
    snippet        TEXT NOT NULL DEFAULT '',
    body_text      TEXT NOT NULL DEFAULT '',
    internal_date  TEXT NOT NULL DEFAULT '',
    labels_json    TEXT NOT NULL DEFAULT '[]',
    is_unread      INTEGER NOT NULL DEFAULT 0,
    permalink      TEXT NOT NULL DEFAULT '',
    synced_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT OR IGNORE INTO gmail_messages_old
SELECT id, thread_id, from_email, from_name, to_json, cc_json, subject, snippet,
       body_text, internal_date, labels_json, is_unread, permalink, synced_at, updated_at
FROM gmail_messages WHERE account_id = 1;
DROP TABLE gmail_messages;
ALTER TABLE gmail_messages_old RENAME TO gmail_messages;
CREATE INDEX IF NOT EXISTS idx_gmail_messages_thread ON gmail_messages(thread_id);
CREATE INDEX IF NOT EXISTS idx_gmail_messages_synced ON gmail_messages(synced_at);
-- calendar_calendars: SQLite can drop a column with an inbound-FK parent intact under foreign_keys=OFF
ALTER TABLE calendar_calendars DROP COLUMN account_id;
DROP TABLE IF EXISTS google_accounts;
ALTER TABLE calendar_events DROP COLUMN ical_uid;
PRAGMA foreign_keys = ON;
