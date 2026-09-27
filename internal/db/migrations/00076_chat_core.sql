-- +goose NO TRANSACTION
-- +goose Up
-- Chat core (spec docs/superpowers/specs/2026-09-26-chat-redesign-design.md §2.1).
-- Adopts the Swift-created chat_conversations/chat_messages into goose and adds
-- what the redesigned chat needs. Legacy installs reach this file with the
-- tables present — normalizeLegacyChatTables (Go, before goose) has already
-- added any missing context_type/context_id/turn_id, so the ALTERs below see
-- one known shape. NO TRANSACTION because the Down recreates both tables and
-- must switch foreign_keys off around that: a DROP of chat_conversations with
-- foreign_keys on would cascade-delete every message (the 00056 precedent).
-- A partial failure leaves the added columns behind and a re-run fails on
-- "duplicate column" — the accepted NO TRANSACTION trade-off (00049, 00056).
PRAGMA foreign_keys = OFF;

CREATE TABLE IF NOT EXISTS chat_conversations (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    title        TEXT NOT NULL DEFAULT '',
    session_id   TEXT,
    context_type TEXT,
    context_id   TEXT,
    created_at   REAL NOT NULL,
    updated_at   REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS chat_messages (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    role            TEXT NOT NULL,
    text            TEXT NOT NULL,
    created_at      REAL NOT NULL,
    turn_id         TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_chat_messages_conversation ON chat_messages(conversation_id);

-- One-time data fix formerly run by Swift ensureContextColumns.
UPDATE chat_conversations SET context_type = 'track' WHERE context_type = 'action_item';

CREATE TABLE chat_projects (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL,
    instructions TEXT NOT NULL DEFAULT '',
    created_at   REAL NOT NULL,
    updated_at   REAL NOT NULL,
    archived_at  REAL
);

ALTER TABLE chat_conversations ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
ALTER TABLE chat_conversations ADD COLUMN archived_at REAL;
ALTER TABLE chat_conversations ADD COLUMN title_source TEXT NOT NULL DEFAULT 'prefix'
    CHECK(title_source IN ('prefix','ai','user'));
ALTER TABLE chat_conversations ADD COLUMN provider TEXT;
ALTER TABLE chat_conversations ADD COLUMN model TEXT;
ALTER TABLE chat_conversations ADD COLUMN project_id INTEGER REFERENCES chat_projects(id) ON DELETE SET NULL;
ALTER TABLE chat_conversations ADD COLUMN active_leaf_message_id INTEGER;
CREATE INDEX IF NOT EXISTS idx_chat_conversations_project ON chat_conversations(project_id);

ALTER TABLE chat_messages ADD COLUMN status TEXT NOT NULL DEFAULT 'complete'
    CHECK(status IN ('complete','partial','error'));
ALTER TABLE chat_messages ADD COLUMN provider TEXT;
ALTER TABLE chat_messages ADD COLUMN model TEXT;
ALTER TABLE chat_messages ADD COLUMN tokens_in INTEGER;
ALTER TABLE chat_messages ADD COLUMN tokens_out INTEGER;
ALTER TABLE chat_messages ADD COLUMN parent_id INTEGER REFERENCES chat_messages(id) ON DELETE CASCADE;
ALTER TABLE chat_messages ADD COLUMN error_code TEXT;
CREATE INDEX IF NOT EXISTS idx_chat_messages_parent ON chat_messages(parent_id);

-- Legacy rows become a linear chain: each message's parent is the previous
-- message of its conversation in id order; the first stays a root (NULL).
-- active_leaf_message_id is deliberately NOT backfilled: NULL means "linear",
-- which keeps Discuss chats (still written without parent_id) whole.
UPDATE chat_messages SET parent_id = (
    SELECT MAX(p.id) FROM chat_messages p
    WHERE p.conversation_id = chat_messages.conversation_id AND p.id < chat_messages.id
) WHERE parent_id IS NULL;

CREATE TABLE chat_turn_steps (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id   INTEGER NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
    seq          INTEGER NOT NULL,
    tool_id      TEXT NOT NULL,
    name         TEXT NOT NULL,
    args_json    TEXT NOT NULL DEFAULT '{}',
    ok           INTEGER,
    summary      TEXT NOT NULL DEFAULT '',
    sources_json TEXT NOT NULL DEFAULT '[]',
    started_at   REAL NOT NULL,
    ended_at     REAL,
    UNIQUE(message_id, tool_id)
);

CREATE TABLE chat_attachments (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER REFERENCES chat_conversations(id) ON DELETE CASCADE,
    project_id      INTEGER REFERENCES chat_projects(id) ON DELETE CASCADE,
    message_id      INTEGER REFERENCES chat_messages(id) ON DELETE SET NULL,
    name            TEXT NOT NULL,
    mime            TEXT NOT NULL,
    size            INTEGER NOT NULL,
    path            TEXT NOT NULL,
    sha256          TEXT NOT NULL,
    created_at      REAL NOT NULL,
    CHECK ((conversation_id IS NULL) <> (project_id IS NULL))
);
CREATE INDEX IF NOT EXISTS idx_chat_attachments_conversation ON chat_attachments(conversation_id);
CREATE INDEX IF NOT EXISTS idx_chat_attachments_project ON chat_attachments(project_id);

CREATE TABLE chat_artifacts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    message_id      INTEGER NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
    artifact_key    TEXT NOT NULL,
    version         INTEGER NOT NULL,
    kind            TEXT NOT NULL CHECK(kind IN ('document','table','email','slack','event','code')),
    title           TEXT NOT NULL DEFAULT '',
    content         TEXT NOT NULL,
    meta_json       TEXT NOT NULL DEFAULT '{}',
    edited          INTEGER NOT NULL DEFAULT 0,
    created_at      REAL NOT NULL,
    UNIQUE(conversation_id, artifact_key, version)
);

CREATE TABLE chat_project_sources (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES chat_projects(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL CHECK(kind IN ('jira_project','slack_channel','target','track','person')),
    ref        TEXT NOT NULL,
    label      TEXT NOT NULL DEFAULT '',
    UNIQUE(project_id, kind, ref)
);

CREATE VIRTUAL TABLE chat_fts USING fts5(
    text,
    content='chat_messages', content_rowid='id',
    tokenize='porter unicode61 remove_diacritics 2'
);
CREATE VIRTUAL TABLE chat_title_fts USING fts5(
    title,
    content='chat_conversations', content_rowid='id',
    tokenize='porter unicode61 remove_diacritics 2'
);

-- +goose StatementBegin
CREATE TRIGGER chat_messages_fts_ai AFTER INSERT ON chat_messages BEGIN
    INSERT INTO chat_fts(rowid, text) VALUES (NEW.id, NEW.text);
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER chat_messages_fts_ad AFTER DELETE ON chat_messages BEGIN
    INSERT INTO chat_fts(chat_fts, rowid, text) VALUES ('delete', OLD.id, OLD.text);
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER chat_messages_fts_au AFTER UPDATE OF text ON chat_messages BEGIN
    INSERT INTO chat_fts(chat_fts, rowid, text) VALUES ('delete', OLD.id, OLD.text);
    INSERT INTO chat_fts(rowid, text) VALUES (NEW.id, NEW.text);
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER chat_conversations_fts_ai AFTER INSERT ON chat_conversations BEGIN
    INSERT INTO chat_title_fts(rowid, title) VALUES (NEW.id, NEW.title);
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER chat_conversations_fts_ad AFTER DELETE ON chat_conversations BEGIN
    INSERT INTO chat_title_fts(chat_title_fts, rowid, title) VALUES ('delete', OLD.id, OLD.title);
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER chat_conversations_fts_au AFTER UPDATE OF title ON chat_conversations BEGIN
    INSERT INTO chat_title_fts(chat_title_fts, rowid, title) VALUES ('delete', OLD.id, OLD.title);
    INSERT INTO chat_title_fts(rowid, title) VALUES (NEW.id, NEW.title);
END;
-- +goose StatementEnd

INSERT INTO chat_fts(chat_fts) VALUES ('rebuild');
INSERT INTO chat_title_fts(chat_title_fts) VALUES ('rebuild');

PRAGMA foreign_keys = ON;

-- +goose Down
-- Returns the two adopted tables to their pre-00076 (normalized) shape and
-- keeps every row: the app created them, not this migration.
PRAGMA foreign_keys = OFF;

DROP TRIGGER IF EXISTS chat_conversations_fts_au;
DROP TRIGGER IF EXISTS chat_conversations_fts_ad;
DROP TRIGGER IF EXISTS chat_conversations_fts_ai;
DROP TRIGGER IF EXISTS chat_messages_fts_au;
DROP TRIGGER IF EXISTS chat_messages_fts_ad;
DROP TRIGGER IF EXISTS chat_messages_fts_ai;
DROP TABLE IF EXISTS chat_title_fts;
DROP TABLE IF EXISTS chat_fts;
DROP TABLE IF EXISTS chat_turn_steps;
DROP TABLE IF EXISTS chat_artifacts;
DROP TABLE IF EXISTS chat_attachments;
DROP TABLE IF EXISTS chat_project_sources;

CREATE TABLE chat_messages_old (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    role            TEXT NOT NULL,
    text            TEXT NOT NULL,
    created_at      REAL NOT NULL,
    turn_id         TEXT NOT NULL DEFAULT ''
);
INSERT INTO chat_messages_old (id, conversation_id, role, text, created_at, turn_id)
    SELECT id, conversation_id, role, text, created_at, turn_id FROM chat_messages;
DROP TABLE chat_messages;
ALTER TABLE chat_messages_old RENAME TO chat_messages;
CREATE INDEX IF NOT EXISTS idx_chat_messages_conversation ON chat_messages(conversation_id);

CREATE TABLE chat_conversations_old (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    title        TEXT NOT NULL DEFAULT '',
    session_id   TEXT,
    context_type TEXT,
    context_id   TEXT,
    created_at   REAL NOT NULL,
    updated_at   REAL NOT NULL
);
INSERT INTO chat_conversations_old (id, title, session_id, context_type, context_id, created_at, updated_at)
    SELECT id, title, session_id, context_type, context_id, created_at, updated_at FROM chat_conversations;
DROP TABLE chat_conversations;
ALTER TABLE chat_conversations_old RENAME TO chat_conversations;

DROP TABLE IF EXISTS chat_projects;

PRAGMA foreign_keys = ON;
