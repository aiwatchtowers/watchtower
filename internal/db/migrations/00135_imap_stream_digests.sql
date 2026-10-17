-- +goose NO TRANSACTION
-- +goose Up
PRAGMA foreign_keys = OFF;

-- Email digests and ideas read IMAP/Outlook mailboxes too (board #615, ask
-- #307): the ideas email pre-digest mines imap_messages per connected
-- mailbox, so stream_digests.source and idea_mentions.source gain 'imap', and
-- every email_accounts row gets its own ideas floor (the
-- google_accounts.ideas_email_floor twin: unix seconds of the newest
-- internal_date already mined; 0 = never initialized).
--
-- SQLite has no ALTER CONSTRAINT, so both CHECKs need the table-recreation
-- dance. Neither table is a parent (nothing references them), but the safe
-- pattern stays: PRAGMA foreign_keys = OFF around the whole migration (NO
-- TRANSACTION). Every index is recreated; neither table has triggers.

ALTER TABLE email_accounts ADD COLUMN ideas_email_floor REAL NOT NULL DEFAULT 0;

CREATE TABLE stream_digests_new (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    source       TEXT NOT NULL CHECK(source IN ('gmail','jira','imap')),
    account_id   INTEGER NOT NULL,
    scope        TEXT NOT NULL DEFAULT '',
    period_from  TEXT NOT NULL,
    period_to    TEXT NOT NULL,
    topics_json  TEXT NOT NULL DEFAULT '[]',
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    read_at      TEXT
);
INSERT INTO stream_digests_new (id, source, account_id, scope, period_from, period_to, topics_json, created_at, read_at)
SELECT id, source, account_id, scope, period_from, period_to, topics_json, created_at, read_at
FROM stream_digests;
-- Carry the AUTOINCREMENT high-water mark: the consolidator's
-- ideas_stream_digest_floor is an id floor, so a new row must never reuse an
-- id at or below a deleted one's.
DELETE FROM sqlite_sequence WHERE name = 'stream_digests_new';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'stream_digests_new', seq FROM sqlite_sequence WHERE name = 'stream_digests';
DROP TABLE stream_digests;
ALTER TABLE stream_digests_new RENAME TO stream_digests;
CREATE INDEX IF NOT EXISTS idx_stream_digests_source ON stream_digests(source, account_id);

CREATE TABLE idea_mentions_new (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    idea_id     INTEGER NOT NULL REFERENCES ideas(id) ON DELETE CASCADE,
    source      TEXT NOT NULL CHECK(source IN ('slack','meeting','gmail','jira','owner','imap')),
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

PRAGMA foreign_keys = ON;

-- +goose Down
-- IMAP rows cannot live in the old tables and are dropped.
PRAGMA foreign_keys = OFF;

CREATE TABLE stream_digests_old (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    source       TEXT NOT NULL CHECK(source IN ('gmail','jira')),
    account_id   INTEGER NOT NULL,
    scope        TEXT NOT NULL DEFAULT '',
    period_from  TEXT NOT NULL,
    period_to    TEXT NOT NULL,
    topics_json  TEXT NOT NULL DEFAULT '[]',
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    read_at      TEXT
);
INSERT INTO stream_digests_old (id, source, account_id, scope, period_from, period_to, topics_json, created_at, read_at)
SELECT id, source, account_id, scope, period_from, period_to, topics_json, created_at, read_at
FROM stream_digests WHERE source != 'imap';
DELETE FROM sqlite_sequence WHERE name = 'stream_digests_old';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'stream_digests_old', seq FROM sqlite_sequence WHERE name = 'stream_digests';
DROP TABLE stream_digests;
ALTER TABLE stream_digests_old RENAME TO stream_digests;
CREATE INDEX IF NOT EXISTS idx_stream_digests_source ON stream_digests(source, account_id);

CREATE TABLE idea_mentions_old (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    idea_id     INTEGER NOT NULL REFERENCES ideas(id) ON DELETE CASCADE,
    source      TEXT NOT NULL CHECK(source IN ('slack','meeting','gmail','jira','owner')),
    ref         TEXT NOT NULL DEFAULT '',
    quote       TEXT NOT NULL DEFAULT '',
    author      TEXT NOT NULL DEFAULT '',
    said_at     TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
INSERT INTO idea_mentions_old (id, idea_id, source, ref, quote, author, said_at, created_at)
SELECT id, idea_id, source, ref, quote, author, said_at, created_at
FROM idea_mentions WHERE source != 'imap';
DELETE FROM sqlite_sequence WHERE name = 'idea_mentions_old';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'idea_mentions_old', seq FROM sqlite_sequence WHERE name = 'idea_mentions';
DROP TABLE idea_mentions;
ALTER TABLE idea_mentions_old RENAME TO idea_mentions;
CREATE INDEX IF NOT EXISTS idx_idea_mentions_idea ON idea_mentions(idea_id);
CREATE INDEX IF NOT EXISTS idx_idea_mentions_ref ON idea_mentions(source, ref);

ALTER TABLE email_accounts DROP COLUMN ideas_email_floor;

PRAGMA foreign_keys = ON;
