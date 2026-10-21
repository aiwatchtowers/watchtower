-- +goose Up
-- Search indexes keyed by row (board #872). messages_fts and transcripts_fts
-- were addressed by their UNINDEXED columns, so every trigger write scanned
-- the whole index. Both are now keyed by the source row's rowid, an O(log n)
-- lookup. Columns, tokenizer and contents stay as they were: readers do not
-- change.
--
-- messages: the old index is kept as messages_fts_legacy until the resumable
-- fill (RebuildMessagesSearch) has copied every indexable message into the
-- new one; filling it here would outlast the Desktop's migrate timeout. The
-- old triggers are dropped before the rename, which would otherwise rewrite
-- their bodies to point at the legacy table. The pending key is set
-- unconditionally; Open drops the legacy table and the key again when no
-- message is indexable (dropEmptyMessagesSearchLegacy), which SQL here cannot
-- express.
DROP TRIGGER IF EXISTS messages_ai;
DROP TRIGGER IF EXISTS messages_au;
DROP TRIGGER IF EXISTS messages_ad;

ALTER TABLE messages_fts RENAME TO messages_fts_legacy;

CREATE VIRTUAL TABLE messages_fts USING fts5(
    text,
    channel_id UNINDEXED,
    ts UNINDEXED,
    user_id UNINDEXED,
    tokenize='porter unicode61'
);

-- The insert trigger deletes first: a stray index row left under a reused
-- rowid must not become a second hit.
-- +goose StatementBegin
CREATE TRIGGER messages_ai AFTER INSERT ON messages
WHEN NEW.text != '' AND NEW.is_deleted = 0
BEGIN
    DELETE FROM messages_fts WHERE rowid = NEW.rowid;
    INSERT INTO messages_fts(rowid, text, channel_id, ts, user_id)
    VALUES (NEW.rowid, NEW.text, NEW.channel_id, NEW.ts, NEW.user_id);
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER messages_ad AFTER DELETE ON messages
BEGIN
    DELETE FROM messages_fts WHERE rowid = OLD.rowid;
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER messages_au AFTER UPDATE OF text, is_deleted ON messages
WHEN OLD.text != NEW.text OR OLD.is_deleted != NEW.is_deleted
BEGIN
    DELETE FROM messages_fts WHERE rowid = OLD.rowid;
    INSERT INTO messages_fts(rowid, text, channel_id, ts, user_id)
    SELECT NEW.rowid, NEW.text, NEW.channel_id, NEW.ts, NEW.user_id
    WHERE NEW.text != '' AND NEW.is_deleted = 0;
END;
-- +goose StatementEnd

INSERT OR REPLACE INTO db_maintenance(key, value) VALUES ('fts_rebuild_pending', '1');

-- transcripts: small enough to rebuild in place.
DROP TRIGGER IF EXISTS meeting_transcripts_ai;
DROP TRIGGER IF EXISTS meeting_transcripts_au;
DROP TRIGGER IF EXISTS meeting_transcripts_ad;
DROP TABLE IF EXISTS transcripts_fts;

CREATE VIRTUAL TABLE transcripts_fts USING fts5(
    text,
    transcript_id UNINDEXED,
    title UNINDEXED,
    tokenize='porter unicode61'
);

-- +goose StatementBegin
CREATE TRIGGER meeting_transcripts_ai AFTER INSERT ON meeting_transcripts
WHEN NEW.transcript_text != ''
BEGIN
    DELETE FROM transcripts_fts WHERE rowid = NEW.id;
    INSERT INTO transcripts_fts(rowid, text, transcript_id, title)
    VALUES (NEW.id, NEW.transcript_text, NEW.id, NEW.title);
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER meeting_transcripts_ad AFTER DELETE ON meeting_transcripts
BEGIN
    DELETE FROM transcripts_fts WHERE rowid = OLD.id;
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER meeting_transcripts_au AFTER UPDATE OF transcript_text, title ON meeting_transcripts
WHEN OLD.transcript_text != NEW.transcript_text OR OLD.title != NEW.title
BEGIN
    DELETE FROM transcripts_fts WHERE rowid = OLD.id;
    INSERT INTO transcripts_fts(rowid, text, transcript_id, title)
    SELECT NEW.id, NEW.transcript_text, NEW.id, NEW.title
    WHERE NEW.transcript_text != '';
END;
-- +goose StatementEnd

INSERT INTO transcripts_fts(rowid, text, transcript_id, title)
SELECT id, transcript_text, id, title FROM meeting_transcripts WHERE transcript_text != '';

-- +goose Down
-- Back to the column-keyed indexes of 00001 and 00052, rebuilt from their
-- source tables.
DROP TRIGGER IF EXISTS messages_ai;
DROP TRIGGER IF EXISTS messages_au;
DROP TRIGGER IF EXISTS messages_ad;
DROP TABLE IF EXISTS messages_fts;
DROP TABLE IF EXISTS messages_fts_legacy;

CREATE VIRTUAL TABLE messages_fts USING fts5(
    text,
    channel_id UNINDEXED,
    ts UNINDEXED,
    user_id UNINDEXED,
    tokenize='porter unicode61'
);

-- +goose StatementBegin
CREATE TRIGGER messages_ai AFTER INSERT ON messages
WHEN NEW.text != '' AND NEW.is_deleted = 0
BEGIN
    DELETE FROM messages_fts WHERE channel_id = NEW.channel_id AND ts = NEW.ts;
    INSERT INTO messages_fts(text, channel_id, ts, user_id)
    VALUES (NEW.text, NEW.channel_id, NEW.ts, NEW.user_id);
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER messages_ad AFTER DELETE ON messages
BEGIN
    DELETE FROM messages_fts WHERE channel_id = OLD.channel_id AND ts = OLD.ts;
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER messages_au AFTER UPDATE OF text, is_deleted ON messages
WHEN OLD.text != NEW.text OR OLD.is_deleted != NEW.is_deleted
BEGIN
    DELETE FROM messages_fts WHERE channel_id = OLD.channel_id AND ts = OLD.ts;
    INSERT INTO messages_fts(text, channel_id, ts, user_id)
    SELECT NEW.text, NEW.channel_id, NEW.ts, NEW.user_id
    WHERE NEW.text != '' AND NEW.is_deleted = 0;
END;
-- +goose StatementEnd

INSERT INTO messages_fts(text, channel_id, ts, user_id)
SELECT text, channel_id, ts, user_id FROM messages WHERE text != '' AND is_deleted = 0;

DELETE FROM db_maintenance WHERE key IN ('fts_rebuild_pending', 'fts_rebuild_cursor_messages');

DROP TRIGGER IF EXISTS meeting_transcripts_ai;
DROP TRIGGER IF EXISTS meeting_transcripts_au;
DROP TRIGGER IF EXISTS meeting_transcripts_ad;
DROP TABLE IF EXISTS transcripts_fts;

CREATE VIRTUAL TABLE transcripts_fts USING fts5(
    text,
    transcript_id UNINDEXED,
    title UNINDEXED,
    tokenize='porter unicode61'
);

-- +goose StatementBegin
CREATE TRIGGER meeting_transcripts_ai AFTER INSERT ON meeting_transcripts
WHEN NEW.transcript_text != ''
BEGIN
    DELETE FROM transcripts_fts WHERE transcript_id = NEW.id;
    INSERT INTO transcripts_fts(text, transcript_id, title)
    VALUES (NEW.transcript_text, NEW.id, NEW.title);
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER meeting_transcripts_ad AFTER DELETE ON meeting_transcripts
BEGIN
    DELETE FROM transcripts_fts WHERE transcript_id = OLD.id;
END;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE TRIGGER meeting_transcripts_au AFTER UPDATE OF transcript_text, title ON meeting_transcripts
WHEN OLD.transcript_text != NEW.transcript_text OR OLD.title != NEW.title
BEGIN
    DELETE FROM transcripts_fts WHERE transcript_id = OLD.id;
    INSERT INTO transcripts_fts(text, transcript_id, title)
    SELECT NEW.transcript_text, NEW.id, NEW.title
    WHERE NEW.transcript_text != '';
END;
-- +goose StatementEnd

INSERT INTO transcripts_fts(text, transcript_id, title)
SELECT transcript_text, id, title FROM meeting_transcripts WHERE transcript_text != '';
