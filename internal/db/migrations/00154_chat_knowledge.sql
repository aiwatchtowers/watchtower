-- +goose NO TRANSACTION
-- +goose Up
-- AI chats feed the knowledge base (spec
-- docs/superpowers/specs/2026-10-24-chat-knowledge-design.md, part B).
--
-- 1. ideas.chat_born: 1 for an idea first proposed from chat material. Until
--    the owner approves it (status 'active') it stays out of every
--    knowledge reader (db.KnowledgeVisibleIdeaCond).
-- 2. idea_mentions.source gains 'chat' (ref = chat:<conversation>:<message>).
-- 3. workspace.ideas_chat_floor: the highest chat_messages.id the ideas
--    consolidator has consumed. Seeded to the current newest message, as
--    00050 seeded its floors: history is not mined.
-- 4. chat_knowledge_artifacts: one row per artifact the owner kept in the
--    knowledge base, removed with its conversation.
--
-- SQLite cannot change a CHECK in place: idea_mentions is rebuilt with every
-- row, its id and its AUTOINCREMENT high-water mark (sqlite_sequence carry,
-- the 00135/00144 shape). It is a child, not a parent, but foreign keys stay
-- OFF around the dance per the house rule. The pragma cannot change inside a
-- transaction, so it stays outside the explicit BEGIN … COMMIT that makes the
-- migration one unit; the transaction is one goose statement (the driver
-- discards a connection left inside a transaction between execs,
-- internal/sqlcipher/wt_session.go).
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;

ALTER TABLE ideas ADD COLUMN chat_born INTEGER NOT NULL DEFAULT 0;

ALTER TABLE workspace ADD COLUMN ideas_chat_floor INTEGER NOT NULL DEFAULT 0;
UPDATE workspace SET ideas_chat_floor = (SELECT COALESCE(MAX(id), 0) FROM chat_messages);

CREATE TABLE chat_knowledge_artifacts (
    conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    artifact_key    TEXT NOT NULL,
    version         INTEGER NOT NULL,
    kept_at         TEXT NOT NULL,
    PRIMARY KEY (conversation_id, artifact_key)
);

CREATE TABLE idea_mentions_new (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    idea_id     INTEGER NOT NULL REFERENCES ideas(id) ON DELETE CASCADE,
    source      TEXT NOT NULL CHECK(source IN ('slack','meeting','gmail','jira','owner','imap','linear','chat')),
    ref         TEXT NOT NULL DEFAULT '',
    quote       TEXT NOT NULL DEFAULT '',
    author      TEXT NOT NULL DEFAULT '',
    said_at     TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
INSERT INTO idea_mentions_new (id, idea_id, source, ref, quote, author, said_at, created_at)
SELECT id, idea_id, source, ref, quote, author, said_at, created_at
FROM idea_mentions;
DELETE FROM sqlite_sequence WHERE name = 'idea_mentions_new';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'idea_mentions_new', seq FROM sqlite_sequence WHERE name = 'idea_mentions';
DROP TABLE idea_mentions;
ALTER TABLE idea_mentions_new RENAME TO idea_mentions;
CREATE INDEX IF NOT EXISTS idx_idea_mentions_idea ON idea_mentions(idea_id);
CREATE INDEX IF NOT EXISTS idx_idea_mentions_ref ON idea_mentions(source, ref);

COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;

-- +goose Down
-- Chat mentions cannot live in the old table and are dropped.
PRAGMA foreign_keys = OFF;
-- +goose StatementBegin
BEGIN IMMEDIATE;

CREATE TABLE idea_mentions_old (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    idea_id     INTEGER NOT NULL REFERENCES ideas(id) ON DELETE CASCADE,
    source      TEXT NOT NULL CHECK(source IN ('slack','meeting','gmail','jira','owner','imap','linear')),
    ref         TEXT NOT NULL DEFAULT '',
    quote       TEXT NOT NULL DEFAULT '',
    author      TEXT NOT NULL DEFAULT '',
    said_at     TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
INSERT INTO idea_mentions_old (id, idea_id, source, ref, quote, author, said_at, created_at)
SELECT id, idea_id, source, ref, quote, author, said_at, created_at
FROM idea_mentions WHERE source != 'chat';
DELETE FROM sqlite_sequence WHERE name = 'idea_mentions_old';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'idea_mentions_old', seq FROM sqlite_sequence WHERE name = 'idea_mentions';
DROP TABLE idea_mentions;
ALTER TABLE idea_mentions_old RENAME TO idea_mentions;
CREATE INDEX IF NOT EXISTS idx_idea_mentions_idea ON idea_mentions(idea_id);
CREATE INDEX IF NOT EXISTS idx_idea_mentions_ref ON idea_mentions(source, ref);

DROP TABLE chat_knowledge_artifacts;
ALTER TABLE workspace DROP COLUMN ideas_chat_floor;
ALTER TABLE ideas DROP COLUMN chat_born;

COMMIT;
-- +goose StatementEnd
PRAGMA foreign_keys = ON;
