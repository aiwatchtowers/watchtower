-- +goose Up
-- Images and web links become knowledge (spec
-- docs/superpowers/specs/2026-10-25-media-knowledge-design.md).
--
-- 1. media_state: one row; start_at is the migration's UTC time. Discovery
--    records nothing whose content is older, and the describe pass reads
--    only rows with content_at >= start_at (only new content, ask #566).
--    The knowledge-search fast-forward hook moves it to now.
-- 2. media_items: one row per image or link found on a synced parent. No
--    bytes, base64 or page body is ever stored (EXT-03). Each row hangs off
--    exactly one parent by a foreign key with ON DELETE CASCADE, so a
--    deleted or purged parent takes its descriptions along.
-- 3. Triggers: a row whose status or body changes to or from 'ok' marks its
--    parent's knowledge document in kb_dirty (the 00139 shape); the owner's
--    own image uploads (chat attachments, workbench target images) record a
--    pending item. The triggers read no other table.
CREATE TABLE media_state (
    id       INTEGER PRIMARY KEY CHECK (id = 1),
    start_at TEXT NOT NULL
);
INSERT INTO media_state (id, start_at) VALUES (1, strftime('%Y-%m-%dT%H:%M:%SZ','now'));

CREATE TABLE media_items (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    kind               TEXT NOT NULL CHECK (kind IN ('image','link')),
    parent_kind        TEXT NOT NULL CHECK (parent_kind IN ('slack','confluence','gmail','imap','chat','target')),
    parent_key         TEXT NOT NULL,
    slack_channel_id   TEXT,
    slack_ts           TEXT,
    ext_source_id      INTEGER,
    ext_id             TEXT,
    gmail_account_id   INTEGER,
    gmail_message_id   TEXT,
    imap_account_id    INTEGER,
    imap_uidvalidity   INTEGER,
    imap_uid           INTEGER,
    chat_attachment_id INTEGER REFERENCES chat_attachments(id) ON DELETE CASCADE,
    target_image_id    INTEGER REFERENCES project_target_images(id) ON DELETE CASCADE,
    anchor             TEXT NOT NULL DEFAULT '',
    locator            TEXT NOT NULL,
    fetch_url          TEXT NOT NULL DEFAULT '',
    name               TEXT NOT NULL DEFAULT '',
    media_type         TEXT NOT NULL DEFAULT '',
    size_bytes         INTEGER NOT NULL DEFAULT 0,
    content_key        TEXT NOT NULL DEFAULT '',
    scope              TEXT NOT NULL,
    from_owner         INTEGER NOT NULL DEFAULT 0,
    content_at         TEXT NOT NULL,
    status             TEXT NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','ok','skipped_type','skipped_junk','too_large','unreachable','unavailable','failed')),
    attempts           INTEGER NOT NULL DEFAULT 0,
    error              TEXT NOT NULL DEFAULT '',
    title              TEXT NOT NULL DEFAULT '',
    body               TEXT NOT NULL DEFAULT '',
    image_text         TEXT NOT NULL DEFAULT '',
    keys_json          TEXT NOT NULL DEFAULT '[]',
    kb_source          TEXT NOT NULL DEFAULT '',
    kb_ref             TEXT NOT NULL DEFAULT '',
    discovered_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    described_at       TEXT NOT NULL DEFAULT '',
    -- a row that could only wait (a source off, a reference not synced yet)
    -- is not listed again before this time ('' = now)
    next_try_at        TEXT NOT NULL DEFAULT '',
    UNIQUE (parent_key, kind, locator),
    FOREIGN KEY (slack_channel_id, slack_ts) REFERENCES messages(channel_id, ts) ON DELETE CASCADE,
    FOREIGN KEY (ext_source_id, ext_id) REFERENCES ext_documents(source_id, ext_id) ON DELETE CASCADE,
    FOREIGN KEY (gmail_account_id, gmail_message_id) REFERENCES gmail_messages(account_id, id) ON DELETE CASCADE,
    FOREIGN KEY (imap_account_id, imap_uidvalidity, imap_uid) REFERENCES imap_messages(account_id, uidvalidity, uid) ON DELETE CASCADE,
    -- exactly the parent kind's columns are set
    CHECK ((slack_channel_id IS NOT NULL) = (parent_kind = 'slack')
       AND (slack_ts IS NOT NULL) = (parent_kind = 'slack')
       AND (ext_source_id IS NOT NULL) = (parent_kind = 'confluence')
       AND (ext_id IS NOT NULL) = (parent_kind = 'confluence')
       AND (gmail_account_id IS NOT NULL) = (parent_kind = 'gmail')
       AND (gmail_message_id IS NOT NULL) = (parent_kind = 'gmail')
       AND (imap_account_id IS NOT NULL) = (parent_kind = 'imap')
       AND (imap_uidvalidity IS NOT NULL) = (parent_kind = 'imap')
       AND (imap_uid IS NOT NULL) = (parent_kind = 'imap')
       AND (chat_attachment_id IS NOT NULL) = (parent_kind = 'chat')
       AND (target_image_id IS NOT NULL) = (parent_kind = 'target'))
);
CREATE INDEX idx_media_items_pending ON media_items(status, from_owner, content_at);
CREATE INDEX idx_media_items_content ON media_items(content_key, scope);
CREATE INDEX idx_media_items_slack ON media_items(slack_channel_id, slack_ts);
CREATE INDEX idx_media_items_ext ON media_items(ext_source_id, ext_id);
CREATE INDEX idx_media_items_gmail ON media_items(gmail_account_id, gmail_message_id);
CREATE INDEX idx_media_items_imap ON media_items(imap_account_id, imap_uidvalidity, imap_uid);
CREATE INDEX idx_media_items_chat ON media_items(chat_attachment_id);
CREATE INDEX idx_media_items_target ON media_items(target_image_id);
-- the doc-links scan's described_at|rowid cursor (internal/doclinks/linkscan)
CREATE INDEX idx_media_items_described ON media_items(described_at);

-- +goose StatementBegin
CREATE TRIGGER media_items_kb_dirty_upd AFTER UPDATE OF status, body, kb_source, kb_ref ON media_items
WHEN (OLD.status = 'ok' OR NEW.status = 'ok') AND (NEW.kb_ref != '' OR OLD.kb_ref != '')
BEGIN
    INSERT INTO kb_dirty (source, key) SELECT NEW.kb_source, NEW.kb_ref WHERE NEW.kb_ref != ''
        ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1;
    -- an ok row moved to another document: the old one loses its section
    INSERT INTO kb_dirty (source, key) SELECT OLD.kb_source, OLD.kb_ref
        WHERE OLD.status = 'ok' AND OLD.kb_ref != ''
          AND (OLD.kb_source != NEW.kb_source OR OLD.kb_ref != NEW.kb_ref)
        ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1;
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER media_items_kb_dirty_del AFTER DELETE ON media_items
WHEN OLD.status = 'ok' AND OLD.kb_ref != ''
BEGIN
    INSERT INTO kb_dirty (source, key) VALUES (OLD.kb_source, OLD.kb_ref)
        ON CONFLICT (source, key) DO UPDATE SET gen = gen + 1;
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER chat_attachments_media AFTER INSERT ON chat_attachments
WHEN NEW.conversation_id IS NOT NULL
 AND NEW.mime IN ('image/png','image/jpeg','image/gif','image/webp')
BEGIN
    INSERT INTO media_items (kind, parent_kind, parent_key, chat_attachment_id, locator, name,
                             media_type, size_bytes, scope, from_owner, content_at)
    VALUES ('image', 'chat', 'chat:' || NEW.id, NEW.id, NEW.path, NEW.name,
            NEW.mime, NEW.size, 'owner', 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER project_target_images_media AFTER INSERT ON project_target_images
BEGIN
    INSERT INTO media_items (kind, parent_kind, parent_key, target_image_id, locator, name,
                             media_type, size_bytes, scope, from_owner, content_at)
    VALUES ('image', 'target', 'target:' || NEW.id, NEW.id, NEW.path, NEW.file_name,
            NEW.mime, NEW.size, 'owner', 1, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
END;
-- +goose StatementEnd

-- +goose Down
DROP TRIGGER IF EXISTS project_target_images_media;
DROP TRIGGER IF EXISTS chat_attachments_media;
DROP TRIGGER IF EXISTS media_items_kb_dirty_del;
DROP TRIGGER IF EXISTS media_items_kb_dirty_upd;
DROP INDEX IF EXISTS idx_media_items_described;
DROP TABLE IF EXISTS media_items;
DROP TABLE IF EXISTS media_state;
