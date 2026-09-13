-- +goose Up
-- Give jira_slack_links an identity per link kind.
--
-- The table shipped with a single UNIQUE(issue_key, channel_id, message_ts),
-- but only a 'mention' link carries a real message_ts: 'track' and 'decision'
-- links both write message_ts = ''. Under one shared identity that means:
--   * a track link and a decision link for the same issue key and channel are
--     one physical row, with link_type flip-flopping to whichever wrote last;
--   * every later track naming that key in that channel overwrites the previous
--     track_id, so only the most recent track is ever linked (same for digests);
--   * daily/weekly rollups pass channel_id = '', collapsing every decision link
--     in the workspace onto one row per issue key.
--
-- The three kinds have three different natural identities, expressed here as
-- three partial unique indexes:
--     mention  -> (issue_key, channel_id, message_ts)
--     track    -> (issue_key, track_id)
--     decision -> (issue_key, digest_id)
--
-- SQLite cannot drop a table-level UNIQUE (its implicit index is not
-- droppable either), so the table is recreated. The INSERT ... SELECT is a
-- formality: jira_slack_links has never had a production writer — its only
-- writer, UpsertJiraSlackLink, is reached solely from internal/jira.KeyDetector,
-- which has had no non-test caller since it was introduced — so the table is
-- empty on every install. Nothing references jira_slack_links, so the DROP
-- fires no cascade.

CREATE TABLE jira_slack_links_new (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    issue_key TEXT NOT NULL,
    channel_id TEXT NOT NULL DEFAULT '',
    message_ts TEXT NOT NULL DEFAULT '',
    track_id INTEGER,
    digest_id INTEGER,
    link_type TEXT NOT NULL DEFAULT 'mention',
    detected_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT INTO jira_slack_links_new (id, issue_key, channel_id, message_ts, track_id, digest_id, link_type, detected_at)
    SELECT id, issue_key, channel_id, message_ts, track_id, digest_id, link_type, detected_at FROM jira_slack_links;
DROP TABLE jira_slack_links;
ALTER TABLE jira_slack_links_new RENAME TO jira_slack_links;

CREATE INDEX IF NOT EXISTS idx_jira_slack_links_issue ON jira_slack_links(issue_key);
CREATE INDEX IF NOT EXISTS idx_jira_slack_links_channel ON jira_slack_links(channel_id, message_ts);
CREATE INDEX IF NOT EXISTS idx_jira_slack_links_track ON jira_slack_links(track_id);
CREATE INDEX IF NOT EXISTS idx_jira_slack_links_digest ON jira_slack_links(digest_id);

-- One identity per kind. A NULL track_id/digest_id never collides with anything
-- (SQLite treats NULLs as distinct in a unique index), so a malformed link of
-- that kind is simply never deduped — it can no longer displace a well-formed
-- row of another kind, which is the loss this migration removes.
CREATE UNIQUE INDEX IF NOT EXISTS idx_jira_slack_links_mention_identity
    ON jira_slack_links(issue_key, channel_id, message_ts) WHERE link_type = 'mention';
CREATE UNIQUE INDEX IF NOT EXISTS idx_jira_slack_links_track_identity
    ON jira_slack_links(issue_key, track_id) WHERE link_type = 'track';
CREATE UNIQUE INDEX IF NOT EXISTS idx_jira_slack_links_decision_identity
    ON jira_slack_links(issue_key, digest_id) WHERE link_type = 'decision';

-- +goose Down
-- Restore the single shared identity. Rows that only the new indexes allowed to
-- coexist (several tracks or digests for one issue key and channel) would
-- violate it, so the copy keeps the newest row per (issue_key, channel_id,
-- message_ts) and drops the rest.

DROP INDEX IF EXISTS idx_jira_slack_links_mention_identity;
DROP INDEX IF EXISTS idx_jira_slack_links_track_identity;
DROP INDEX IF EXISTS idx_jira_slack_links_decision_identity;

CREATE TABLE jira_slack_links_old (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    issue_key TEXT NOT NULL,
    channel_id TEXT NOT NULL DEFAULT '',
    message_ts TEXT NOT NULL DEFAULT '',
    track_id INTEGER,
    digest_id INTEGER,
    link_type TEXT NOT NULL DEFAULT 'mention',
    detected_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(issue_key, channel_id, message_ts)
);
INSERT INTO jira_slack_links_old (id, issue_key, channel_id, message_ts, track_id, digest_id, link_type, detected_at)
    SELECT id, issue_key, channel_id, message_ts, track_id, digest_id, link_type, detected_at
    FROM jira_slack_links
    WHERE id IN (SELECT MAX(id) FROM jira_slack_links GROUP BY issue_key, channel_id, message_ts);
DROP TABLE jira_slack_links;
ALTER TABLE jira_slack_links_old RENAME TO jira_slack_links;

CREATE INDEX IF NOT EXISTS idx_jira_slack_links_issue ON jira_slack_links(issue_key);
CREATE INDEX IF NOT EXISTS idx_jira_slack_links_channel ON jira_slack_links(channel_id, message_ts);
CREATE INDEX IF NOT EXISTS idx_jira_slack_links_track ON jira_slack_links(track_id);
CREATE INDEX IF NOT EXISTS idx_jira_slack_links_digest ON jira_slack_links(digest_id);
