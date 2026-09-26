-- +goose Up
-- Gmail as an inbox source: message store, auth telemetry, sync watermark,
-- and two new inbox trigger types (email_received / email_cc).

CREATE TABLE IF NOT EXISTS gmail_messages (
    id             TEXT PRIMARY KEY,              -- Gmail message ID
    thread_id      TEXT NOT NULL DEFAULT '',
    from_email     TEXT NOT NULL DEFAULT '',
    from_name      TEXT NOT NULL DEFAULT '',
    to_json        TEXT NOT NULL DEFAULT '[]',    -- JSON array of recipient emails (To)
    cc_json        TEXT NOT NULL DEFAULT '[]',    -- JSON array of recipient emails (Cc)
    subject        TEXT NOT NULL DEFAULT '',
    snippet        TEXT NOT NULL DEFAULT '',      -- Gmail-provided preview (~200 chars)
    body_text      TEXT NOT NULL DEFAULT '',      -- full plain-text body (truncated at sync)
    internal_date  TEXT NOT NULL DEFAULT '',      -- ISO8601 message time
    labels_json    TEXT NOT NULL DEFAULT '[]',    -- JSON array of Gmail label IDs
    is_unread      INTEGER NOT NULL DEFAULT 0,
    permalink      TEXT NOT NULL DEFAULT '',
    synced_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_gmail_messages_thread ON gmail_messages(thread_id);
CREATE INDEX IF NOT EXISTS idx_gmail_messages_synced ON gmail_messages(synced_at);

CREATE TABLE IF NOT EXISTS gmail_auth_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    status TEXT NOT NULL DEFAULT 'ok',
    error TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT OR IGNORE INTO gmail_auth_state (id, status, error) VALUES (1, 'ok', '');

ALTER TABLE workspace ADD COLUMN gmail_last_internal_date REAL NOT NULL DEFAULT 0;

-- Expand inbox_items.trigger_type CHECK (recreation dance; see 00002).
PRAGMA defer_foreign_keys = ON;

CREATE TABLE inbox_items_new (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id      TEXT NOT NULL,
    message_ts      TEXT NOT NULL,
    thread_ts       TEXT NOT NULL DEFAULT '',
    sender_user_id  TEXT NOT NULL,
    trigger_type    TEXT NOT NULL CHECK(trigger_type IN (
        'mention','dm','thread_reply','reaction',
        'jira_assigned','jira_comment_mention','jira_comment_watching','jira_status_change','jira_priority_change',
        'calendar_invite','calendar_time_change','calendar_cancelled',
        'decision_made','briefing_ready',
        'target_due',
        'stream',
        'email_received','email_cc'
    )),
    snippet         TEXT NOT NULL DEFAULT '',
    context         TEXT NOT NULL DEFAULT '',
    raw_text        TEXT NOT NULL DEFAULT '',
    permalink       TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','resolved','dismissed','snoozed')),
    priority        TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('high','medium','low')),
    ai_reason       TEXT NOT NULL DEFAULT '',
    resolved_reason TEXT NOT NULL DEFAULT '',
    snooze_until    TEXT NOT NULL DEFAULT '',
    waiting_user_ids TEXT NOT NULL DEFAULT '[]',
    target_id       INTEGER,
    read_at         TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    item_class      TEXT NOT NULL DEFAULT 'actionable' CHECK(item_class IN ('actionable','ambient')),
    archived_at     TEXT,
    archive_reason  TEXT DEFAULT '' CHECK(archive_reason IN ('','resolved','seen_expired','stale','dismissed')),
    why_matters     TEXT NOT NULL DEFAULT '',
    thread_digest   TEXT NOT NULL DEFAULT '',
    draft_reply     TEXT NOT NULL DEFAULT '',
    card_status     TEXT NOT NULL DEFAULT 'none' CHECK(card_status IN ('none','ready','failed')),
    card_generated_at TEXT,
    composed_at     TEXT,
    UNIQUE(channel_id, message_ts)
);

