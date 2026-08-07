-- +goose NO TRANSACTION
-- +goose Up
PRAGMA foreign_keys = OFF;

-- Ideas & Decisions Registry: durable, dedupable record of ideas/decisions/
-- notes mined from Slack digests, meeting transcripts, Gmail and Jira, plus
-- the owner-authored ones from chat. Distinct from targets (actionable goal
-- tracking): an idea only becomes a target when the owner converts it.

CREATE TABLE IF NOT EXISTS ideas (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    kind            TEXT NOT NULL CHECK(kind IN ('idea','decision','note')),
    title           TEXT NOT NULL,
    essence         TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'proposed'
                    CHECK(status IN ('proposed','active','rejected','not_now',
                                     'converted','dropped','merged','superseded','reversed')),
    source          TEXT NOT NULL DEFAULT 'mined' CHECK(source IN ('mined','owner')),
    snooze_until    TEXT NOT NULL DEFAULT '',
    needs_review    INTEGER NOT NULL DEFAULT 0,
    review_reason   TEXT NOT NULL DEFAULT '',
    similar_to_id   INTEGER,
    merged_into_id  INTEGER,
    superseded_by_id INTEGER,
    converted_target_id INTEGER,
    owner_rating    INTEGER NOT NULL DEFAULT 0,
    rating_comment  TEXT NOT NULL DEFAULT '',
    last_mention_at TEXT NOT NULL DEFAULT '',
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_ideas_status ON ideas(status, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_ideas_kind ON ideas(kind, status);

-- Individual sightings of an idea across sources; an idea accumulates one
-- row per mention instead of being overwritten.
CREATE TABLE IF NOT EXISTS idea_mentions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    idea_id     INTEGER NOT NULL REFERENCES ideas(id) ON DELETE CASCADE,
    source      TEXT NOT NULL CHECK(source IN ('slack','meeting','gmail','jira','owner')),
    ref         TEXT NOT NULL DEFAULT '',
    quote       TEXT NOT NULL DEFAULT '',
    author      TEXT NOT NULL DEFAULT '',
    said_at     TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_idea_mentions_idea ON idea_mentions(idea_id);

-- Stage-1 pre-digests for streams that have no existing digest pipeline
-- (Gmail, Jira): a lightweight per-account topic summary the stage-2
-- consolidator reads alongside Slack digests and meeting recaps.
CREATE TABLE IF NOT EXISTS stream_digests (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    source       TEXT NOT NULL CHECK(source IN ('gmail','jira')),
    account_id   INTEGER NOT NULL,
    scope        TEXT NOT NULL DEFAULT '',
    period_from  TEXT NOT NULL,
    period_to    TEXT NOT NULL,
    topics_json  TEXT NOT NULL DEFAULT '[]',
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_stream_digests_source ON stream_digests(source, account_id);

-- Bounded Jira comment sync (per-account, per-issue) feeding the Jira
-- stream digest; a small local cache, not a full Jira-comment mirror.
CREATE TABLE IF NOT EXISTS jira_comments (
    account_id          INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    issue_key           TEXT NOT NULL,
    id                  TEXT NOT NULL,
    author              TEXT NOT NULL DEFAULT '',
    author_account_id   TEXT NOT NULL DEFAULT '',
    body_text           TEXT NOT NULL DEFAULT '',
    created_at          TEXT NOT NULL DEFAULT '',
    updated_at          TEXT NOT NULL DEFAULT '',
    synced_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    PRIMARY KEY (account_id, id)
);
CREATE INDEX IF NOT EXISTS idx_jira_comments_issue ON jira_comments(account_id, issue_key);

ALTER TABLE digest_topics ADD COLUMN ideas TEXT NOT NULL DEFAULT '[]';
ALTER TABLE workspace ADD COLUMN ideas_digest_floor INTEGER NOT NULL DEFAULT 0;  -- ideas registry floor: highest digests.id already consolidated
ALTER TABLE workspace ADD COLUMN ideas_stream_digest_floor INTEGER NOT NULL DEFAULT 0;  -- ideas registry floor: highest stream_digests.id already consolidated
ALTER TABLE workspace ADD COLUMN ideas_transcript_floor INTEGER NOT NULL DEFAULT 0;  -- ideas registry floor: highest meeting_transcripts.id already consolidated
ALTER TABLE google_accounts ADD COLUMN ideas_email_floor REAL NOT NULL DEFAULT 0;  -- ideas registry floor: per-account Gmail internalDate watermark for the email pre-digest
ALTER TABLE jira_accounts ADD COLUMN ideas_jira_floor TEXT NOT NULL DEFAULT '';  -- ideas registry floor: per-account Jira comment-sync watermark for the jira pre-digest

-- Expand targets.source_type CHECK to include 'idea' (converted from the
-- registry). Table-recreation dance (SQLite has no ADD CONSTRAINT); targets
-- is the parent of target_links (ON DELETE CASCADE), hence the
-- PRAGMA foreign_keys = OFF wrapping this whole migration rather than
-- defer_foreign_keys (see the 00002 incident note in the add-migration skill).
CREATE TABLE targets_new (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    text                TEXT NOT NULL,
    intent              TEXT NOT NULL DEFAULT '',
    level               TEXT NOT NULL DEFAULT 'day'
                        CHECK(level IN ('quarter','month','week','day','custom')),
    custom_label        TEXT NOT NULL DEFAULT '',
    period_start        TEXT NOT NULL,
    period_end          TEXT NOT NULL,
    parent_id           INTEGER REFERENCES targets(id) ON DELETE SET NULL,
    status              TEXT NOT NULL DEFAULT 'todo'
                        CHECK(status IN ('todo','in_progress','blocked','done','dismissed','snoozed')),
    priority            TEXT NOT NULL DEFAULT 'medium'
                        CHECK(priority IN ('high','medium','low')),
    ownership           TEXT NOT NULL DEFAULT 'mine'
                        CHECK(ownership IN ('mine','delegated','watching')),
    ball_on             TEXT NOT NULL DEFAULT '',
    due_date            TEXT NOT NULL DEFAULT '',
    snooze_until        TEXT NOT NULL DEFAULT '',
    blocking            TEXT NOT NULL DEFAULT '',
    tags                TEXT NOT NULL DEFAULT '[]',
    sub_items           TEXT NOT NULL DEFAULT '[]',
    notes               TEXT NOT NULL DEFAULT '[]',
    progress            REAL NOT NULL DEFAULT 0.0,
    source_type         TEXT NOT NULL DEFAULT 'manual'
                        CHECK(source_type IN ('extract','track','digest','briefing','manual','chat','inbox','jira','slack','promoted_subitem','idea')),
    source_id           TEXT NOT NULL DEFAULT '',
    ai_level_confidence REAL DEFAULT NULL,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    notified_at         TEXT NOT NULL DEFAULT '',
    next_step           TEXT NOT NULL DEFAULT '',
    next_step_at        TEXT NOT NULL DEFAULT ''
);
INSERT INTO targets_new SELECT
    id, text, intent, level, custom_label, period_start, period_end, parent_id,
    status, priority, ownership, ball_on, due_date, snooze_until, blocking,
    tags, sub_items, notes, progress, source_type, source_id,
    ai_level_confidence, created_at, updated_at, notified_at, next_step, next_step_at
FROM targets;
DROP TABLE targets;
ALTER TABLE targets_new RENAME TO targets;
CREATE INDEX IF NOT EXISTS idx_targets_level       ON targets(level);
CREATE INDEX IF NOT EXISTS idx_targets_parent      ON targets(parent_id);
CREATE INDEX IF NOT EXISTS idx_targets_period      ON targets(period_start, period_end);
CREATE INDEX IF NOT EXISTS idx_targets_status      ON targets(status);
CREATE INDEX IF NOT EXISTS idx_targets_priority    ON targets(priority);
CREATE INDEX IF NOT EXISTS idx_targets_due         ON targets(due_date);
CREATE INDEX IF NOT EXISTS idx_targets_source      ON targets(source_type, source_id);
CREATE INDEX IF NOT EXISTS idx_targets_updated     ON targets(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_targets_due_unfired ON targets(due_date)
    WHERE notified_at = '' AND due_date != '';

PRAGMA foreign_keys = ON;

-- +goose Down
PRAGMA foreign_keys = OFF;

CREATE TABLE targets_old (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    text                TEXT NOT NULL,
    intent              TEXT NOT NULL DEFAULT '',
    level               TEXT NOT NULL DEFAULT 'day'
                        CHECK(level IN ('quarter','month','week','day','custom')),
    custom_label        TEXT NOT NULL DEFAULT '',
    period_start        TEXT NOT NULL,
    period_end          TEXT NOT NULL,
    parent_id           INTEGER REFERENCES targets(id) ON DELETE SET NULL,
    status              TEXT NOT NULL DEFAULT 'todo'
                        CHECK(status IN ('todo','in_progress','blocked','done','dismissed','snoozed')),
    priority            TEXT NOT NULL DEFAULT 'medium'
                        CHECK(priority IN ('high','medium','low')),
    ownership           TEXT NOT NULL DEFAULT 'mine'
                        CHECK(ownership IN ('mine','delegated','watching')),
    ball_on             TEXT NOT NULL DEFAULT '',
    due_date            TEXT NOT NULL DEFAULT '',
    snooze_until        TEXT NOT NULL DEFAULT '',
    blocking            TEXT NOT NULL DEFAULT '',
    tags                TEXT NOT NULL DEFAULT '[]',
    sub_items           TEXT NOT NULL DEFAULT '[]',
    notes               TEXT NOT NULL DEFAULT '[]',
    progress            REAL NOT NULL DEFAULT 0.0,
    source_type         TEXT NOT NULL DEFAULT 'manual'
                        CHECK(source_type IN ('extract','track','digest','briefing','manual','chat','inbox','jira','slack','promoted_subitem')),
    source_id           TEXT NOT NULL DEFAULT '',
    ai_level_confidence REAL DEFAULT NULL,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    notified_at         TEXT NOT NULL DEFAULT '',
    next_step           TEXT NOT NULL DEFAULT '',
    next_step_at        TEXT NOT NULL DEFAULT ''
);
-- Rows with source_type='idea' cannot round-trip into the narrower enum;
-- drop them rather than violate the restored CHECK (symmetric with the
-- 00003 precedent for a table-recreation Down).
INSERT INTO targets_old SELECT
    id, text, intent, level, custom_label, period_start, period_end, parent_id,
    status, priority, ownership, ball_on, due_date, snooze_until, blocking,
    tags, sub_items, notes, progress, source_type, source_id,
    ai_level_confidence, created_at, updated_at, notified_at, next_step, next_step_at
FROM targets WHERE source_type <> 'idea';
DROP TABLE targets;
ALTER TABLE targets_old RENAME TO targets;
CREATE INDEX IF NOT EXISTS idx_targets_level       ON targets(level);
CREATE INDEX IF NOT EXISTS idx_targets_parent      ON targets(parent_id);
CREATE INDEX IF NOT EXISTS idx_targets_period      ON targets(period_start, period_end);
CREATE INDEX IF NOT EXISTS idx_targets_status      ON targets(status);
CREATE INDEX IF NOT EXISTS idx_targets_priority    ON targets(priority);
CREATE INDEX IF NOT EXISTS idx_targets_due         ON targets(due_date);
CREATE INDEX IF NOT EXISTS idx_targets_source      ON targets(source_type, source_id);
CREATE INDEX IF NOT EXISTS idx_targets_updated     ON targets(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_targets_due_unfired ON targets(due_date)
    WHERE notified_at = '' AND due_date != '';

ALTER TABLE jira_accounts DROP COLUMN ideas_jira_floor;
ALTER TABLE google_accounts DROP COLUMN ideas_email_floor;
ALTER TABLE workspace DROP COLUMN ideas_transcript_floor;
ALTER TABLE workspace DROP COLUMN ideas_stream_digest_floor;
ALTER TABLE workspace DROP COLUMN ideas_digest_floor;
ALTER TABLE digest_topics DROP COLUMN ideas;

DROP TABLE IF EXISTS jira_comments;
DROP TABLE IF EXISTS stream_digests;
DROP TABLE IF EXISTS idea_mentions;
DROP TABLE IF EXISTS ideas;

PRAGMA foreign_keys = ON;
