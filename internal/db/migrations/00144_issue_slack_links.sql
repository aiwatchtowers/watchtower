-- +goose NO TRANSACTION
-- +goose Up
PRAGMA foreign_keys = OFF;

-- Linear consumers, knowledge half (spec 2026-10-15-linear-integration-design
-- §4.3 and §6, board #688/#689).
--
-- 1. jira_slack_links becomes issue_slack_links with a tracker column
--    ('jira' | 'linear'): the key detector links a key whose prefix is a known
--    Jira project key OR a known Linear team key, and a prefix known to both
--    writes one link per tracker. Every existing row is a Jira link. The three
--    per-kind identities of 00067 gain the tracker. Nothing references the
--    table, so the DROP fires no cascade.
-- 2. stream_digests.source and idea_mentions.source gain 'linear': the ideas
--    registry mines Linear issues per account into a 'linear' stream, and a
--    mention minted from it carries source 'linear' (00135's dance, same
--    AUTOINCREMENT carry so the consolidator's id floor never sees a reused id).

CREATE TABLE issue_slack_links (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    tracker TEXT NOT NULL DEFAULT 'jira' CHECK (tracker IN ('jira','linear')),
    issue_key TEXT NOT NULL,
    channel_id TEXT NOT NULL DEFAULT '',
    message_ts TEXT NOT NULL DEFAULT '',
    track_id INTEGER,
    digest_id INTEGER,
    link_type TEXT NOT NULL DEFAULT 'mention',
    detected_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT INTO issue_slack_links (id, tracker, issue_key, channel_id, message_ts, track_id, digest_id, link_type, detected_at)
    SELECT id, 'jira', issue_key, channel_id, message_ts, track_id, digest_id, link_type, detected_at
    FROM jira_slack_links;
DELETE FROM sqlite_sequence WHERE name = 'issue_slack_links';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'issue_slack_links', seq FROM sqlite_sequence WHERE name = 'jira_slack_links';
DROP TABLE jira_slack_links;

CREATE INDEX IF NOT EXISTS idx_issue_slack_links_issue ON issue_slack_links(issue_key);
CREATE INDEX IF NOT EXISTS idx_issue_slack_links_channel ON issue_slack_links(channel_id, message_ts);
CREATE INDEX IF NOT EXISTS idx_issue_slack_links_track ON issue_slack_links(track_id);
CREATE INDEX IF NOT EXISTS idx_issue_slack_links_digest ON issue_slack_links(digest_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_issue_slack_links_mention_identity
    ON issue_slack_links(tracker, issue_key, channel_id, message_ts) WHERE link_type = 'mention';
CREATE UNIQUE INDEX IF NOT EXISTS idx_issue_slack_links_track_identity
    ON issue_slack_links(tracker, issue_key, track_id) WHERE link_type = 'track';
CREATE UNIQUE INDEX IF NOT EXISTS idx_issue_slack_links_decision_identity
    ON issue_slack_links(tracker, issue_key, digest_id) WHERE link_type = 'decision';

CREATE TABLE stream_digests_new (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    source       TEXT NOT NULL CHECK(source IN ('gmail','jira','imap','linear')),
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
DELETE FROM sqlite_sequence WHERE name = 'stream_digests_new';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'stream_digests_new', seq FROM sqlite_sequence WHERE name = 'stream_digests';
DROP TABLE stream_digests;
ALTER TABLE stream_digests_new RENAME TO stream_digests;
CREATE INDEX IF NOT EXISTS idx_stream_digests_source ON stream_digests(source, account_id);

CREATE TABLE idea_mentions_new (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    idea_id     INTEGER NOT NULL REFERENCES ideas(id) ON DELETE CASCADE,
    source      TEXT NOT NULL CHECK(source IN ('slack','meeting','gmail','jira','owner','imap','linear')),
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
-- Linear rows cannot live in the old tables and are dropped.
PRAGMA foreign_keys = OFF;

CREATE TABLE jira_slack_links (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    issue_key TEXT NOT NULL,
    channel_id TEXT NOT NULL DEFAULT '',
    message_ts TEXT NOT NULL DEFAULT '',
    track_id INTEGER,
    digest_id INTEGER,
    link_type TEXT NOT NULL DEFAULT 'mention',
    detected_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT INTO jira_slack_links (id, issue_key, channel_id, message_ts, track_id, digest_id, link_type, detected_at)
    SELECT id, issue_key, channel_id, message_ts, track_id, digest_id, link_type, detected_at
    FROM issue_slack_links WHERE tracker = 'jira';
DELETE FROM sqlite_sequence WHERE name = 'jira_slack_links';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'jira_slack_links', seq FROM sqlite_sequence WHERE name = 'issue_slack_links';
DROP TABLE issue_slack_links;
DELETE FROM sqlite_sequence WHERE name = 'issue_slack_links';

CREATE INDEX IF NOT EXISTS idx_jira_slack_links_issue ON jira_slack_links(issue_key);
CREATE INDEX IF NOT EXISTS idx_jira_slack_links_channel ON jira_slack_links(channel_id, message_ts);
CREATE INDEX IF NOT EXISTS idx_jira_slack_links_track ON jira_slack_links(track_id);
CREATE INDEX IF NOT EXISTS idx_jira_slack_links_digest ON jira_slack_links(digest_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_jira_slack_links_mention_identity
    ON jira_slack_links(issue_key, channel_id, message_ts) WHERE link_type = 'mention';
CREATE UNIQUE INDEX IF NOT EXISTS idx_jira_slack_links_track_identity
    ON jira_slack_links(issue_key, track_id) WHERE link_type = 'track';
CREATE UNIQUE INDEX IF NOT EXISTS idx_jira_slack_links_decision_identity
    ON jira_slack_links(issue_key, digest_id) WHERE link_type = 'decision';

CREATE TABLE stream_digests_old (
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
INSERT INTO stream_digests_old (id, source, account_id, scope, period_from, period_to, topics_json, created_at, read_at)
SELECT id, source, account_id, scope, period_from, period_to, topics_json, created_at, read_at
FROM stream_digests WHERE source != 'linear';
DELETE FROM sqlite_sequence WHERE name = 'stream_digests_old';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'stream_digests_old', seq FROM sqlite_sequence WHERE name = 'stream_digests';
DROP TABLE stream_digests;
ALTER TABLE stream_digests_old RENAME TO stream_digests;
CREATE INDEX IF NOT EXISTS idx_stream_digests_source ON stream_digests(source, account_id);

CREATE TABLE idea_mentions_old (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    idea_id     INTEGER NOT NULL REFERENCES ideas(id) ON DELETE CASCADE,
    source      TEXT NOT NULL CHECK(source IN ('slack','meeting','gmail','jira','owner','imap')),
    ref         TEXT NOT NULL DEFAULT '',
    quote       TEXT NOT NULL DEFAULT '',
    author      TEXT NOT NULL DEFAULT '',
    said_at     TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
INSERT INTO idea_mentions_old (id, idea_id, source, ref, quote, author, said_at, created_at)
SELECT id, idea_id, source, ref, quote, author, said_at, created_at
FROM idea_mentions WHERE source != 'linear';
DELETE FROM sqlite_sequence WHERE name = 'idea_mentions_old';
INSERT INTO sqlite_sequence (name, seq)
    SELECT 'idea_mentions_old', seq FROM sqlite_sequence WHERE name = 'idea_mentions';
DROP TABLE idea_mentions;
ALTER TABLE idea_mentions_old RENAME TO idea_mentions;
CREATE INDEX IF NOT EXISTS idx_idea_mentions_idea ON idea_mentions(idea_id);
CREATE INDEX IF NOT EXISTS idx_idea_mentions_ref ON idea_mentions(source, ref);

PRAGMA foreign_keys = ON;
