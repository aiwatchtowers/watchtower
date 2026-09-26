-- +goose Up
-- Adds secretary profile to workspace and card-generation columns to inbox_items.
-- New columns: why_matters, thread_digest, draft_reply, card_status, card_generated_at.
-- New trigger_type: 'stream'.
-- The pinned column is KEPT; it is dropped in migration 00010.

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
    pinned          INTEGER NOT NULL DEFAULT 0,
    archived_at     TEXT,
    archive_reason  TEXT DEFAULT '' CHECK(archive_reason IN ('','resolved','seen_expired','stale','dismissed')),
    why_matters     TEXT NOT NULL DEFAULT '',
    thread_digest   TEXT NOT NULL DEFAULT '',
    draft_reply     TEXT NOT NULL DEFAULT '',
    card_status     TEXT NOT NULL DEFAULT 'none' CHECK(card_status IN ('none','ready','failed')),
    card_generated_at TEXT,
    UNIQUE(channel_id, message_ts)
);

INSERT INTO inbox_items_new (
    id, channel_id, message_ts, thread_ts, sender_user_id, trigger_type,
    snippet, context, raw_text, permalink, status, priority, ai_reason,
    resolved_reason, snooze_until, waiting_user_ids, target_id, read_at,
    created_at, updated_at, item_class, pinned, archived_at, archive_reason
) SELECT
    id, channel_id, message_ts, thread_ts, sender_user_id, trigger_type,
    snippet, context, raw_text, permalink, status, priority, ai_reason,
    resolved_reason, snooze_until, waiting_user_ids, target_id, read_at,
    created_at, updated_at, item_class, pinned, archived_at, archive_reason
FROM inbox_items;

DROP TABLE inbox_items;
ALTER TABLE inbox_items_new RENAME TO inbox_items;

CREATE INDEX IF NOT EXISTS idx_inbox_items_status ON inbox_items(status);
CREATE INDEX IF NOT EXISTS idx_inbox_items_priority ON inbox_items(priority);
CREATE INDEX IF NOT EXISTS idx_inbox_items_updated ON inbox_items(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_inbox_items_sender ON inbox_items(sender_user_id);
CREATE INDEX IF NOT EXISTS idx_inbox_items_snooze ON inbox_items(snooze_until);
CREATE INDEX IF NOT EXISTS idx_inbox_items_class_status ON inbox_items(item_class, status);
CREATE INDEX IF NOT EXISTS idx_inbox_items_pinned ON inbox_items(pinned) WHERE pinned = 1;
CREATE INDEX IF NOT EXISTS idx_inbox_items_archived ON inbox_items(archived_at);

ALTER TABLE workspace ADD COLUMN secretary_profile TEXT NOT NULL DEFAULT '';

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
        'target_due'
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
    pinned          INTEGER NOT NULL DEFAULT 0,
    archived_at     TEXT,
    archive_reason  TEXT DEFAULT '' CHECK(archive_reason IN ('','resolved','seen_expired','stale','dismissed')),
    UNIQUE(channel_id, message_ts)
);

INSERT INTO inbox_items_old (
    id, channel_id, message_ts, thread_ts, sender_user_id, trigger_type,
    snippet, context, raw_text, permalink, status, priority, ai_reason,
    resolved_reason, snooze_until, waiting_user_ids, target_id, read_at,
    created_at, updated_at, item_class, pinned, archived_at, archive_reason
) SELECT
    id, channel_id, message_ts, thread_ts, sender_user_id, trigger_type,
    snippet, context, raw_text, permalink, status, priority, ai_reason,
    resolved_reason, snooze_until, waiting_user_ids, target_id, read_at,
    created_at, updated_at, item_class, pinned, archived_at, archive_reason
FROM inbox_items WHERE trigger_type != 'stream';

DROP TABLE inbox_items;
ALTER TABLE inbox_items_old RENAME TO inbox_items;

CREATE INDEX IF NOT EXISTS idx_inbox_items_status ON inbox_items(status);
CREATE INDEX IF NOT EXISTS idx_inbox_items_priority ON inbox_items(priority);
CREATE INDEX IF NOT EXISTS idx_inbox_items_updated ON inbox_items(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_inbox_items_sender ON inbox_items(sender_user_id);
CREATE INDEX IF NOT EXISTS idx_inbox_items_snooze ON inbox_items(snooze_until);
CREATE INDEX IF NOT EXISTS idx_inbox_items_class_status ON inbox_items(item_class, status);
CREATE INDEX IF NOT EXISTS idx_inbox_items_pinned ON inbox_items(pinned) WHERE pinned = 1;
CREATE INDEX IF NOT EXISTS idx_inbox_items_archived ON inbox_items(archived_at);

ALTER TABLE workspace DROP COLUMN secretary_profile;