INSERT INTO inbox_items_new SELECT * FROM inbox_items;
DROP TABLE inbox_items;
ALTER TABLE inbox_items_new RENAME TO inbox_items;

CREATE INDEX IF NOT EXISTS idx_inbox_items_status ON inbox_items(status);
CREATE INDEX IF NOT EXISTS idx_inbox_items_priority ON inbox_items(priority);
CREATE INDEX IF NOT EXISTS idx_inbox_items_updated ON inbox_items(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_inbox_items_sender ON inbox_items(sender_user_id);
CREATE INDEX IF NOT EXISTS idx_inbox_items_snooze ON inbox_items(snooze_until);
CREATE INDEX IF NOT EXISTS idx_inbox_items_class_status ON inbox_items(item_class, status);
CREATE INDEX IF NOT EXISTS idx_inbox_items_archived ON inbox_items(archived_at);

-- +goose Down
PRAGMA defer_foreign_keys = ON;

CREATE TABLE inbox_items_old (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id      TEXT NOT NULL,
    message_ts      TEXT NOT NULL,
    thread_ts       TEXT NOT NULL DEFAULT '',
    sender_user_id  TEXT NOT NULL,
    trigger_type    TEXT NOT NULL CHECK(trigger_type IN (
        'mention','dm','thread_reply','reaction',
        'jira_assigned','jira_comment_mention','jira_comment_watching','jira_status_change','jira_priority_change',
        'calendar_invite','calendar_time_change','calendar_cancelled',
        'decision_made','briefing_ready',
        'target_due',
        'stream'
    )),
    snippet         TEXT NOT NULL DEFAULT '',
    context         TEXT NOT NULL DEFAULT '',
    raw_text        TEXT NOT NULL DEFAULT '',
    permalink       TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','resolved','dismissed','snoozed')),
    priority        TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('high','medium','low')),
    ai_reason       TEXT NOT NULL DEFAULT '',
    resolved_reason TEXT NOT NULL DEFAULT '',
    snooze_until    TEXT NOT NULL DEFAULT '',
    waiting_user_ids TEXT NOT NULL DEFAULT '[]',
    target_id       INTEGER,
    read_at         TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    item_class      TEXT NOT NULL DEFAULT 'actionable' CHECK(item_class IN ('actionable','ambient')),
    archived_at     TEXT,
    archive_reason  TEXT DEFAULT '' CHECK(archive_reason IN ('','resolved','seen_expired','stale','dismissed')),
    why_matters     TEXT NOT NULL DEFAULT '',
    thread_digest   TEXT NOT NULL DEFAULT '',
    draft_reply     TEXT NOT NULL DEFAULT '',
    card_status     TEXT NOT NULL DEFAULT 'none' CHECK(card_status IN ('none','ready','failed')),
    card_generated_at TEXT,
    composed_at     TEXT,
    UNIQUE(channel_id, message_ts)
);

INSERT INTO inbox_items_old SELECT * FROM inbox_items WHERE trigger_type NOT IN ('email_received','email_cc');
DROP TABLE inbox_items;
ALTER TABLE inbox_items_old RENAME TO inbox_items;

CREATE INDEX IF NOT EXISTS idx_inbox_items_status ON inbox_items(status);
CREATE INDEX IF NOT EXISTS idx_inbox_items_priority ON inbox_items(priority);
CREATE INDEX IF NOT EXISTS idx_inbox_items_updated ON inbox_items(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_inbox_items_sender ON inbox_items(sender_user_id);
CREATE INDEX IF NOT EXISTS idx_inbox_items_snooze ON inbox_items(snooze_until);
CREATE INDEX IF NOT EXISTS idx_inbox_items_class_status ON inbox_items(item_class, status);
CREATE INDEX IF NOT EXISTS idx_inbox_items_archived ON inbox_items(archived_at);

ALTER TABLE workspace DROP COLUMN gmail_last_internal_date;
DROP TABLE IF EXISTS gmail_auth_state;
DROP TABLE IF EXISTS gmail_messages;
