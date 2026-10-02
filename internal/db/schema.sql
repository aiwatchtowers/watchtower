-- Watchtower database schema
-- All tables for Slack workspace data storage

-- Workspace metadata. id/name/domain are a frozen legacy snapshot of Slack
-- account #1 — current_user_id/search_last_date moved to slack_accounts,
-- one row per connected Slack workspace (see 00048).
-- Vestigial since 00070 (inbox demolition — the pipelines that advanced and
-- read these watermarks are gone; kept rather than dropped to avoid a
-- table-recreation migration): compose_last_run_ts,
-- memory_last_ingested_situation_id, memory_last_interaction_id,
-- memory_last_situation_feedback_id. ClearSlackData still zeroes
-- compose_last_run_ts, but nothing consumes the value.
CREATE TABLE IF NOT EXISTS workspace (
    id                TEXT PRIMARY KEY,  -- Slack team_id
    name              TEXT NOT NULL,
    domain            TEXT NOT NULL DEFAULT '',
    synced_at         TEXT,              -- ISO8601 timestamp of last sync
    inbox_last_processed_ts REAL NOT NULL DEFAULT 0,  -- Unix timestamp of last inbox pipeline run
    secretary_profile TEXT NOT NULL DEFAULT '',  -- User-written secretary brief text
    style_profile TEXT NOT NULL DEFAULT '',  -- AI-distilled, user-editable communication style (see 00013)
    style_profile_updated_at TEXT NOT NULL DEFAULT '',
    compose_last_run_ts REAL NOT NULL DEFAULT 0,  -- Unix timestamp of last situation composer run
    memory_last_extracted_ts REAL NOT NULL DEFAULT 0,  -- Unix ts of last message consumed by the memory episode extractor (see 00017)
    memory_last_ingested_situation_id INTEGER NOT NULL DEFAULT 0,  -- ingest floor: highest terminal situation id already folded into the vault (see 00018)
    memory_chat_turn_floor INTEGER NOT NULL DEFAULT 0,  -- owner-chat ingest floor: highest chat_messages.id already folded into the belief pass (see 00019)
    memory_last_interaction_id INTEGER NOT NULL DEFAULT 0,  -- 5D interaction-ingest floor: highest owner-interaction row id already folded into episode outcomes / memory_engagement (see 00042)
    memory_calendar_last_extracted_ts REAL NOT NULL DEFAULT 0,  -- Unix ts of last ended calendar event fully folded into an episode by the calendar past-event->episode builder; a fourth independent memory watermark (see 00033)
    -- memory_jira_last_extracted_ts moved to jira_accounts (per-account, see 00049)
    memory_last_situation_feedback_id INTEGER NOT NULL DEFAULT 0,  -- 5D interaction-ingest floor over feedback(entity_type='situation') — the dashboard's situation-level thumbs; sibling of memory_last_interaction_id (see 00036, M8)
    memory_focus_fingerprint TEXT NOT NULL DEFAULT '',  -- Hash of the last APPLIED parsed focus.md directive set — runtime state (see 00041)
    ideas_digest_floor INTEGER NOT NULL DEFAULT 0,  -- ideas registry floor: highest digest_topics.id already consolidated (see 00050)
    ideas_stream_digest_floor INTEGER NOT NULL DEFAULT 0,  -- ideas registry floor: highest stream_digests.id already consolidated (see 00050)
    ideas_transcript_floor INTEGER NOT NULL DEFAULT 0,  -- ideas registry floor: highest meeting_transcripts.id already consolidated (see 00050)
    digest_fastforward_ts REAL NOT NULL DEFAULT 0  -- Slack-digest fast-forward floor: lastDigestTime returns max(MAX(digests.period_to), this); stamped to now on a slack-digests re-enable (FEAT-03, see 00057)
);

-- Users
CREATE TABLE IF NOT EXISTS users (
    id            TEXT PRIMARY KEY,  -- namespaced "<slack_account_id>:<raw Slack user ID>" (see 00048)
    name          TEXT NOT NULL,
    display_name  TEXT NOT NULL DEFAULT '',
    real_name     TEXT NOT NULL DEFAULT '',
    email         TEXT NOT NULL DEFAULT '',
    is_bot        INTEGER NOT NULL DEFAULT 0,
    is_deleted    INTEGER NOT NULL DEFAULT 0,
    is_stub       INTEGER NOT NULL DEFAULT 0,
    is_bot_override INTEGER DEFAULT NULL,  -- NULL=use Slack value, 1=force bot, 0=force not-bot
    is_muted_for_llm INTEGER NOT NULL DEFAULT 0,  -- 1=exclude this user's messages from AI analysis
    profile_json  TEXT NOT NULL DEFAULT '{}',
    updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_users_name ON users(name);
CREATE INDEX IF NOT EXISTS idx_users_is_bot ON users(is_bot);
CREATE INDEX IF NOT EXISTS idx_users_is_stub ON users(is_stub);

-- Channels
CREATE TABLE IF NOT EXISTS channels (
    id           TEXT PRIMARY KEY,  -- namespaced "<slack_account_id>:<raw Slack channel ID>" (see 00048)
    name         TEXT NOT NULL,
    type         TEXT NOT NULL CHECK(type IN ('public', 'private', 'dm', 'group_dm')),
    topic        TEXT NOT NULL DEFAULT '',
    purpose      TEXT NOT NULL DEFAULT '',
    is_archived  INTEGER NOT NULL DEFAULT 0,
    is_member    INTEGER NOT NULL DEFAULT 0,
    dm_user_id   TEXT,
    num_members  INTEGER NOT NULL DEFAULT 0,
    last_read    TEXT NOT NULL DEFAULT '',  -- Slack conversations.mark cursor (message ts)
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    digest_considered_ts INTEGER            -- newest message ts_unix rendered into a channel-digest AI call that succeeded (NULL = never); see 00066
);
CREATE INDEX IF NOT EXISTS idx_channels_name ON channels(name);
CREATE INDEX IF NOT EXISTS idx_channels_type ON channels(type);
CREATE INDEX IF NOT EXISTS idx_channels_is_archived ON channels(is_archived);
CREATE INDEX IF NOT EXISTS idx_channels_is_member ON channels(is_member);

-- Messages
CREATE TABLE IF NOT EXISTS messages (
    channel_id   TEXT NOT NULL,  -- namespaced "<slack_account_id>:<raw channel ID>" (see 00048)
    ts           TEXT NOT NULL,       -- Slack timestamp (unique message ID)
    user_id      TEXT NOT NULL DEFAULT '',  -- namespaced "<slack_account_id>:<raw user ID>" (see 00048)
    text         TEXT NOT NULL DEFAULT '',
    thread_ts    TEXT,
    reply_count  INTEGER NOT NULL DEFAULT 0,
    is_edited    INTEGER NOT NULL DEFAULT 0,
    is_deleted   INTEGER NOT NULL DEFAULT 0,
    subtype      TEXT NOT NULL DEFAULT '',
    permalink    TEXT NOT NULL DEFAULT '',
    ts_unix      REAL GENERATED ALWAYS AS (CASE WHEN INSTR(ts, '.') > 0 THEN CAST(SUBSTR(ts, 1, INSTR(ts, '.') - 1) AS REAL) ELSE CAST(ts AS REAL) END) STORED,
    raw_json     TEXT NOT NULL DEFAULT '{}',
    PRIMARY KEY (channel_id, ts)
);
CREATE INDEX IF NOT EXISTS idx_messages_user_id ON messages(user_id);
CREATE INDEX IF NOT EXISTS idx_messages_thread ON messages(channel_id, thread_ts);
CREATE INDEX IF NOT EXISTS idx_messages_ts_unix ON messages(ts_unix);
CREATE INDEX IF NOT EXISTS idx_messages_channel_ts_unix ON messages(channel_id, ts_unix);

-- FTS5 virtual table for full-text search on messages
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
    text,
    channel_id UNINDEXED,
    ts UNINDEXED,
    user_id UNINDEXED,
    tokenize='porter unicode61'
);

-- Triggers to keep FTS index in sync with messages table
CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages
WHEN NEW.text != '' AND NEW.is_deleted = 0
BEGIN
    DELETE FROM messages_fts WHERE channel_id = NEW.channel_id AND ts = NEW.ts;
    INSERT INTO messages_fts(text, channel_id, ts, user_id)
    VALUES (NEW.text, NEW.channel_id, NEW.ts, NEW.user_id);
END;

CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages
BEGIN
    DELETE FROM messages_fts WHERE channel_id = OLD.channel_id AND ts = OLD.ts;
END;

CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE OF text, is_deleted ON messages
WHEN OLD.text != NEW.text OR OLD.is_deleted != NEW.is_deleted
BEGIN
    DELETE FROM messages_fts WHERE channel_id = OLD.channel_id AND ts = OLD.ts;
    INSERT INTO messages_fts(text, channel_id, ts, user_id)
    SELECT NEW.text, NEW.channel_id, NEW.ts, NEW.user_id
    WHERE NEW.text != '' AND NEW.is_deleted = 0;
END;

-- Reactions
CREATE TABLE IF NOT EXISTS reactions (
    channel_id  TEXT NOT NULL,
    message_ts  TEXT NOT NULL,
    user_id     TEXT NOT NULL,
    emoji       TEXT NOT NULL,
    PRIMARY KEY (channel_id, message_ts, user_id, emoji)
);
CREATE INDEX IF NOT EXISTS idx_reactions_message ON reactions(channel_id, message_ts);

-- Files
CREATE TABLE IF NOT EXISTS files (
    id                 TEXT PRIMARY KEY,  -- Slack file ID
    message_channel_id TEXT NOT NULL DEFAULT '',
    message_ts         TEXT NOT NULL DEFAULT '',
    name               TEXT NOT NULL DEFAULT '',
    mimetype           TEXT NOT NULL DEFAULT '',
    size               INTEGER NOT NULL DEFAULT 0,
    permalink          TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_files_message ON files(message_channel_id, message_ts);

-- Sync state tracking per channel
CREATE TABLE IF NOT EXISTS sync_state (
    channel_id              TEXT PRIMARY KEY,
    last_synced_ts          TEXT NOT NULL DEFAULT '',
    oldest_synced_ts        TEXT NOT NULL DEFAULT '',
    is_initial_sync_complete INTEGER NOT NULL DEFAULT 0,
    cursor                  TEXT NOT NULL DEFAULT '',
    messages_synced         INTEGER NOT NULL DEFAULT 0,
    last_sync_at            TEXT,
    error                   TEXT NOT NULL DEFAULT ''
);

-- Watch list for priority tracking
CREATE TABLE IF NOT EXISTS watch_list (
    entity_type TEXT NOT NULL CHECK(entity_type IN ('channel', 'user')),
    entity_id   TEXT NOT NULL,
    entity_name TEXT NOT NULL DEFAULT '',
    priority    TEXT NOT NULL DEFAULT 'normal' CHECK(priority IN ('high', 'normal', 'low')),
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (entity_type, entity_id)
);

-- User checkpoints (singleton table for last catchup time)
CREATE TABLE IF NOT EXISTS user_checkpoints (
    id              INTEGER PRIMARY KEY CHECK(id = 1),
    last_checked_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- AI-generated digests (summaries of channel activity)
CREATE TABLE IF NOT EXISTS digests (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id    TEXT NOT NULL DEFAULT '',  -- '' for cross-channel digests
    period_from   REAL NOT NULL,             -- Unix timestamp
    period_to     REAL NOT NULL,             -- Unix timestamp
    type          TEXT NOT NULL CHECK(type IN ('channel', 'daily', 'weekly')),
    summary       TEXT NOT NULL,
    topics        TEXT NOT NULL DEFAULT '[]',
    decisions     TEXT NOT NULL DEFAULT '[]',
    action_items  TEXT NOT NULL DEFAULT '[]',
    message_count INTEGER NOT NULL DEFAULT 0,
    model         TEXT NOT NULL DEFAULT '',
    input_tokens  INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cost_usd      REAL NOT NULL DEFAULT 0,
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    read_at         TEXT,  -- NULL = unread, ISO8601 = when read (local-only)
    prompt_version  INTEGER NOT NULL DEFAULT 0,  -- version of prompt used for generation
    people_signals  TEXT NOT NULL DEFAULT '[]',   -- JSON array of PersonSignals from MAP phase (legacy)
    situations      TEXT NOT NULL DEFAULT '[]',   -- JSON array of Situation objects from channel digest
    running_summary TEXT NOT NULL DEFAULT '',     -- JSON running context for next digest (channel memory)
    UNIQUE(channel_id, type, period_from, period_to)
);
CREATE INDEX IF NOT EXISTS idx_digests_channel ON digests(channel_id);
CREATE INDEX IF NOT EXISTS idx_digests_type ON digests(type);
CREATE INDEX IF NOT EXISTS idx_digests_period ON digests(period_from, period_to);

-- Digest participants: which users were mentioned in each digest's situations
CREATE TABLE IF NOT EXISTS digest_participants (
    digest_id      INTEGER NOT NULL REFERENCES digests(id) ON DELETE CASCADE,
    user_id        TEXT NOT NULL,
    situation_idx  INTEGER NOT NULL DEFAULT 0,
    role           TEXT NOT NULL DEFAULT '',
    topic_id       INTEGER NOT NULL DEFAULT 0,  -- 0 = legacy (pre-v39), >0 = digest_topics.id
    PRIMARY KEY (digest_id, user_id, situation_idx)
);
CREATE INDEX IF NOT EXISTS idx_digest_participants_user ON digest_participants(user_id);

-- Digest topics: each digest is decomposed into granular, self-contained topics.
-- Each topic carries its own decisions, action_items, situations, key_messages.
CREATE TABLE IF NOT EXISTS digest_topics (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    digest_id     INTEGER NOT NULL REFERENCES digests(id) ON DELETE CASCADE,
    idx           INTEGER NOT NULL DEFAULT 0,
    title         TEXT NOT NULL,
    summary       TEXT NOT NULL DEFAULT '',
    decisions     TEXT NOT NULL DEFAULT '[]',
    action_items  TEXT NOT NULL DEFAULT '[]',
    situations    TEXT NOT NULL DEFAULT '[]',
    key_messages  TEXT NOT NULL DEFAULT '[]',
    ideas         TEXT NOT NULL DEFAULT '[]',  -- ideas registry: idea/decision candidates mined from this topic (see 00050)
    UNIQUE(digest_id, idx)
);
CREATE INDEX IF NOT EXISTS idx_digest_topics_digest ON digest_topics(digest_id);

-- Per-decision read tracking (local-only, Desktop app)
CREATE TABLE IF NOT EXISTS decision_reads (
    digest_id    INTEGER NOT NULL REFERENCES digests(id) ON DELETE CASCADE,
    decision_idx INTEGER NOT NULL,  -- index in the decisions JSON array within a topic
    topic_id     INTEGER NOT NULL DEFAULT 0,  -- 0 = legacy (pre-v39), >0 = digest_topics.id
    read_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (digest_id, decision_idx)
);

-- User communication analyses (people analytics with sliding window)
CREATE TABLE IF NOT EXISTS user_analyses (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id             TEXT NOT NULL,
    period_from         REAL NOT NULL,             -- Unix timestamp (window start)
    period_to           REAL NOT NULL,             -- Unix timestamp (window end)
    -- Computed stats (pure SQL, no AI)
    message_count       INTEGER NOT NULL DEFAULT 0,
    channels_active     INTEGER NOT NULL DEFAULT 0,
    threads_initiated   INTEGER NOT NULL DEFAULT 0,
    threads_replied     INTEGER NOT NULL DEFAULT 0,
    avg_message_length  REAL NOT NULL DEFAULT 0,
    active_hours_json   TEXT NOT NULL DEFAULT '{}',  -- {"9":12,"10":8,...}
    volume_change_pct   REAL NOT NULL DEFAULT 0,     -- vs previous window
    -- AI-generated analysis
    summary             TEXT NOT NULL DEFAULT '',
    communication_style TEXT NOT NULL DEFAULT '',
    decision_role       TEXT NOT NULL DEFAULT '',     -- "driver","approver","observer",...
    red_flags           TEXT NOT NULL DEFAULT '[]',   -- JSON array
    highlights          TEXT NOT NULL DEFAULT '[]',   -- JSON array (positive contributions)
    style_details       TEXT NOT NULL DEFAULT '',     -- detailed communication style evaluation
    recommendations     TEXT NOT NULL DEFAULT '[]',   -- JSON array of improvement suggestions
    concerns            TEXT NOT NULL DEFAULT '[]',   -- JSON array of specific issues with examples
    accomplishments     TEXT NOT NULL DEFAULT '[]',   -- JSON array of what was delivered/completed
    -- Metadata
    model               TEXT NOT NULL DEFAULT '',
    input_tokens        INTEGER NOT NULL DEFAULT 0,
    output_tokens       INTEGER NOT NULL DEFAULT 0,
    cost_usd            REAL NOT NULL DEFAULT 0,
    prompt_version      INTEGER NOT NULL DEFAULT 0,  -- version of prompt used for generation
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(user_id, period_from, period_to)
);
CREATE INDEX IF NOT EXISTS idx_user_analyses_user ON user_analyses(user_id);
CREATE INDEX IF NOT EXISTS idx_user_analyses_period ON user_analyses(period_from, period_to);

-- Period summaries (cross-user team summary for a time window)
CREATE TABLE IF NOT EXISTS period_summaries (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    period_from   REAL NOT NULL,
    period_to     REAL NOT NULL,
    summary       TEXT NOT NULL DEFAULT '',
    attention     TEXT NOT NULL DEFAULT '[]',  -- JSON array of things to pay attention to
    model         TEXT NOT NULL DEFAULT '',
    input_tokens  INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cost_usd      REAL NOT NULL DEFAULT 0,
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(period_from, period_to)
);
CREATE INDEX IF NOT EXISTS idx_period_summaries_period ON period_summaries(period_from, period_to);

-- Custom workspace emojis (synced via emoji.list API)
CREATE TABLE IF NOT EXISTS custom_emojis (
    name       TEXT PRIMARY KEY,       -- Emoji shortcode (without colons)
    url        TEXT NOT NULL,           -- URL to emoji image (or "alias:other_name")
    alias_for  TEXT NOT NULL DEFAULT '', -- If this is an alias, the target emoji name
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Action-item tracks (hybrid v2 extraction + cross-channel merge)
CREATE TABLE IF NOT EXISTS tracks (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    assignee_user_id    TEXT NOT NULL DEFAULT '',           -- user the track is for
    text                TEXT NOT NULL,                      -- actionable description
    context             TEXT NOT NULL DEFAULT '',           -- 3-5 sentence explanation
    category            TEXT NOT NULL DEFAULT 'task',       -- code_review, decision_needed, info_request, task, approval, follow_up, bug_fix, discussion
    ownership           TEXT NOT NULL DEFAULT 'mine' CHECK(ownership IN ('mine','delegated','watching')),
    ball_on             TEXT NOT NULL DEFAULT '',           -- user_id of next actor
    owner_user_id       TEXT NOT NULL DEFAULT '',           -- for delegated: report's user_id
    requester_name      TEXT NOT NULL DEFAULT '',           -- who made the request
    requester_user_id   TEXT NOT NULL DEFAULT '',           -- requester's Slack user_id
    blocking            TEXT NOT NULL DEFAULT '',           -- who/what is blocked
    decision_summary    TEXT NOT NULL DEFAULT '',           -- how group arrived at decision
    decision_options    TEXT NOT NULL DEFAULT '[]',         -- JSON: [{option, supporters, pros, cons}]
    sub_items           TEXT NOT NULL DEFAULT '[]',         -- JSON: [{text, status}]
    participants        TEXT NOT NULL DEFAULT '[]',         -- JSON: [{name, user_id, stance}]
    source_refs         TEXT NOT NULL DEFAULT '[]',         -- JSON: [{ts, author, text}] key message quotes
    tags                TEXT NOT NULL DEFAULT '[]',         -- JSON: ["tag1","tag2"]
    channel_ids         TEXT NOT NULL DEFAULT '[]',         -- JSON: ["C1","C2"] cross-channel
    related_digest_ids  TEXT NOT NULL DEFAULT '[]',         -- JSON: [1,2,3]
    priority            TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('high','medium','low')),
    due_date            REAL,                               -- Unix timestamp if deadline extracted
    fingerprint         TEXT NOT NULL DEFAULT '[]',         -- JSON: extracted entities for dedup
    read_at             TEXT,                               -- NULL=unread, ISO8601=when read
    has_updates         INTEGER NOT NULL DEFAULT 0,
    dismissed_at        TEXT NOT NULL DEFAULT '',           -- ''=active, ISO8601=when dismissed
    model               TEXT NOT NULL DEFAULT '',
    input_tokens        INTEGER NOT NULL DEFAULT 0,
    output_tokens       INTEGER NOT NULL DEFAULT 0,
    cost_usd            REAL NOT NULL DEFAULT 0,
    prompt_version      INTEGER NOT NULL DEFAULT 0,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    origin              TEXT NOT NULL DEFAULT 'auto' CHECK(origin IN ('auto','custom')),
    instruction         TEXT NOT NULL DEFAULT '',       -- custom tracks: watch instruction
    enabled             INTEGER NOT NULL DEFAULT 1,      -- custom tracks: scan on/off
    last_run_at         TEXT NOT NULL DEFAULT '',        -- custom tracks: scan watermark, ''=never
    linked_target_id    INTEGER REFERENCES targets(id) ON DELETE SET NULL,
    scan_attempts       INTEGER NOT NULL DEFAULT 0,      -- custom tracks: failed scans on the UTC day of scan_attempted_at (3/day cap)
    scan_attempted_at   TEXT NOT NULL DEFAULT ''         -- custom tracks: last failed scan, ISO8601 UTC
);
CREATE INDEX IF NOT EXISTS idx_tracks_priority ON tracks(priority);
CREATE INDEX IF NOT EXISTS idx_tracks_has_updates ON tracks(has_updates);
CREATE INDEX IF NOT EXISTS idx_tracks_updated ON tracks(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_tracks_ownership ON tracks(ownership);
CREATE INDEX IF NOT EXISTS idx_tracks_assignee ON tracks(assignee_user_id);
CREATE INDEX IF NOT EXISTS idx_tracks_origin ON tracks(origin);
CREATE INDEX IF NOT EXISTS idx_tracks_custom_enabled ON tracks(origin, enabled) WHERE origin = 'custom';

-- TRACKS-06: per-track narrative-state history
CREATE TABLE IF NOT EXISTS track_states (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    track_id           INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    text               TEXT NOT NULL,
    context            TEXT NOT NULL DEFAULT '',
    category           TEXT NOT NULL,
    ownership          TEXT NOT NULL,
    ball_on            TEXT NOT NULL DEFAULT '',  -- namespaced Slack user_id (see 00048)
    owner_user_id      TEXT NOT NULL DEFAULT '',  -- namespaced Slack user_id (see 00048)
    requester_name     TEXT NOT NULL DEFAULT '',
    requester_user_id  TEXT NOT NULL DEFAULT '',  -- namespaced Slack user_id (see 00048)
    blocking           TEXT NOT NULL DEFAULT '',
    decision_summary   TEXT NOT NULL DEFAULT '',
    decision_options   TEXT NOT NULL DEFAULT '[]',
    sub_items          TEXT NOT NULL DEFAULT '[]',
    participants       TEXT NOT NULL DEFAULT '[]',
    tags               TEXT NOT NULL DEFAULT '[]',
    priority           TEXT NOT NULL,
    due_date           REAL,
    source             TEXT NOT NULL CHECK(source IN ('extraction','manual')),
    model              TEXT NOT NULL DEFAULT '',
    prompt_version     INTEGER NOT NULL DEFAULT 0,
    created_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_track_states_track ON track_states(track_id, created_at DESC);

-- Channel digests whose track-extraction batch failed inside an otherwise
-- successful tracks run; re-offered to later runs, dropped after 3 failures.
CREATE TABLE IF NOT EXISTS track_retry_digests (
    digest_id  INTEGER PRIMARY KEY REFERENCES digests(id) ON DELETE CASCADE,
    attempts   INTEGER NOT NULL DEFAULT 0,             -- failed batches this digest was part of
    last_charged_day TEXT NOT NULL DEFAULT '',         -- UTC YYYY-MM-DD of the last charge; an all-failed run charges once per day
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Hierarchical goal targets (replaces tasks)
CREATE TABLE IF NOT EXISTS targets (
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
                        CHECK(status IN ('todo','in_progress','in_review','blocked','done','dismissed','snoozed')),
    priority            TEXT NOT NULL DEFAULT 'medium'
                        CHECK(priority IN ('high','medium','low')),
    ownership           TEXT NOT NULL DEFAULT 'mine'
                        CHECK(ownership IN ('mine','delegated','watching')),
    ball_on             TEXT NOT NULL DEFAULT '',  -- namespaced Slack user_id (see 00048)
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
    notified_at         TEXT NOT NULL DEFAULT '',  -- set once when an overdue target is surfaced to inbox
    next_step           TEXT NOT NULL DEFAULT '',  -- AI-suggested next action (JSON), generated by the next-step pipeline
    next_step_at        TEXT NOT NULL DEFAULT '',  -- when next_step was generated; compared to updated_at for staleness
    next_step_attempts     INTEGER NOT NULL DEFAULT 0,  -- attempts made since the last budget reset (see 00068)
    next_step_attempted_at TEXT NOT NULL DEFAULT '',   -- UTC ISO8601 of the most recent attempt (success or failure)
    project_id          INTEGER REFERENCES projects(id) ON DELETE CASCADE, -- set = lives only on that project's board (00081)
    status_actor        TEXT DEFAULT NULL  -- who makes this status write: agent|owner|system; cleared by the history trigger (00086)
                        CHECK(status_actor IS NULL OR status_actor IN ('agent','owner','system')),
    branch              TEXT NOT NULL DEFAULT '',  -- project targets: the git branch carrying the work (00089)
    pr                  TEXT NOT NULL DEFAULT '',  -- project targets: the pull request, a number or URL (00089)
    CHECK(status != 'in_review' OR project_id IS NOT NULL)  -- in_review exists only on a project board (00086)
);
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
CREATE INDEX IF NOT EXISTS idx_targets_project     ON targets(project_id);
-- Triggers targets_project_status_rollup_{ai,au,ad} (00085, PROJ-05): when a
-- project target (project_id set) is inserted, deleted, or changes status /
-- parent_id / project_id, its parent's status is re-derived from its direct
-- children of the same project (all closed with a done -> done; all dismissed
-- -> dismissed; every open child blocked -> blocked; any in_progress or done
-- -> in_progress; else todo; no children -> untouched), walking up the
-- ancestors while a status changes and never re-deriving a dismissed one.
-- A parent's own update is never rolled up. Full bodies: the migration file.
-- (00086: an in_review child counts as started like in_progress; a rollup
-- write sets status_actor = 'system'.)

-- Status history of project targets (00086, PROJ-06): one row per status
-- transition and one at creation (from_status NULL), written by the triggers
-- targets_status_history_{ai,au} for project targets only; actor copies
-- targets.status_actor (unset = 'owner'). Existing project targets were
-- seeded with one 'system' row dated by their updated_at.
CREATE TABLE IF NOT EXISTS target_status_history (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    target_id   INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    from_status TEXT,
    to_status   TEXT NOT NULL,
    changed_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),  -- UTC ISO-8601
    actor       TEXT NOT NULL CHECK(actor IN ('agent','owner','system'))
);
CREATE INDEX IF NOT EXISTS idx_target_status_history_target ON target_status_history(target_id, changed_at);

-- Links between targets or to external references
CREATE TABLE IF NOT EXISTS target_links (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    source_target_id INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    target_target_id INTEGER REFERENCES targets(id) ON DELETE CASCADE,
    external_ref     TEXT NOT NULL DEFAULT '',
    relation         TEXT NOT NULL
                     CHECK(relation IN ('contributes_to','blocks','related','duplicates')),
    confidence       REAL DEFAULT NULL,
    created_by       TEXT NOT NULL DEFAULT 'ai'
                     CHECK(created_by IN ('ai','user')),
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    CHECK (target_target_id IS NOT NULL OR external_ref != ''),
    UNIQUE(source_target_id, target_target_id, external_ref, relation)
);
CREATE INDEX IF NOT EXISTS idx_target_links_source   ON target_links(source_target_id);
CREATE INDEX IF NOT EXISTS idx_target_links_target   ON target_links(target_target_id);
CREATE INDEX IF NOT EXISTS idx_target_links_external ON target_links(external_ref);

-- track_events: the per-track activity timeline produced by the custom-track
-- scan engine. decision / proposed_action are optional JSON blobs ('' = absent).
-- proposed_action uses the same shape as the Desktop chat ProposedAction so the
-- existing executor applies it. action_status tracks the lifecycle of a
-- proposed_action.
CREATE TABLE IF NOT EXISTS track_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    track_id        INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    summary         TEXT NOT NULL DEFAULT '',
    detail          TEXT NOT NULL DEFAULT '',
    source_type     TEXT NOT NULL DEFAULT '',
    source_id       TEXT NOT NULL DEFAULT '',
    source_refs     TEXT NOT NULL DEFAULT '[]',
    decision        TEXT NOT NULL DEFAULT '',
    proposed_action TEXT NOT NULL DEFAULT '',
    action_status   TEXT NOT NULL DEFAULT 'none'
                    CHECK(action_status IN ('none','pending','applied','dismissed')),
    read_at         TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_track_events_track ON track_events(track_id, created_at DESC);

-- Inbox items — messages awaiting user response (@mentions, DMs, Jira, Calendar, etc.)
-- Defaults only since migration 00070 (inbox demolition): item_class, priority
-- and ai_reason were written by the retired triage stage, and why_matters /
-- thread_digest / draft_reply / card_status / card_generated_at / composed_at by
-- the retired card and composer stages. Detection still writes every other
-- column, so the table is live — recreating it to drop these buys nothing.
CREATE TABLE IF NOT EXISTS inbox_items (
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
CREATE INDEX IF NOT EXISTS idx_inbox_items_status ON inbox_items(status);
CREATE INDEX IF NOT EXISTS idx_inbox_items_priority ON inbox_items(priority);
CREATE INDEX IF NOT EXISTS idx_inbox_items_updated ON inbox_items(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_inbox_items_sender ON inbox_items(sender_user_id);
CREATE INDEX IF NOT EXISTS idx_inbox_items_snooze ON inbox_items(snooze_until);
CREATE INDEX IF NOT EXISTS idx_inbox_items_class_status ON inbox_items(item_class, status);
CREATE INDEX IF NOT EXISTS idx_inbox_items_archived ON inbox_items(archived_at);

-- Inbox learned rules — adaptive signal weights from implicit/explicit feedback
CREATE TABLE IF NOT EXISTS inbox_learned_rules (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_type      TEXT NOT NULL CHECK(rule_type IN ('source_mute','source_boost','trigger_downgrade','trigger_boost')),
    scope_key      TEXT NOT NULL,
    weight         REAL NOT NULL,
    source         TEXT NOT NULL CHECK(source IN ('implicit','explicit_feedback','user_rule')),
    evidence_count INTEGER NOT NULL DEFAULT 0,
    last_updated   TEXT NOT NULL,
    pipeline       TEXT NOT NULL DEFAULT 'inbox',
    UNIQUE(rule_type, scope_key)
);
CREATE INDEX IF NOT EXISTS idx_inbox_learned_rules_scope ON inbox_learned_rules(rule_type, scope_key);

-- Catch-Up — one persisted absence recap per time window (see 00061)
CREATE TABLE IF NOT EXISTS catchup_recaps (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    period_from     REAL NOT NULL,
    period_to       REAL NOT NULL,
    status          TEXT NOT NULL CHECK(status IN ('building','ready','failed')),
    tldr            TEXT NOT NULL DEFAULT '',
    body_json       TEXT NOT NULL DEFAULT '{}',
    coverage_json   TEXT NOT NULL DEFAULT '{}',
    error           TEXT NOT NULL DEFAULT '',
    regen_of_id     INTEGER REFERENCES catchup_recaps(id) ON DELETE SET NULL,
    acknowledged_at TEXT,
    model           TEXT NOT NULL DEFAULT '',
    input_tokens    INTEGER NOT NULL DEFAULT 0,
    output_tokens   INTEGER NOT NULL DEFAULT 0,
    cost_usd        REAL NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_catchup_recaps_ack ON catchup_recaps(acknowledged_at, period_to DESC);

-- Feedback on AI-generated content (thumbs up/down)
CREATE TABLE IF NOT EXISTS feedback (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL CHECK(entity_type IN ('digest', 'track', 'decision', 'user_analysis', 'briefing', 'target', 'inbox', 'catchup_theme', 'situation')),
    entity_id   TEXT NOT NULL,       -- digest.id, tracks.id, or "digest_id:decision_idx"
    rating      INTEGER NOT NULL CHECK(rating IN (-1, 1)),  -- -1 = bad, +1 = good
    comment     TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_feedback_entity ON feedback(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_feedback_rating ON feedback(entity_type, rating);

-- Editable AI prompt templates with versioning
CREATE TABLE IF NOT EXISTS prompts (
    id         TEXT PRIMARY KEY,  -- 'digest.channel', 'digest.daily', 'tracks.extract', etc.
    template   TEXT NOT NULL,
    version    INTEGER NOT NULL DEFAULT 1,
    language   TEXT NOT NULL DEFAULT '',  -- '' = auto-detect, 'en', 'ru', etc.
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    customized INTEGER NOT NULL DEFAULT 0  -- 1 = a tuner/user edit moved this off the default lineage; Seed's auto-upgrade skips it
);

-- Prompt version history for rollback and audit
CREATE TABLE IF NOT EXISTS prompt_history (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    prompt_id  TEXT NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,
    version    INTEGER NOT NULL,
    template   TEXT NOT NULL,
    reason     TEXT NOT NULL DEFAULT '',  -- "tuned: 12 negative feedbacks on decisions", "manual edit", "rollback to v3"
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_prompt_history_prompt ON prompt_history(prompt_id);
CREATE INDEX IF NOT EXISTS idx_prompt_history_version ON prompt_history(prompt_id, version);

-- User profile for personalization (role, team, reports, starred items)
CREATE TABLE IF NOT EXISTS user_profile (
    id                    INTEGER PRIMARY KEY,
    slack_user_id         TEXT NOT NULL UNIQUE,  -- namespaced "<slack_account_id>:<raw Slack user ID>" (see 00048)
    role                  TEXT NOT NULL DEFAULT '',
    team                  TEXT NOT NULL DEFAULT '',
    responsibilities      TEXT NOT NULL DEFAULT '[]',    -- JSON array of strings
    reports               TEXT NOT NULL DEFAULT '[]',    -- JSON array of Slack user_ids
    peers                 TEXT NOT NULL DEFAULT '[]',    -- JSON array of Slack user_ids
    manager               TEXT NOT NULL DEFAULT '',      -- namespaced Slack user_id (see 00048)
    starred_channels      TEXT NOT NULL DEFAULT '[]',    -- JSON array of channel_ids
    starred_people        TEXT NOT NULL DEFAULT '[]',    -- JSON array of Slack user_ids
    pain_points           TEXT NOT NULL DEFAULT '[]',    -- JSON array from onboarding
    track_focus           TEXT NOT NULL DEFAULT '[]',    -- JSON array of focus areas
    onboarding_done       INTEGER NOT NULL DEFAULT 0,
    custom_prompt_context TEXT NOT NULL DEFAULT '',
    created_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- User interaction edges (social graph) — computed per analysis window
CREATE TABLE IF NOT EXISTS user_interactions (
    user_a              TEXT NOT NULL,              -- current user ("me")
    user_b              TEXT NOT NULL,              -- the other person
    period_from         REAL NOT NULL,              -- analysis window start (Unix ts)
    period_to           REAL NOT NULL,              -- analysis window end (Unix ts)
    messages_to         INTEGER NOT NULL DEFAULT 0, -- A's messages in channels where B is active
    messages_from       INTEGER NOT NULL DEFAULT 0, -- B's messages in channels where A is active
    shared_channels     INTEGER NOT NULL DEFAULT 0, -- channels where both posted
    thread_replies_to   INTEGER NOT NULL DEFAULT 0, -- A replied to B's threads
    thread_replies_from INTEGER NOT NULL DEFAULT 0, -- B replied to A's threads
    shared_channel_ids  TEXT NOT NULL DEFAULT '[]', -- JSON array of shared channel IDs
    dm_messages_to      INTEGER NOT NULL DEFAULT 0, -- A's DM messages to B
    dm_messages_from    INTEGER NOT NULL DEFAULT 0, -- B's DM messages to A
    mentions_to         INTEGER NOT NULL DEFAULT 0, -- A @-mentioned B
    mentions_from       INTEGER NOT NULL DEFAULT 0, -- B @-mentioned A
    reactions_to        INTEGER NOT NULL DEFAULT 0, -- A reacted to B's messages
    reactions_from      INTEGER NOT NULL DEFAULT 0, -- B reacted to A's messages
    interaction_score   REAL NOT NULL DEFAULT 0,    -- weighted composite score
    connection_type     TEXT NOT NULL DEFAULT '',    -- peer, i_depend, depends_on_me, weak
    PRIMARY KEY (user_a, user_b, period_from, period_to)
);
CREATE INDEX IF NOT EXISTS idx_user_interactions_a ON user_interactions(user_a, period_from, period_to);

-- Unified people cards (per-user, per-window — combines analysis + guide)
CREATE TABLE IF NOT EXISTS people_cards (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id             TEXT NOT NULL,
    period_from         REAL NOT NULL,
    period_to           REAL NOT NULL,
    -- Computed stats (pure SQL, no AI)
    message_count       INTEGER NOT NULL DEFAULT 0,
    channels_active     INTEGER NOT NULL DEFAULT 0,
    threads_initiated   INTEGER NOT NULL DEFAULT 0,
    threads_replied     INTEGER NOT NULL DEFAULT 0,
    avg_message_length  REAL NOT NULL DEFAULT 0,
    active_hours_json   TEXT NOT NULL DEFAULT '{}',
    volume_change_pct   REAL NOT NULL DEFAULT 0,
    -- Analysis (from signals reduce)
    summary             TEXT NOT NULL DEFAULT '',
    communication_style TEXT NOT NULL DEFAULT '',
    decision_role       TEXT NOT NULL DEFAULT '',
    red_flags           TEXT NOT NULL DEFAULT '[]',
    highlights          TEXT NOT NULL DEFAULT '[]',
    accomplishments     TEXT NOT NULL DEFAULT '[]',
    -- Guide (coaching framing)
    communication_guide TEXT NOT NULL DEFAULT '',
    decision_style      TEXT NOT NULL DEFAULT '',
    tactics             TEXT NOT NULL DEFAULT '[]',
    -- Context
    relationship_context TEXT NOT NULL DEFAULT '',
    -- Status
    status              TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active', 'insufficient_data')),
    -- Metadata
    model               TEXT NOT NULL DEFAULT '',
    input_tokens        INTEGER NOT NULL DEFAULT 0,
    output_tokens       INTEGER NOT NULL DEFAULT 0,
    cost_usd            REAL NOT NULL DEFAULT 0,
    prompt_version      INTEGER NOT NULL DEFAULT 0,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(user_id, period_from, period_to)
);
CREATE INDEX IF NOT EXISTS idx_people_cards_user ON people_cards(user_id);
CREATE INDEX IF NOT EXISTS idx_people_cards_period ON people_cards(period_from, period_to);

-- People card summaries (cross-user team health for a time window)
CREATE TABLE IF NOT EXISTS people_card_summaries (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    period_from   REAL NOT NULL,
    period_to     REAL NOT NULL,
    summary       TEXT NOT NULL DEFAULT '',
    attention     TEXT NOT NULL DEFAULT '[]',
    tips          TEXT NOT NULL DEFAULT '[]',
    model         TEXT NOT NULL DEFAULT '',
    input_tokens  INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cost_usd      REAL NOT NULL DEFAULT 0,
    prompt_version INTEGER NOT NULL DEFAULT 0,
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(period_from, period_to)
);

-- Daily personalized briefings
CREATE TABLE IF NOT EXISTS briefings (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    workspace_id     TEXT NOT NULL DEFAULT '',
    user_id          TEXT NOT NULL,
    date             TEXT NOT NULL,              -- YYYY-MM-DD
    role             TEXT NOT NULL DEFAULT '',
    attention        TEXT NOT NULL DEFAULT '[]',
    your_day         TEXT NOT NULL DEFAULT '[]',
    what_happened    TEXT NOT NULL DEFAULT '[]',
    team_pulse       TEXT NOT NULL DEFAULT '[]',
    coaching         TEXT NOT NULL DEFAULT '[]',
    model            TEXT NOT NULL DEFAULT '',
    input_tokens     INTEGER NOT NULL DEFAULT 0,
    output_tokens    INTEGER NOT NULL DEFAULT 0,
    cost_usd         REAL NOT NULL DEFAULT 0,
    prompt_version   INTEGER NOT NULL DEFAULT 0,
    read_at          TEXT,
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE(user_id, date)
);
CREATE INDEX IF NOT EXISTS idx_briefings_user_date ON briefings(user_id, date DESC);

-- Per-channel user settings (mute for AI, favorite)
CREATE TABLE IF NOT EXISTS channel_settings (
    channel_id       TEXT PRIMARY KEY REFERENCES channels(id) ON DELETE CASCADE,
    is_muted_for_llm INTEGER NOT NULL DEFAULT 0,
    is_favorite      INTEGER NOT NULL DEFAULT 0,
    updated_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Pipeline run history — logs every pipeline invocation (CLI, daemon, desktop)
CREATE TABLE IF NOT EXISTS pipeline_runs (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    pipeline         TEXT NOT NULL,                          -- 'digests', 'tracks', 'people', 'briefing'
    source           TEXT NOT NULL DEFAULT 'cli',            -- 'cli', 'daemon'
    model            TEXT NOT NULL DEFAULT '',
    status           TEXT NOT NULL DEFAULT 'running' CHECK(status IN ('running', 'done', 'error')),
    error_msg        TEXT NOT NULL DEFAULT '',
    items_found      INTEGER NOT NULL DEFAULT 0,
    input_tokens     INTEGER NOT NULL DEFAULT 0,
    output_tokens    INTEGER NOT NULL DEFAULT 0,
    cost_usd         REAL NOT NULL DEFAULT 0,
    total_api_tokens INTEGER NOT NULL DEFAULT 0,
    period_from      REAL,
    period_to        REAL,
    started_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    finished_at      TEXT,
    duration_seconds REAL NOT NULL DEFAULT 0,
    cache_read_tokens     INTEGER NOT NULL DEFAULT 0,  -- prompt-cache read tokens (billed cheaper, recorded separately)
    cache_creation_tokens INTEGER NOT NULL DEFAULT 0   -- prompt-cache creation tokens
);
CREATE INDEX IF NOT EXISTS idx_pipeline_runs_pipeline ON pipeline_runs(pipeline);
CREATE INDEX IF NOT EXISTS idx_pipeline_runs_started ON pipeline_runs(started_at DESC);

-- Pipeline steps — per-step detail within a run
CREATE TABLE IF NOT EXISTS pipeline_steps (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id           INTEGER NOT NULL REFERENCES pipeline_runs(id) ON DELETE CASCADE,
    step             INTEGER NOT NULL,
    total            INTEGER NOT NULL,
    status           TEXT NOT NULL DEFAULT '',
    channel_id       TEXT NOT NULL DEFAULT '',  -- namespaced "<slack_account_id>:<raw channel ID>" (see 00048)
    channel_name     TEXT NOT NULL DEFAULT '',
    input_tokens     INTEGER NOT NULL DEFAULT 0,
    output_tokens    INTEGER NOT NULL DEFAULT 0,
    cost_usd         REAL NOT NULL DEFAULT 0,
    total_api_tokens INTEGER NOT NULL DEFAULT 0,
    message_count    INTEGER NOT NULL DEFAULT 0,
    period_from      REAL,
    period_to        REAL,
    duration_seconds REAL NOT NULL DEFAULT 0,
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_pipeline_steps_run ON pipeline_steps(run_id);

-- Google Calendar calendars
CREATE TABLE IF NOT EXISTS calendar_calendars (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    is_primary  INTEGER NOT NULL DEFAULT 0,
    is_selected INTEGER NOT NULL DEFAULT 1,
    color       TEXT NOT NULL DEFAULT '',
    synced_at   TEXT NOT NULL DEFAULT '',
    account_id  INTEGER REFERENCES google_accounts(id)  -- NULL for caldav:/ics: rows (see 00043)
);

-- Calendar events (synced from Google Calendar)
CREATE TABLE IF NOT EXISTS calendar_events (
    id              TEXT PRIMARY KEY,
    calendar_id     TEXT NOT NULL REFERENCES calendar_calendars(id),
    title           TEXT NOT NULL DEFAULT '',
    description     TEXT NOT NULL DEFAULT '',
    location        TEXT NOT NULL DEFAULT '',
    start_time      TEXT NOT NULL,           -- ISO8601
    end_time        TEXT NOT NULL,           -- ISO8601
    organizer_email TEXT NOT NULL DEFAULT '',
    attendees       TEXT NOT NULL DEFAULT '[]',  -- JSON array
    is_recurring    INTEGER NOT NULL DEFAULT 0,
    is_all_day      INTEGER NOT NULL DEFAULT 0,
    event_status    TEXT NOT NULL DEFAULT 'confirmed',
    event_type      TEXT NOT NULL DEFAULT '',
    html_link       TEXT NOT NULL DEFAULT '',
    conference_url  TEXT NOT NULL DEFAULT '',  -- meeting join link (Meet/Zoom/Teams/Webex), '' when none (see 00044)
    raw_json        TEXT NOT NULL DEFAULT '{}',
    ical_uid        TEXT NOT NULL DEFAULT '',  -- dedup enabler across accounts/providers (see 00043)
    synced_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT '',
    time_changed_at TEXT NOT NULL DEFAULT '',  -- sync pass that last saw start/end move, '' never (see 00079)
    rsvp_changed    TEXT NOT NULL DEFAULT '{}' -- JSON {lower(email): synced_at of the pass that saw their RSVP change} (see 00079)
);
CREATE INDEX IF NOT EXISTS idx_calendar_events_calendar ON calendar_events(calendar_id);
CREATE INDEX IF NOT EXISTS idx_calendar_events_start ON calendar_events(start_time);
CREATE INDEX IF NOT EXISTS idx_calendar_events_end ON calendar_events(end_time);

-- Calendar attendee email to Slack user_id mapping cache
CREATE TABLE IF NOT EXISTS calendar_attendee_map (
    email          TEXT PRIMARY KEY,
    slack_user_id  TEXT NOT NULL DEFAULT '',
    resolved_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE IF NOT EXISTS meeting_prep_cache (
    event_id      TEXT PRIMARY KEY,
    result_json   TEXT NOT NULL DEFAULT '',
    user_notes    TEXT NOT NULL DEFAULT '',
    generated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_meeting_prep_cache_generated ON meeting_prep_cache(generated_at);

-- Multi-account Jira source: one row per connected Atlassian site (see 00049).
-- Site-scoped tables carry an account_id column with a composite PK (the
-- google_accounts route, not Slack's namespaced ids — issue keys are
-- user-visible and must stay bare). Bare-key lookups keep working; a key
-- shared by two sites is a documented v1 ambiguity.
CREATE TABLE IF NOT EXISTS jira_accounts (
    id                            INTEGER PRIMARY KEY AUTOINCREMENT,
    cloud_id                      TEXT NOT NULL DEFAULT '',
    site_url                      TEXT NOT NULL DEFAULT '',
    site_name                     TEXT NOT NULL DEFAULT '',
    label                         TEXT NOT NULL DEFAULT '',
    status                        TEXT NOT NULL DEFAULT 'ok',  -- ok | error | revoked | removed
    error                         TEXT NOT NULL DEFAULT '',
    enabled                       INTEGER NOT NULL DEFAULT 1,
    memory_jira_last_extracted_ts REAL NOT NULL DEFAULT 0,  -- per-account memory extraction watermark (was on workspace)
    ideas_jira_floor              TEXT NOT NULL DEFAULT '',  -- ideas registry floor: per-account Jira comment-sync watermark for the jira pre-digest (see 00050)
    created_at                    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    owner_account_id              TEXT NOT NULL DEFAULT '',  -- the connecting person's own Atlassian identity from GET /rest/api/3/myself; feeds db.ResolveOwner's Jira rung (see 00071)
    owner_email                   TEXT NOT NULL DEFAULT '',
    owner_display_name            TEXT NOT NULL DEFAULT ''
);

-- Jira boards
CREATE TABLE IF NOT EXISTS jira_boards (
    account_id INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    id INTEGER NOT NULL, name TEXT NOT NULL, project_key TEXT NOT NULL DEFAULT '',
    board_type TEXT NOT NULL DEFAULT '', is_selected INTEGER NOT NULL DEFAULT 0,
    issue_count INTEGER NOT NULL DEFAULT 0, synced_at TEXT NOT NULL DEFAULT '',
    raw_columns_json TEXT NOT NULL DEFAULT '',
    raw_config_json TEXT NOT NULL DEFAULT '',
    llm_profile_json TEXT NOT NULL DEFAULT '',
    workflow_summary TEXT NOT NULL DEFAULT '',
    user_overrides_json TEXT NOT NULL DEFAULT '',
    config_hash TEXT NOT NULL DEFAULT '',
    profile_generated_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, id)
);

-- Jira custom fields (discovered from API, classified by LLM)
CREATE TABLE IF NOT EXISTS jira_custom_fields (
    account_id INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    id TEXT NOT NULL,
    name TEXT NOT NULL,
    field_type TEXT NOT NULL,
    items_type TEXT NOT NULL DEFAULT '',
    is_useful INTEGER NOT NULL DEFAULT 0,
    usage_hint TEXT NOT NULL DEFAULT '',
    synced_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, id)
);

-- Per-board custom field mapping
CREATE TABLE IF NOT EXISTS jira_board_field_map (
    account_id INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    board_id INTEGER NOT NULL,
    field_id TEXT NOT NULL,
    role TEXT NOT NULL,
    PRIMARY KEY (account_id, board_id, field_id)
);

-- Jira issues
CREATE TABLE IF NOT EXISTS jira_issues (
    account_id INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    key TEXT NOT NULL, id TEXT NOT NULL DEFAULT '', project_key TEXT NOT NULL,
    board_id INTEGER,
    summary TEXT NOT NULL, description_text TEXT NOT NULL DEFAULT '',
    issue_type TEXT NOT NULL DEFAULT '', issue_type_category TEXT NOT NULL DEFAULT '',
    is_bug INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL, status_category TEXT NOT NULL,
    status_category_changed_at TEXT NOT NULL DEFAULT '',
    assignee_account_id TEXT NOT NULL DEFAULT '', assignee_email TEXT NOT NULL DEFAULT '',
    assignee_display_name TEXT NOT NULL DEFAULT '', assignee_slack_id TEXT NOT NULL DEFAULT '',
    reporter_account_id TEXT NOT NULL DEFAULT '', reporter_email TEXT NOT NULL DEFAULT '',
    reporter_display_name TEXT NOT NULL DEFAULT '', reporter_slack_id TEXT NOT NULL DEFAULT '',
    priority TEXT NOT NULL DEFAULT '', story_points REAL,
    due_date TEXT NOT NULL DEFAULT '', sprint_id INTEGER, sprint_name TEXT NOT NULL DEFAULT '',
    epic_key TEXT NOT NULL DEFAULT '',
    labels TEXT NOT NULL DEFAULT '[]', components TEXT NOT NULL DEFAULT '[]',
    fix_versions TEXT NOT NULL DEFAULT '[]',
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL, resolved_at TEXT NOT NULL DEFAULT '',
    raw_json TEXT NOT NULL DEFAULT '', custom_fields_json TEXT NOT NULL DEFAULT '',
    synced_at TEXT NOT NULL, is_deleted INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, key)
);
CREATE INDEX IF NOT EXISTS idx_jira_issues_project ON jira_issues(project_key);
CREATE INDEX IF NOT EXISTS idx_jira_issues_assignee ON jira_issues(assignee_account_id);
CREATE INDEX IF NOT EXISTS idx_jira_issues_status_cat ON jira_issues(status_category);
CREATE INDEX IF NOT EXISTS idx_jira_issues_sprint ON jira_issues(sprint_id);
CREATE INDEX IF NOT EXISTS idx_jira_issues_epic ON jira_issues(epic_key);
CREATE INDEX IF NOT EXISTS idx_jira_issues_updated ON jira_issues(updated_at);
CREATE INDEX IF NOT EXISTS idx_jira_issues_due ON jira_issues(due_date);
CREATE INDEX IF NOT EXISTS idx_jira_issues_board ON jira_issues(board_id);

-- Jira sprints
CREATE TABLE IF NOT EXISTS jira_sprints (
    account_id INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    id INTEGER NOT NULL, board_id INTEGER NOT NULL, name TEXT NOT NULL,
    state TEXT NOT NULL, goal TEXT NOT NULL DEFAULT '',
    start_date TEXT NOT NULL DEFAULT '', end_date TEXT NOT NULL DEFAULT '',
    complete_date TEXT NOT NULL DEFAULT '', synced_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, id)
);

-- Jira issue links
CREATE TABLE IF NOT EXISTS jira_issue_links (
    account_id INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    id TEXT NOT NULL, source_key TEXT NOT NULL, target_key TEXT NOT NULL,
    link_type TEXT NOT NULL, synced_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, id)
);

-- Jira user mapping — intentionally NOT account-scoped: Atlassian account
-- ids are globally unique across sites (see 00049)
CREATE TABLE IF NOT EXISTS jira_user_map (
    jira_account_id TEXT PRIMARY KEY, email TEXT NOT NULL DEFAULT '',
    slack_user_id TEXT NOT NULL DEFAULT '', display_name TEXT NOT NULL DEFAULT '',
    match_method TEXT NOT NULL DEFAULT '', match_confidence REAL NOT NULL DEFAULT 0,
    resolved_at TEXT NOT NULL DEFAULT ''
);

-- Jira Slack links (key detection) — intentionally NOT account-scoped:
-- keys detected in Slack text are site-ambiguous by nature (see 00049)
CREATE TABLE IF NOT EXISTS jira_slack_links (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    issue_key TEXT NOT NULL,
    channel_id TEXT NOT NULL DEFAULT '',
    message_ts TEXT NOT NULL DEFAULT '',
    track_id INTEGER,
    digest_id INTEGER,
    link_type TEXT NOT NULL DEFAULT 'mention',
    detected_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_jira_slack_links_issue ON jira_slack_links(issue_key);
CREATE INDEX IF NOT EXISTS idx_jira_slack_links_channel ON jira_slack_links(channel_id, message_ts);
CREATE INDEX IF NOT EXISTS idx_jira_slack_links_track ON jira_slack_links(track_id);
CREATE INDEX IF NOT EXISTS idx_jira_slack_links_digest ON jira_slack_links(digest_id);
-- One identity per link kind (see 00067): only a mention carries a real
-- message_ts, so a track link is identified by its track and a decision link by
-- its digest. A shared identity made them overwrite one another.
CREATE UNIQUE INDEX IF NOT EXISTS idx_jira_slack_links_mention_identity
    ON jira_slack_links(issue_key, channel_id, message_ts) WHERE link_type = 'mention';
CREATE UNIQUE INDEX IF NOT EXISTS idx_jira_slack_links_track_identity
    ON jira_slack_links(issue_key, track_id) WHERE link_type = 'track';
CREATE UNIQUE INDEX IF NOT EXISTS idx_jira_slack_links_decision_identity
    ON jira_slack_links(issue_key, digest_id) WHERE link_type = 'decision';

CREATE INDEX IF NOT EXISTS idx_jira_issues_assignee_slack ON jira_issues(assignee_slack_id);
CREATE INDEX IF NOT EXISTS idx_jira_issues_assignee_status ON jira_issues(assignee_slack_id, status_category);
-- Bare-key lookups: the composite PK leads with account_id, so this index is
-- what keeps `WHERE key = ?` off a full scan (see 00049)
CREATE INDEX IF NOT EXISTS idx_jira_issues_key ON jira_issues(key);
CREATE INDEX IF NOT EXISTS idx_jira_issues_synced ON jira_issues(synced_at);

-- Jira sync state
CREATE TABLE IF NOT EXISTS jira_sync_state (
    account_id INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    project_key TEXT NOT NULL, last_synced_at TEXT NOT NULL DEFAULT '',
    issues_synced INTEGER NOT NULL DEFAULT 0, last_error TEXT NOT NULL DEFAULT '',
    last_error_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, project_key)
);

-- Meeting notes (questions + freeform notes linked to calendar events)
CREATE TABLE IF NOT EXISTS meeting_notes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT NOT NULL,
    type TEXT NOT NULL CHECK(type IN ('question', 'note')),
    text TEXT NOT NULL DEFAULT '',
    is_checked INTEGER NOT NULL DEFAULT 0,
    sort_order INTEGER NOT NULL DEFAULT 0,
    task_id INTEGER,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_meeting_notes_event ON meeting_notes(event_id);

-- Meeting recaps (AI-generated post-meeting summary; one row per event). A
-- surrogate id PK + nullable UNIQUE event_id ON DELETE SET NULL (see 00056) —
-- the meeting_transcripts shape — so a recap outlives its calendar event when
-- the daemon's stale-event cleanup ages the event out (event_id nulled)
-- instead of being cascade-deleted. transcript_id is the durable link back to
-- the meeting_transcripts row (also ON DELETE SET NULL) so an orphaned recap
-- (event deleted) stays reachable via GetMeetingRecapByTranscript.
CREATE TABLE IF NOT EXISTS meeting_recaps (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id      TEXT UNIQUE REFERENCES calendar_events(id) ON DELETE SET NULL,
    transcript_id INTEGER REFERENCES meeting_transcripts(id) ON DELETE SET NULL,
    source_text   TEXT NOT NULL,
    recap_json    TEXT NOT NULL,
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Meeting transcripts: locally-transcribed meeting audio (WhisperKit in the
-- Desktop app). One row per recording. event_id is NULL for ad-hoc recordings
-- and survives event deletion (SET NULL) — a transcript must outlive its
-- calendar event. audio_path is NULLed by the daemon retention phase once the
-- audio file is deleted; transcript_text is kept forever. summary_json holds
-- the recap for ad-hoc recordings only (event-linked recaps live in
-- meeting_recaps). segments_json is a JSON array of per-utterance segments
-- ({"idx","start_sec","end_sec","speaker","text","deleted"}); NULL for legacy
-- rows. Invariant: when non-NULL, transcript_text = render(segments where
-- !deleted). speakers_json is a JSON array of per-cluster voice embeddings
-- ({"speaker","embedding"}); NULL when the diarizer produced none.
-- chapters_json is the AI-generated chapter breakdown
-- ({"overall_summary", "chapters": [{"title","start_sec","end_sec",
-- "participants","summary","decisions","action_items","open_questions"}]});
-- each action item is {"text","converted_target_id"} — converted_target_id
-- links the Target created from it.
CREATE TABLE IF NOT EXISTS meeting_transcripts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id        TEXT REFERENCES calendar_events(id) ON DELETE SET NULL,
    title           TEXT NOT NULL,
    audio_path      TEXT,
    duration_sec    INTEGER NOT NULL DEFAULT 0,
    lang_stats      TEXT NOT NULL DEFAULT '',
    transcript_text TEXT NOT NULL,
    summary_json    TEXT,
    notes_md        TEXT,
    segments_json   TEXT,
    speakers_json   TEXT,
    chapters_json   TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    speaker_names_changed_at TEXT,
    summary_updated_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_meeting_transcripts_event ON meeting_transcripts(event_id);

-- FTS5 virtual table for full-text search on meeting transcripts
CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(
    text,
    transcript_id UNINDEXED,
    title UNINDEXED,
    tokenize='porter unicode61'
);

-- Triggers to keep the FTS index in sync with meeting_transcripts
CREATE TRIGGER IF NOT EXISTS meeting_transcripts_ai AFTER INSERT ON meeting_transcripts
WHEN NEW.transcript_text != ''
BEGIN
    DELETE FROM transcripts_fts WHERE transcript_id = NEW.id;
    INSERT INTO transcripts_fts(text, transcript_id, title)
    VALUES (NEW.transcript_text, NEW.id, NEW.title);
END;

CREATE TRIGGER IF NOT EXISTS meeting_transcripts_ad AFTER DELETE ON meeting_transcripts
BEGIN
    DELETE FROM transcripts_fts WHERE transcript_id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS meeting_transcripts_au AFTER UPDATE OF transcript_text, title ON meeting_transcripts
WHEN OLD.transcript_text != NEW.transcript_text OR OLD.title != NEW.title
BEGIN
    DELETE FROM transcripts_fts WHERE transcript_id = OLD.id;
    INSERT INTO transcripts_fts(text, transcript_id, title)
    SELECT NEW.transcript_text, NEW.id, NEW.title
    WHERE NEW.transcript_text != '';
END;

-- Voice registry (migration 00080, spec
-- docs/superpowers/specs/2026-09-28-voice-registry-design.md): voice_prints
-- is one row per known person, learned from manual speaker renames in the
-- Desktop transcript view (person_key = attendee email, or a normalized
-- display name when no email). Voices live as per-sample rows in
-- voice_samples (nearest-sample matching, owner anchors, self-training,
-- imports) rather than one centroid embedding per person. Prints are
-- exported only by an explicit owner action as an encrypted file of
-- embeddings (never automatically).
CREATE TABLE IF NOT EXISTS voice_prints (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    person_key   TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- One row per imported voice-print file (an owner sharing their exported
-- prints with a colleague). file_sha256 is the dedup key for a re-import.
CREATE TABLE IF NOT EXISTS voice_imports (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    sender_name   TEXT NOT NULL,
    sender_email  TEXT NOT NULL DEFAULT '',
    file_sha256   TEXT NOT NULL UNIQUE,
    people_count  INTEGER NOT NULL,
    sample_count  INTEGER NOT NULL,
    model_version TEXT NOT NULL,
    imported_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Per-sample voice embeddings (256-dim float32, little-endian BLOB): owner
-- anchors (origin='owner', anchor=1, the only samples an owner directly
-- confirmed), auto self-training samples pulled from diarized transcripts,
-- and imported samples from a colleague's voice_imports file. A sample is
-- matched nearest-neighbor, not centroid-averaged. anchor=1 is restricted to
-- origin='owner' by the CHECK below.
CREATE TABLE IF NOT EXISTS voice_samples (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    person_id     INTEGER NOT NULL REFERENCES voice_prints(id) ON DELETE CASCADE,
    embedding     BLOB NOT NULL,
    model_version TEXT NOT NULL,
    origin        TEXT NOT NULL CHECK (origin IN ('owner', 'auto', 'imported')),
    anchor        INTEGER NOT NULL DEFAULT 0 CHECK (anchor IN (0, 1)),
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'pending', 'retired')),
    transcript_id INTEGER REFERENCES meeting_transcripts(id) ON DELETE SET NULL,
    cluster_label TEXT,
    channel       TEXT NOT NULL DEFAULT 'unknown' CHECK (channel IN ('room', 'remote', 'unknown')),
    score         REAL,
    speech_sec    REAL NOT NULL DEFAULT 0,
    import_id     INTEGER REFERENCES voice_imports(id) ON DELETE CASCADE,
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    CHECK (anchor = 0 OR origin = 'owner')
);
CREATE INDEX IF NOT EXISTS idx_voice_samples_person_status ON voice_samples(person_id, status);
CREATE INDEX IF NOT EXISTS idx_voice_samples_transcript ON voice_samples(transcript_id);

-- Queue of speaker-cluster labeling tasks the owner should resolve (an
-- unsure/unknown diarized cluster, an import awaiting confirmation, a
-- conflict, or a relabel). At most one pending task per transcript+cluster.
CREATE TABLE IF NOT EXISTS voice_label_queue (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    transcript_id       INTEGER NOT NULL REFERENCES meeting_transcripts(id) ON DELETE CASCADE,
    cluster_label       TEXT NOT NULL,
    reason              TEXT NOT NULL CHECK (reason IN ('unsure', 'unknown', 'import_confirm', 'conflict', 'relabel')),
    suggested_person_id INTEGER REFERENCES voice_prints(id) ON DELETE SET NULL,
    score               REAL,
    status              TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'done', 'skipped')),
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    resolved_at         TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_voice_label_queue_open ON voice_label_queue(transcript_id, cluster_label) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_voice_label_queue_status ON voice_label_queue(status, created_at);

-- Gmail messages (synced inbox items from Gmail). account_id + composite PK
-- scope messages per Google account (see 00043); calendar_auth_state/
-- gmail_auth_state singletons are retired in favor of google_accounts below.
CREATE TABLE IF NOT EXISTS gmail_messages (
    account_id     INTEGER NOT NULL REFERENCES google_accounts(id) ON DELETE CASCADE,
    id             TEXT NOT NULL,                 -- Gmail message ID
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
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (account_id, id)
);
CREATE INDEX IF NOT EXISTS idx_gmail_messages_thread ON gmail_messages(thread_id);
CREATE INDEX IF NOT EXISTS idx_gmail_messages_synced ON gmail_messages(synced_at);

-- Multi-account Google source: one row per connected Google account (Gmail
-- and/or Calendar). Replaces the calendar_auth_state / gmail_auth_state
-- singletons — status/error/watermarks now live per account here (see 00043).
CREATE TABLE IF NOT EXISTS google_accounts (
    id                             INTEGER PRIMARY KEY AUTOINCREMENT,
    email                          TEXT NOT NULL DEFAULT '',
    label                          TEXT NOT NULL DEFAULT '',
    client_id                      TEXT NOT NULL DEFAULT '',  -- non-secret half of a custom OAuth client; '' = build-time default
    calendar_enabled               INTEGER NOT NULL DEFAULT 0,
    gmail_enabled                  INTEGER NOT NULL DEFAULT 0,
    status                         TEXT NOT NULL DEFAULT 'ok',  -- ok | error | revoked
    error                          TEXT NOT NULL DEFAULT '',
    gmail_last_internal_date       REAL NOT NULL DEFAULT 0,   -- per-account Gmail sync watermark
    memory_gmail_last_extracted_ts REAL NOT NULL DEFAULT 0,   -- per-account memory extraction watermark
    ideas_email_floor              REAL NOT NULL DEFAULT 0,   -- ideas registry floor: per-account Gmail internalDate watermark for the email pre-digest (see 00050)
    created_at                     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at                     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Multi-account Slack source: one row per connected Slack workspace.
-- Every Slack-derived id column across the schema (channels.id, users.id,
-- messages.channel_id/user_id, etc.) is namespaced "<accountID>:<rawID>" so
-- multiple workspaces can coexist without id collisions (see 00048).
CREATE TABLE IF NOT EXISTS slack_accounts (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    team_id           TEXT NOT NULL DEFAULT '',
    team_name         TEXT NOT NULL DEFAULT '',
    team_domain       TEXT NOT NULL DEFAULT '',
    label             TEXT NOT NULL DEFAULT '',
    current_user_id   TEXT NOT NULL DEFAULT '',  -- namespaced, e.g. "1:U0123"
    status            TEXT NOT NULL DEFAULT 'ok',  -- ok | error | revoked | removed
    error             TEXT NOT NULL DEFAULT '',
    enabled           INTEGER NOT NULL DEFAULT 1,
    search_last_date  TEXT NOT NULL DEFAULT '',
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    reaction_commands_seeded_at TEXT NOT NULL DEFAULT ''  -- when the reaction-commands ledger was seeded with this account's history; '' = never
);

-- Multi-account IMAP/Outlook email source: one row per connected mailbox
-- (email_accounts) plus its synced messages (imap_messages). status/error
-- live directly on email_accounts, the same pattern google_accounts uses
-- for Gmail's multi-account model.
CREATE TABLE IF NOT EXISTS email_accounts (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    provider       TEXT NOT NULL CHECK(provider IN ('imap','outlook')),
    email_address  TEXT NOT NULL DEFAULT '',
    host           TEXT NOT NULL DEFAULT '',
    port           INTEGER NOT NULL DEFAULT 0,
    security       TEXT NOT NULL DEFAULT 'ssl' CHECK(security IN ('ssl','starttls','none')),
    folder         TEXT NOT NULL DEFAULT 'INBOX',
    label          TEXT NOT NULL DEFAULT '',      -- user-facing display name
    status         TEXT NOT NULL DEFAULT 'ok',    -- ok | error | revoked
    error          TEXT NOT NULL DEFAULT '',
    last_uid       INTEGER NOT NULL DEFAULT 0,    -- sync watermark: highest IMAP UID synced
    uidvalidity    INTEGER NOT NULL DEFAULT 0,    -- IMAP UIDVALIDITY; a change means last_uid must reset
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE IF NOT EXISTS imap_messages (
    account_id     INTEGER NOT NULL REFERENCES email_accounts(id) ON DELETE CASCADE,
    uid            INTEGER NOT NULL,              -- IMAP UID; unique within (account_id, uidvalidity, uid)
    uidvalidity    INTEGER NOT NULL DEFAULT 0,    -- IMAP UIDVALIDITY epoch this uid was assigned under
    from_email     TEXT NOT NULL DEFAULT '',
    from_name      TEXT NOT NULL DEFAULT '',
    to_json        TEXT NOT NULL DEFAULT '[]',    -- JSON array of recipient emails (To)
    cc_json        TEXT NOT NULL DEFAULT '[]',    -- JSON array of recipient emails (Cc)
    subject        TEXT NOT NULL DEFAULT '',
    snippet        TEXT NOT NULL DEFAULT '',
    body_text      TEXT NOT NULL DEFAULT '',      -- full plain-text body (truncated at sync)
    internal_date  TEXT NOT NULL DEFAULT '',      -- ISO8601 message time
    is_unread      INTEGER NOT NULL DEFAULT 0,
    permalink      TEXT NOT NULL DEFAULT '',
    synced_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (account_id, uidvalidity, uid)
);
CREATE INDEX IF NOT EXISTS idx_imap_messages_synced ON imap_messages(synced_at);

-- Multi-account open-protocol calendar sources: one row per connected CalDAV
-- server or secret ICS feed (the calendar analog of email_accounts). Events
-- land in the shared calendar_events table scoped by calendar_id =
-- 'caldav:<id>' / 'ics:<id>'. For provider='ics' the url column stays empty:
-- the secret feed URL is a credential and lives in the per-account
-- credential file, never the DB.
CREATE TABLE IF NOT EXISTS calendar_accounts (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    provider   TEXT NOT NULL CHECK(provider IN ('caldav','ics')),
    username   TEXT NOT NULL DEFAULT '',
    url        TEXT NOT NULL DEFAULT '',      -- CalDAV server base URL ONLY; empty for provider='ics'
    label      TEXT NOT NULL DEFAULT '',      -- user-facing display name
    status     TEXT NOT NULL DEFAULT 'ok',    -- ok | error | revoked
    error      TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Jira releases (fix versions)
CREATE TABLE IF NOT EXISTS jira_releases (
    account_id INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    id INTEGER NOT NULL,
    project_key TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    release_date TEXT NOT NULL DEFAULT '',
    released INTEGER NOT NULL DEFAULT 0,
    archived INTEGER NOT NULL DEFAULT 0,
    synced_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, id),
    UNIQUE(account_id, project_key, name)
);

-- Day plans (AI-generated daily schedule for the current user)
CREATE TABLE IF NOT EXISTS day_plans (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id              TEXT NOT NULL,
    plan_date            TEXT NOT NULL,
    status               TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
    has_conflicts        INTEGER NOT NULL DEFAULT 0,
    conflict_summary     TEXT,
    generated_at         TEXT NOT NULL,
    last_regenerated_at  TEXT,
    regenerate_count     INTEGER NOT NULL DEFAULT 0,
    feedback_history     TEXT,
    prompt_version       TEXT,
    briefing_id          INTEGER,
    read_at              TEXT,
    created_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    UNIQUE (user_id, plan_date),
    FOREIGN KEY (briefing_id) REFERENCES briefings(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_day_plans_date ON day_plans(plan_date DESC);
CREATE INDEX IF NOT EXISTS idx_day_plans_user_date ON day_plans(user_id, plan_date DESC);

-- Day plan items (individual blocks/backlog entries within a day plan)
CREATE TABLE IF NOT EXISTS day_plan_items (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    day_plan_id  INTEGER NOT NULL,
    kind         TEXT NOT NULL CHECK (kind IN ('timeblock','backlog')),
    source_type  TEXT NOT NULL CHECK (source_type IN ('task','briefing_attention','jira','calendar','manual','focus')),
    source_id    TEXT,
    title        TEXT NOT NULL,
    description  TEXT,
    rationale    TEXT,
    start_time   TEXT,
    end_time     TEXT,
    duration_min INTEGER,
    priority     TEXT CHECK (priority IS NULL OR priority IN ('high','medium','low')),
    status       TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','done','skipped')),
    order_index  INTEGER NOT NULL DEFAULT 0,
    tags         TEXT,
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    FOREIGN KEY (day_plan_id) REFERENCES day_plans(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_day_plan_items_plan ON day_plan_items(day_plan_id);
CREATE INDEX IF NOT EXISTS idx_day_plan_items_source ON day_plan_items(source_type, source_id);

-- Situations (clusters of inbox signals composed into a single narrative unit
-- for the secretary dashboard). Frozen read-only history since migration 00070
-- (inbox demolition): the composer and its cards are gone, no writer remains,
-- and every row that was still 'open' was set to 'stale'. Kept because
-- converted_target_id/converted_track_id links and targets.source_type =
-- 'situation' rows still point here.
CREATE TABLE IF NOT EXISTS situations (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    title           TEXT NOT NULL,
    kind            TEXT NOT NULL DEFAULT 'external' CHECK(kind IN ('external','target_update','track_update','mixed')),
    status          TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','done','dismissed','converted','stale','snoozed')),
    snooze_until    TEXT NOT NULL DEFAULT '',
    priority        TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('high','medium','low')),
    rank            REAL NOT NULL DEFAULT 0,
    ai_reason       TEXT NOT NULL DEFAULT '',
    summary         TEXT NOT NULL DEFAULT '',
    why_matters     TEXT NOT NULL DEFAULT '',
    chronology      TEXT NOT NULL DEFAULT '',
    card_status     TEXT NOT NULL DEFAULT 'none' CHECK(card_status IN ('none','ready','failed')),
    card_generated_at TEXT,
    target_id       INTEGER,
    track_id        INTEGER,
    converted_target_id INTEGER,
    converted_track_id  INTEGER,
    last_signal_at  TEXT NOT NULL DEFAULT '',
    resolved_reason TEXT NOT NULL DEFAULT '',
    -- The secretary's "looks resolved" mark (DASH-07): set by the composer's
    -- suggest_resolve op when new material shows the story concluded without the
    -- owner acting; cleared by a later merge without a re-suggest, or by the
    -- user's "Keep open". Never closes the situation — status stays 'open'.
    suggested_resolution TEXT NOT NULL DEFAULT '',
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_situations_status_rank ON situations(status, rank DESC);
CREATE INDEX IF NOT EXISTS idx_situations_updated ON situations(updated_at DESC);

-- Situation signals (join table linking situations to their constituent inbox items)
CREATE TABLE IF NOT EXISTS situation_signals (
    situation_id   INTEGER NOT NULL REFERENCES situations(id) ON DELETE CASCADE,
    inbox_item_id  INTEGER NOT NULL REFERENCES inbox_items(id) ON DELETE CASCADE,
    UNIQUE(situation_id, inbox_item_id)
);
CREATE INDEX IF NOT EXISTS idx_situation_signals_item ON situation_signals(inbox_item_id);

-- Secretary memory index — rebuildable SQLite mirror of the markdown vault
-- (files + git are the source of truth; MEM-02: drop all memory_* tables and
-- reindex reproduces this index).
CREATE TABLE IF NOT EXISTS memory_nodes (
    id            TEXT PRIMARY KEY,             -- ent_*/ep_*/sum_*/bel_*
    type          TEXT NOT NULL CHECK (type IN ('entity','episode','rollup','belief')),
    tier          TEXT NOT NULL CHECK (tier IN ('short','long')),
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed','tombstone','shaken','retired')),  -- shaken/retired are belief-only (see 00018)
    redirect_to   TEXT,
    title         TEXT NOT NULL DEFAULT '',
    path          TEXT NOT NULL,                -- vault-relative file path
    content_hash  TEXT NOT NULL,                -- sha256 of file bytes at last index
    indexed_at    TEXT NOT NULL,
    subject       TEXT NOT NULL DEFAULT '',     -- belief subject entity id, '' for non-beliefs; file-derived (see 00019)
    confidence    REAL NOT NULL DEFAULT 0,      -- belief confidence 0..1, 0 for non-beliefs; file-derived (see 00019)
    importance_score REAL NOT NULL DEFAULT 0    -- merged override-or-computed importance snapshot, refreshed by Reconcile/Rebuild (see 00037, MEM-16)
);

-- Alias → node lookup (natural keys like slack IDs, 'situation:<id>', names).
CREATE TABLE IF NOT EXISTS memory_aliases (
    alias    TEXT PRIMARY KEY COLLATE NOCASE,
    node_id  TEXT NOT NULL REFERENCES memory_nodes(id)
);

-- Access accounting bumped by memory_open (not by memory_recall).
CREATE TABLE IF NOT EXISTS memory_node_stats (
    node_id          TEXT PRIMARY KEY REFERENCES memory_nodes(id),
    access_count     INTEGER NOT NULL DEFAULT 0,
    last_accessed_at TEXT
);

-- FTS5 index over node titles/bodies for memory_recall.
CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
    id UNINDEXED, title, body
);

-- Unresolved extractor entity hints, persisted for concept-entity promotion
-- once a hint recurs across enough distinct episodes (see 00018). Runtime
-- accumulation like memory_node_stats — excluded from the MEM-02 reindex-
-- equivalence comparison and NOT cleared by a reindex.
CREATE TABLE IF NOT EXISTS memory_entity_hints (
    hint        TEXT NOT NULL,          -- normalized (lowercased, trimmed) hint text
    episode_id  TEXT NOT NULL,          -- the ep_* node that emitted it (distinct-episode counting)
    first_seen  TEXT NOT NULL,
    promoted_to TEXT NOT NULL DEFAULT '', -- ent_* once a concept entity was created; '' until then
    PRIMARY KEY (hint, episode_id)
);

-- Phase-4 dispute flags (see 00019): a SIDE TABLE, not a memory_nodes
-- column — runtime state set by the belief pass / weekly reflection when a
-- belief's evidence looks contested. Write-only since migration 00070: the
-- inbox watchtower detector that read and cleared these flags (minting a
-- decision_made item for the Dashboard) went with the inbox demolition, so
-- the writers stay under MEM-06..08 and no surface reads them today (MEM-10).
-- Same memory_node_stats precedent: excluded from the MEM-02
-- reindex-equivalence comparison by construction (it lives outside
-- memory_nodes and Reconcile/Rebuild never touch it).
CREATE TABLE IF NOT EXISTS memory_dispute_flags (
    node_id     TEXT PRIMARY KEY REFERENCES memory_nodes(id),
    flagged_at  TEXT NOT NULL,
    reason      TEXT NOT NULL DEFAULT ''
);

-- Phase-5 slice-1 per-entity engagement aggregates (see 00042): the
-- retention-importance input Phase-3's RetentionInputs/RetentionScore
-- stubbed out. Its writer, the mechanical interaction-ingest step, was removed
-- with the inbox demolition (every one of its sources — inbox_feedback,
-- situation thumbs, situation verdicts — went with it), so existing rows stay
-- readable by retention scoring and no new ones are produced. A dedicated side
-- table — not memory_nodes columns, not memory_node_stats (which stays
-- write-dead). Runtime state derived from interaction rows: MEM-02-exempt like
-- memory_entity_hints (NOT like memory_node_stats) — it must survive
-- DropMemoryIndex/reindex because the rows that produced these aggregates may
-- be long gone.
CREATE TABLE IF NOT EXISTS memory_engagement (
    node_id             TEXT PRIMARY KEY REFERENCES memory_nodes(id),
    engaged_count       INTEGER NOT NULL DEFAULT 0,
    dismissed_count     INTEGER NOT NULL DEFAULT 0,
    last_interaction_at TEXT NOT NULL DEFAULT ''
);

-- Phase-5 slice-3 (see 00034): derived index of each episode/rollup node's
-- `## Provenance` refs, so a channel+window lookup does not require a full
-- vault body re-scan. Rebuildable from vault files — INSIDE the MEM-02
-- reindex-equivalence set (an extension, not a weakening; owner-review
-- flagged). scheme='' for bare Slack channel_id refs; mail:/cal:/chat:/act:
-- prefixed refs carry their scheme, naturally excluded from a Slack channel
-- window query.
CREATE TABLE IF NOT EXISTS memory_provenance (
    node_id     TEXT NOT NULL REFERENCES memory_nodes(id),
    scheme      TEXT NOT NULL DEFAULT '',
    channel_id  TEXT NOT NULL,
    ts_raw      TEXT NOT NULL,
    ts_unix     REAL NOT NULL,
    sender_id   TEXT NOT NULL DEFAULT '',    -- per-message sender (Slack user_id / Gmail from_email); '' for cal:/chat:/act: schemes (see 00038, Slice B)
    PRIMARY KEY (node_id, channel_id, ts_raw)
);
CREATE INDEX IF NOT EXISTS idx_memory_provenance_window ON memory_provenance(channel_id, ts_unix);
CREATE INDEX IF NOT EXISTS idx_memory_provenance_sender ON memory_provenance(sender_id);

-- Phase-5 slice-3 (see 00034): dark compare-mode telemetry
-- (memory.renders.digest_compare) — memory-owned, never the legacy
-- digests/digest_topics tables (MEM-05/MEM-14). Not a memory_nodes child;
-- not vault-derived, so DropMemoryIndex leaves it alone. Never read by any
-- UI; a pure reader of digests/digest_topics/messages writes here.
CREATE TABLE IF NOT EXISTS memory_digest_shadow (
    id                   INTEGER PRIMARY KEY,
    channel_id           TEXT NOT NULL,  -- namespaced "<slack_account_id>:<raw channel ID>" (see 00048)
    period_from          REAL NOT NULL,
    period_to            REAL NOT NULL,
    legacy_digest_id     INTEGER NOT NULL DEFAULT 0,
    rendered_json        TEXT NOT NULL,
    coverage             REAL NOT NULL DEFAULT 0,
    render_refs_rejected INTEGER NOT NULL DEFAULT 0,
    model                TEXT NOT NULL DEFAULT '',
    created_at           TEXT NOT NULL,
    UNIQUE(channel_id, period_from, period_to)
);

-- Wave-4 cost fix (see 00069): the "done today" memo for the three staggered
-- memory steps. dueForRewrite/dueForReflect are day-granular and STATELESS, so
-- on their slot day they answered "due" on every daemon cycle; the strong map
-- render had no change gate on its AI call at all. One row per (step, node_id):
-- node_id is the entity id for the per-node 'rewrite' step and '' for the
-- workspace-wide 'reflect'/'map' steps. last_run_at is the last ATTEMPT (not
-- success — a dispute-only reflect run writes no vault commit, so the git log
-- cannot serve as its memo); fingerprint is the sha256 of the rendered map
-- prompt input. No FK onto memory_nodes (DropMemoryIndex toggles FKs off around
-- its delete; a stale row is harmless and self-overwrites on the next stamp).
-- Runtime cadence state, NOT vault-derived: deliberately excluded from
-- DropMemoryIndex like memory_engagement/memory_entity_hints — a reindex that
-- erased it would re-trigger the strong-tier cost spike it removes (MEM-02).
CREATE TABLE IF NOT EXISTS memory_step_state (
    step        TEXT NOT NULL,            -- 'rewrite' | 'reflect' | 'map'
    node_id     TEXT NOT NULL DEFAULT '', -- entity id for 'rewrite'; '' for the workspace-wide steps
    last_run_at TEXT NOT NULL DEFAULT '', -- RFC3339 UTC of the last attempt
    fingerprint TEXT NOT NULL DEFAULT '', -- sha256 of the map prompt input; '' for the other steps
    PRIMARY KEY (step, node_id)
);

-- Extraction attempt budget (see 00093, MEM-04): one row per failing Slack
-- extraction window, keyed by channel + first message's raw Slack ts. After
-- the budget the window is quarantined (quarantined_at set) and its messages,
-- channel_id with raw ts from first_ts to last_ts, are skipped so the
-- watermark can pass them; the row stays as the record of what memory never
-- read.
-- Runtime state, excluded from DropMemoryIndex (MEM-02).
CREATE TABLE IF NOT EXISTS memory_extract_failures (
    channel_id     TEXT NOT NULL,
    first_ts       TEXT NOT NULL,            -- first message's Slack ts (e.g. "1700000000.000100")
    last_ts        TEXT NOT NULL,            -- last message's Slack ts at the latest failure
    last_ts_unix   REAL NOT NULL,            -- last_ts's ts_unix, for pruning against the watermark
    failures       INTEGER NOT NULL DEFAULT 0, -- consecutive failures; extracted alone after 3
    solo_failures  INTEGER NOT NULL DEFAULT 0, -- proven failures while alone; quarantined after 3
    last_error     TEXT NOT NULL DEFAULT '',
    quarantined_at TEXT NOT NULL DEFAULT '', -- RFC3339 UTC; '' while still retried
    updated_at     TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (channel_id, first_ts)
);

-- Slice B Task 7 (see 00039): dark retrieval-compare telemetry
-- (memory.retrieve.{recall_compare,briefing_compare,meeting_prep_compare}) —
-- append-only, no FK onto memory_nodes (a shadow row is pure telemetry that
-- must survive independently of the compared node's later eviction).
CREATE TABLE IF NOT EXISTS memory_retrieve_shadow (
    id                INTEGER PRIMARY KEY,
    surface           TEXT NOT NULL CHECK (surface IN ('recall','briefing','meeting_prep')),
    query_key         TEXT NOT NULL DEFAULT '',
    old_result_json   TEXT NOT NULL,
    new_result_json   TEXT NOT NULL,
    diff_metrics_json TEXT NOT NULL,
    ts                TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_memory_retrieve_shadow_surface ON memory_retrieve_shadow(surface, ts);

-- Focus salience (see 00041): mechanically-matched node set (state 'now' or
-- 'cooled'), rewritten wholesale on every fingerprint change. Runtime state:
-- rebuilt from focus.md + the index, cleared and rewritten by the pipeline.
-- No FK (a match may outlive its node briefly between runs; reads join
-- against live nodes).
CREATE TABLE IF NOT EXISTS memory_focus_matches (
    node_id TEXT PRIMARY KEY,
    state   TEXT NOT NULL CHECK (state IN ('now','cooled'))
);

-- Ideas & Decisions Registry (see 00050): durable, dedupable record of
-- ideas/decisions/notes mined from Slack digests, meeting transcripts,
-- Gmail and Jira, plus owner-authored ones from chat. Distinct from targets
-- (actionable goal tracking) — an idea only becomes a target when the
-- owner converts it (targets.source_type='idea').

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
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    seen_at         TEXT
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
CREATE INDEX IF NOT EXISTS idx_idea_mentions_ref ON idea_mentions(source, ref);

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
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    read_at      TEXT
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
CREATE INDEX IF NOT EXISTS idx_jira_comments_issue_author ON jira_comments(issue_key, author_account_id);
CREATE INDEX IF NOT EXISTS idx_jira_comments_synced ON jira_comments(synced_at);

-- Jira status/assignee history (00095). For field 'status' *_value is the
-- status id and *_string its name; for 'assignee' *_value is the Atlassian
-- account id and *_string the display name. Timestamps are UTC.
CREATE TABLE IF NOT EXISTS jira_issue_changelog (
    account_id          INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    issue_key           TEXT NOT NULL,
    history_id          TEXT NOT NULL,
    field               TEXT NOT NULL,
    from_value          TEXT NOT NULL DEFAULT '',
    from_string         TEXT NOT NULL DEFAULT '',
    to_value            TEXT NOT NULL DEFAULT '',
    to_string           TEXT NOT NULL DEFAULT '',
    author_account_id   TEXT NOT NULL DEFAULT '',
    author_display_name TEXT NOT NULL DEFAULT '',
    changed_at          TEXT NOT NULL,
    PRIMARY KEY (account_id, issue_key, history_id, field)
);
CREATE INDEX IF NOT EXISTS idx_jira_issue_changelog_issue ON jira_issue_changelog(account_id, issue_key, changed_at);

-- Per-issue changelog cursor: the issue updated_at the stored history belongs to.
CREATE TABLE IF NOT EXISTS jira_changelog_sync (
    account_id       INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    issue_key        TEXT NOT NULL,
    issue_updated_at TEXT NOT NULL,
    synced_at        TEXT NOT NULL,
    PRIMARY KEY (account_id, issue_key)
);

-- Issues linked from synced issues that live on other boards (not in
-- jira_issues); fetch_error is set when the site would not return the key.
CREATE TABLE IF NOT EXISTS jira_linked_issues (
    account_id            INTEGER NOT NULL REFERENCES jira_accounts(id) ON DELETE CASCADE,
    key                   TEXT NOT NULL,
    id                    TEXT NOT NULL DEFAULT '',
    project_key           TEXT NOT NULL DEFAULT '',
    summary               TEXT NOT NULL DEFAULT '',
    issue_type            TEXT NOT NULL DEFAULT '',
    status                TEXT NOT NULL DEFAULT '',
    status_category       TEXT NOT NULL DEFAULT '',
    assignee_account_id   TEXT NOT NULL DEFAULT '',
    assignee_display_name TEXT NOT NULL DEFAULT '',
    created_at            TEXT NOT NULL DEFAULT '',
    updated_at            TEXT NOT NULL DEFAULT '',
    resolved_at           TEXT NOT NULL DEFAULT '',
    fetch_error           TEXT NOT NULL DEFAULT '',
    synced_at             TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, key)
);

CREATE TABLE IF NOT EXISTS agent_actions (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    tool            TEXT    NOT NULL,
    external        INTEGER NOT NULL DEFAULT 0,
    args_json       TEXT    NOT NULL,
    reason          TEXT    NOT NULL DEFAULT '',
    surface         TEXT    NOT NULL DEFAULT '',
    conversation_id INTEGER NOT NULL DEFAULT 0,
    context_type    TEXT    NOT NULL DEFAULT '',
    context_id      TEXT    NOT NULL DEFAULT '',
    turn_id         TEXT    NOT NULL DEFAULT '',
    -- `executing` is the claim Apply takes before it runs the tool, so two
    -- overlapping applies can never both perform the write (AGENT-05).
    status          TEXT    NOT NULL DEFAULT 'pending'
                    CHECK(status IN ('pending','approved','rejected','applied','failed','executing')),
    trust_at_create TEXT    NOT NULL DEFAULT 'ask' CHECK(trust_at_create IN ('ask','execute')),
    result_json     TEXT    NOT NULL DEFAULT '',
    error           TEXT    NOT NULL DEFAULT '',
    created_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    decided_at      TEXT    NOT NULL DEFAULT '',
    applied_at      TEXT    NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_agent_actions_conversation ON agent_actions(conversation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_agent_actions_status ON agent_actions(status);

CREATE TABLE IF NOT EXISTS tool_trust (
    tool       TEXT PRIMARY KEY,
    trust      TEXT NOT NULL CHECK(trust IN ('ask','execute')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- Reaction commands (migration 00063): the owner drives Watchtower by reacting
-- in Slack. See docs/superpowers/specs/2026-09-05-reaction-commands-design.md.
CREATE TABLE IF NOT EXISTS reaction_command_map (
    emoji      TEXT PRIMARY KEY,
    kind       TEXT    NOT NULL DEFAULT 'builtin_tool'
               CHECK(kind IN ('builtin_tool','agent')),
    tool       TEXT    NOT NULL DEFAULT '',
    handler_id INTEGER NOT NULL DEFAULT 0,
    enabled    INTEGER NOT NULL DEFAULT 1,
    created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE TABLE IF NOT EXISTS reaction_commands (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id INTEGER NOT NULL,
    channel_id TEXT    NOT NULL,
    message_ts TEXT    NOT NULL,
    emoji      TEXT    NOT NULL,
    status     TEXT    NOT NULL DEFAULT 'pending'
               CHECK(status IN ('pending','dispatched','skipped','failed')),
    action_id  INTEGER NOT NULL DEFAULT 0,
    error      TEXT    NOT NULL DEFAULT '',
    created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    UNIQUE(account_id, channel_id, message_ts, emoji)
);
CREATE INDEX IF NOT EXISTS idx_reaction_commands_status ON reaction_commands(status);

-- Owner-managed external MCP servers ("Quick Connections"). Read-only tools
-- surfaced in the chat on demand; nothing is synced. Secrets live in 0600
-- files (mcp_secret_<id>.json), never in this table.
CREATE TABLE IF NOT EXISTS external_connections (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL UNIQUE,
    kind       TEXT    NOT NULL DEFAULT 'stdio'
               CHECK(kind IN ('stdio','http')),
    command    TEXT    NOT NULL DEFAULT '',
    args_json  TEXT    NOT NULL DEFAULT '[]',
    url        TEXT    NOT NULL DEFAULT '',
    enabled    INTEGER NOT NULL DEFAULT 0,
    status     TEXT    NOT NULL DEFAULT 'ok',
    error      TEXT    NOT NULL DEFAULT '',
    created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- QC-02 per-tool allowlist (migration 00094): a Quick Connection's cached
-- tools/list ('' = never listed: no tool allowed) and the owner's explicit
-- allow list of tool names (NULL = only tools known to be read-only).
CREATE TABLE IF NOT EXISTS external_connection_tools (
    connection_id INTEGER PRIMARY KEY REFERENCES external_connections(id) ON DELETE CASCADE,
    tools_json    TEXT NOT NULL DEFAULT '',
    listed_at     TEXT NOT NULL DEFAULT '',
    allow_json    TEXT,
    list_failed_at TEXT NOT NULL DEFAULT ''
);

-- Reminders (migration 00065): the owner's ":later:" reaction parks a message
-- to resurface in the inbox action strip at remind_at.
CREATE TABLE IF NOT EXISTS reminders (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id  INTEGER NOT NULL DEFAULT 0,
    message_ref TEXT    NOT NULL DEFAULT '',
    note        TEXT    NOT NULL DEFAULT '',
    remind_at   TEXT    NOT NULL,
    status      TEXT    NOT NULL DEFAULT 'pending'
                CHECK(status IN ('pending','done','dismissed')),
    created_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    done_at     TEXT    NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_reminders_due ON reminders(status, remind_at);

-- Knowledge search (see 00072)
CREATE TABLE IF NOT EXISTS kb_documents (
    id            TEXT PRIMARY KEY,
    source        TEXT NOT NULL,
    title         TEXT NOT NULL DEFAULT '',
    doc_time      TEXT NOT NULL DEFAULT '',
    doc_time_unix REAL NOT NULL DEFAULT 0,
    link          TEXT NOT NULL DEFAULT '',
    anchor_json   TEXT NOT NULL DEFAULT '{}',
    meta          TEXT NOT NULL DEFAULT '',
    content_hash  TEXT NOT NULL DEFAULT '',
    chunk_count   INTEGER NOT NULL DEFAULT 0,
    indexed_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_kb_documents_source_time ON kb_documents(source, doc_time_unix);

CREATE TABLE IF NOT EXISTS kb_chunks (
    id      INTEGER PRIMARY KEY,
    doc_id  TEXT NOT NULL REFERENCES kb_documents(id) ON DELETE CASCADE,
    idx     INTEGER NOT NULL,
    title   TEXT NOT NULL DEFAULT '',
    body    TEXT NOT NULL,
    meta    TEXT NOT NULL DEFAULT '',
    anchor  TEXT NOT NULL DEFAULT '',
    UNIQUE(doc_id, idx)
);

CREATE VIRTUAL TABLE IF NOT EXISTS kb_fts USING fts5(
    title, body, meta,
    content='kb_chunks', content_rowid='id',
    tokenize='porter unicode61 remove_diacritics 2'
);

CREATE TRIGGER IF NOT EXISTS kb_chunks_ai AFTER INSERT ON kb_chunks BEGIN
    INSERT INTO kb_fts(rowid, title, body, meta) VALUES (NEW.id, NEW.title, NEW.body, NEW.meta);
END;
CREATE TRIGGER IF NOT EXISTS kb_chunks_ad AFTER DELETE ON kb_chunks BEGIN
    INSERT INTO kb_fts(kb_fts, rowid, title, body, meta) VALUES ('delete', OLD.id, OLD.title, OLD.body, OLD.meta);
END;
CREATE TRIGGER IF NOT EXISTS kb_chunks_au AFTER UPDATE ON kb_chunks BEGIN
    INSERT INTO kb_fts(kb_fts, rowid, title, body, meta) VALUES ('delete', OLD.id, OLD.title, OLD.body, OLD.meta);
    INSERT INTO kb_fts(rowid, title, body, meta) VALUES (NEW.id, NEW.title, NEW.body, NEW.meta);
END;

CREATE TABLE IF NOT EXISTS kb_sources (
    source             TEXT PRIMARY KEY,
    cursor             TEXT NOT NULL DEFAULT '',
    last_reconciled_at TEXT NOT NULL DEFAULT '',
    updated_at         TEXT NOT NULL DEFAULT ''
);

-- External knowledge sources (see 00074)
CREATE TABLE IF NOT EXISTS ext_sources (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  provider         TEXT NOT NULL CHECK (provider IN ('confluence')),
  jira_account_id  INTEGER REFERENCES jira_accounts(id) ON DELETE CASCADE,
  connection_id    INTEGER REFERENCES external_connections(id) ON DELETE CASCADE,
  container_key    TEXT NOT NULL,          -- space key
  container_ext_id TEXT NOT NULL DEFAULT '',-- space id (REST v2)
  container_name   TEXT NOT NULL DEFAULT '',
  enabled          INTEGER NOT NULL DEFAULT 1,
  page_cursor       TEXT NOT NULL DEFAULT '',  -- RFC3339 lastModified high-water
  comment_cursor    TEXT NOT NULL DEFAULT '',
  attachment_cursor TEXT NOT NULL DEFAULT '',
  page_token        TEXT NOT NULL DEFAULT '',  -- in-flight pagination token per stream
  comment_token     TEXT NOT NULL DEFAULT '',  --   (resume mid-backfill; cleared when
  attachment_token  TEXT NOT NULL DEFAULT '',  --    the stream's enumeration completes)
  backfill_done    INTEGER NOT NULL DEFAULT 0,
  last_reconcile_at TEXT NOT NULL DEFAULT '',
  last_synced_at   TEXT NOT NULL DEFAULT '',
  status           TEXT NOT NULL DEFAULT 'ok' CHECK (status IN ('ok','error','needs_consent','revoked')),
  error            TEXT NOT NULL DEFAULT '',
  created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  CHECK ((jira_account_id IS NULL) != (connection_id IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_ext_sources_jira ON ext_sources(provider, jira_account_id, container_key)
  WHERE jira_account_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_ext_sources_conn ON ext_sources(provider, connection_id, container_key)
  WHERE connection_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS ext_documents (
  source_id     INTEGER NOT NULL REFERENCES ext_sources(id) ON DELETE CASCADE,
  ext_id        TEXT NOT NULL,
  kind          TEXT NOT NULL CHECK (kind IN ('page','blogpost','attachment')),
  parent_ext_id TEXT NOT NULL DEFAULT '',
  title         TEXT NOT NULL DEFAULT '',
  url           TEXT NOT NULL DEFAULT '',
  version       INTEGER NOT NULL DEFAULT 0,
  status        TEXT NOT NULL DEFAULT 'current',
  author_id     TEXT NOT NULL DEFAULT '',
  created_at    TEXT NOT NULL DEFAULT '',
  modified_at   TEXT NOT NULL DEFAULT '',
  sections_json TEXT NOT NULL DEFAULT '[]',   -- [{"heading":..,"anchor":..,"text":..}]
  meta_json     TEXT NOT NULL DEFAULT '{}',
  media_type    TEXT NOT NULL DEFAULT '',
  size_bytes    INTEGER NOT NULL DEFAULT 0,
  extract_status TEXT NOT NULL DEFAULT 'ok'
      CHECK (extract_status IN ('ok','skipped_type','too_large','ocr_pending','ocr_unavailable','failed')),
  extract_attempts INTEGER NOT NULL DEFAULT 0,
  children_changed_at TEXT NOT NULL DEFAULT '',  -- a comment moved: re-render the page
  synced_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (source_id, ext_id)
);
CREATE INDEX IF NOT EXISTS idx_ext_documents_synced ON ext_documents(synced_at);
CREATE INDEX IF NOT EXISTS idx_ext_documents_parent ON ext_documents(source_id, parent_ext_id);

CREATE TABLE IF NOT EXISTS ext_comments (
  source_id    INTEGER NOT NULL REFERENCES ext_sources(id) ON DELETE CASCADE,
  ext_id       TEXT NOT NULL,
  page_ext_id  TEXT NOT NULL,
  kind         TEXT NOT NULL CHECK (kind IN ('footer','inline')),
  author_id    TEXT NOT NULL DEFAULT '',
  created_at   TEXT NOT NULL DEFAULT '',
  version      INTEGER NOT NULL DEFAULT 0,
  body_text    TEXT NOT NULL DEFAULT '',
  anchor_text  TEXT NOT NULL DEFAULT '',
  resolved     INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source_id, ext_id)
);
CREATE INDEX IF NOT EXISTS idx_ext_comments_page ON ext_comments(source_id, page_ext_id);

CREATE TABLE IF NOT EXISTS ext_users (
  provider     TEXT NOT NULL,
  ext_user_id  TEXT NOT NULL,          -- Atlassian accountId for Confluence
  display_name TEXT NOT NULL DEFAULT '',
  email        TEXT NOT NULL DEFAULT '',
  fetched_at   TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (provider, ext_user_id)
);

CREATE TABLE IF NOT EXISTS doc_links (
  from_kind TEXT NOT NULL,   -- 'confluence' | 'slack' | 'gmail' | 'jira'
  from_ref  TEXT NOT NULL,   -- kb-style ref of the mentioning document
  to_kind   TEXT NOT NULL,   -- 'jira_issue' | 'confluence_page'
  to_ref    TEXT NOT NULL,   -- 'PROJ-123' | '<cloud_id>:<page_id>'
  detected_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (from_kind, from_ref, to_kind, to_ref)
);
CREATE INDEX IF NOT EXISTS idx_doc_links_to ON doc_links(to_kind, to_ref);

CREATE TABLE IF NOT EXISTS ext_link_state (          -- doc_links detection watermark per scanned kind
  from_kind TEXT PRIMARY KEY,          -- 'slack' | 'gmail' | 'imap' | 'jira_issue' | 'jira_comment' | 'ext_relink'
  cursor    TEXT NOT NULL DEFAULT ''   -- slack: messages.rowid; gmail/imap/jira_*: '<synced_at>|<rowid>' of the last row read; ext_relink: '<source_id>|<ext_id>' resume point, then 'done'
);

-- Chat (see 00076). Adopted from the Desktop app; conversations form a tree via
-- chat_messages.parent_id, the visible thread is root → active_leaf_message_id
-- (NULL = linear). chat_fts / chat_title_fts are external-content FTS5 indexes
-- kept by triggers.
CREATE TABLE IF NOT EXISTS chat_projects (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL,
    instructions TEXT NOT NULL DEFAULT '',
    created_at   REAL NOT NULL,
    updated_at   REAL NOT NULL,
    archived_at  REAL
);

CREATE TABLE IF NOT EXISTS chat_conversations (
    id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    title                  TEXT NOT NULL DEFAULT '',
    session_id             TEXT,
    context_type           TEXT,
    context_id             TEXT,
    created_at             REAL NOT NULL,
    updated_at             REAL NOT NULL,
    pinned                 INTEGER NOT NULL DEFAULT 0,
    archived_at            REAL,
    title_source           TEXT NOT NULL DEFAULT 'prefix' CHECK(title_source IN ('prefix','ai','user')),
    provider               TEXT,
    model                  TEXT,
    project_id             INTEGER REFERENCES chat_projects(id) ON DELETE SET NULL,
    active_leaf_message_id INTEGER
);
CREATE INDEX IF NOT EXISTS idx_chat_conversations_project ON chat_conversations(project_id);

CREATE TABLE IF NOT EXISTS chat_messages (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    role            TEXT NOT NULL,
    text            TEXT NOT NULL,
    created_at      REAL NOT NULL,
    turn_id         TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'complete' CHECK(status IN ('complete','partial','error')),
    provider        TEXT,
    model           TEXT,
    tokens_in       INTEGER,
    tokens_out      INTEGER,
    parent_id       INTEGER REFERENCES chat_messages(id) ON DELETE CASCADE,
    error_code      TEXT,
    error_message   TEXT
);
CREATE INDEX IF NOT EXISTS idx_chat_messages_conversation ON chat_messages(conversation_id);
CREATE INDEX IF NOT EXISTS idx_chat_messages_parent ON chat_messages(parent_id);

CREATE TABLE IF NOT EXISTS chat_turn_steps (
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

CREATE TABLE IF NOT EXISTS chat_attachments (
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

CREATE TABLE IF NOT EXISTS chat_artifacts (
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

-- Owner comments on an artifact's passages; Desktop-written, never read by
-- the assistant (it sees them only in the owner's own chat message).
CREATE TABLE IF NOT EXISTS chat_artifact_comments (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id  INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    artifact_key     TEXT NOT NULL,
    artifact_version INTEGER NOT NULL,
    body             TEXT NOT NULL,
    anchor_quote     TEXT NOT NULL,
    anchor_prefix    TEXT NOT NULL DEFAULT '',
    anchor_suffix    TEXT NOT NULL DEFAULT '',
    anchor_heading   TEXT NOT NULL DEFAULT '',
    status           TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','sent','resolved','outdated')),
    created_at       REAL NOT NULL,
    sent_at          REAL,
    CHECK (anchor_quote != '' AND body != ''),
    CHECK (status != 'sent' OR sent_at IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_chat_artifact_comments_key ON chat_artifact_comments(conversation_id, artifact_key);

CREATE TABLE IF NOT EXISTS chat_project_sources (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES chat_projects(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL CHECK(kind IN ('jira_project','slack_channel','target','track','person')),
    ref        TEXT NOT NULL,
    label      TEXT NOT NULL DEFAULT '',
    UNIQUE(project_id, kind, ref)
);

CREATE VIRTUAL TABLE IF NOT EXISTS chat_fts USING fts5(
    text, content='chat_messages', content_rowid='id',
    tokenize='porter unicode61 remove_diacritics 2'
);
CREATE VIRTUAL TABLE IF NOT EXISTS chat_title_fts USING fts5(
    title, content='chat_conversations', content_rowid='id',
    tokenize='porter unicode61 remove_diacritics 2'
);
CREATE TRIGGER IF NOT EXISTS chat_messages_fts_ai AFTER INSERT ON chat_messages BEGIN
    INSERT INTO chat_fts(rowid, text) VALUES (NEW.id, NEW.text);
END;
CREATE TRIGGER IF NOT EXISTS chat_messages_fts_ad AFTER DELETE ON chat_messages BEGIN
    INSERT INTO chat_fts(chat_fts, rowid, text) VALUES ('delete', OLD.id, OLD.text);
END;
CREATE TRIGGER IF NOT EXISTS chat_messages_fts_au AFTER UPDATE OF text ON chat_messages BEGIN
    INSERT INTO chat_fts(chat_fts, rowid, text) VALUES ('delete', OLD.id, OLD.text);
    INSERT INTO chat_fts(rowid, text) VALUES (NEW.id, NEW.text);
END;
CREATE TRIGGER IF NOT EXISTS chat_conversations_fts_ai AFTER INSERT ON chat_conversations BEGIN
    INSERT INTO chat_title_fts(rowid, title) VALUES (NEW.id, NEW.title);
END;
CREATE TRIGGER IF NOT EXISTS chat_conversations_fts_ad AFTER DELETE ON chat_conversations BEGIN
    INSERT INTO chat_title_fts(chat_title_fts, rowid, title) VALUES ('delete', OLD.id, OLD.title);
END;
CREATE TRIGGER IF NOT EXISTS chat_conversations_fts_au AFTER UPDATE OF title ON chat_conversations BEGIN
    INSERT INTO chat_title_fts(chat_title_fts, rowid, title) VALUES ('delete', OLD.id, OLD.title);
    INSERT INTO chat_title_fts(rowid, title) VALUES (NEW.id, NEW.title);
END;

-- Projects (00081, spec 2026-09-29-project-board-poc-design.md): a folder-bound
-- project worked on by Claude Code through `watchtower mcp --project N`. Its
-- targets carry targets.project_id and appear only on its board. Documents are
-- files inside folder_path (rel_path); comments hang off a target, a document
-- or a thread root (parent_id; replies are flat, parent_id = the root).
-- author 'agent' comments are unread for the owner while read_at = ''.
CREATE TABLE IF NOT EXISTS projects (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL,
    folder_path TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    board_language TEXT NOT NULL DEFAULT '' -- unused: the board always follows the session language (00087, retired by board item #153)
);

CREATE TABLE IF NOT EXISTS project_sources (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL CHECK(kind IN ('slack_channel','jira_project','confluence_space','person','link')),
    ref        TEXT NOT NULL,
    label      TEXT NOT NULL DEFAULT '',
    UNIQUE(project_id, kind, ref)
);

CREATE TABLE IF NOT EXISTS project_documents (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    target_id  INTEGER REFERENCES targets(id) ON DELETE SET NULL,
    rel_path   TEXT NOT NULL,
    kind       TEXT NOT NULL DEFAULT 'doc' CHECK(kind IN ('spec','plan','doc')),
    title      TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    origin     TEXT NOT NULL DEFAULT 'agent' CHECK(origin IN ('agent','import','owner')),  -- import = found by the setup scan
    UNIQUE(project_id, rel_path)
);
CREATE INDEX IF NOT EXISTS idx_project_documents_target ON project_documents(target_id);

-- Images attached to project targets (00088); path = absolute 0600 copy under
-- <workspace>/project_files/<project_id>/. Board-only (PROJ-01).
CREATE TABLE IF NOT EXISTS project_target_images (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    target_id  INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    file_name  TEXT NOT NULL,
    mime       TEXT NOT NULL CHECK(mime IN ('image/png','image/jpeg','image/gif','image/webp')),
    size       INTEGER NOT NULL,
    sha256     TEXT NOT NULL,
    path       TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    UNIQUE(target_id, sha256)
);
CREATE INDEX IF NOT EXISTS idx_project_target_images_project ON project_target_images(project_id);

CREATE TABLE IF NOT EXISTS project_comments (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id     INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    target_id      INTEGER REFERENCES targets(id) ON DELETE CASCADE,
    document_id    INTEGER REFERENCES project_documents(id) ON DELETE CASCADE,
    parent_id      INTEGER REFERENCES project_comments(id) ON DELETE CASCADE,
    author         TEXT NOT NULL CHECK(author IN ('owner','agent')),
    agent_label    TEXT NOT NULL DEFAULT '',
    body           TEXT NOT NULL,
    anchor_quote   TEXT NOT NULL DEFAULT '',
    anchor_prefix  TEXT NOT NULL DEFAULT '',
    anchor_suffix  TEXT NOT NULL DEFAULT '',
    anchor_heading TEXT NOT NULL DEFAULT '',
    status         TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved','outdated')),
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    read_at        TEXT NOT NULL DEFAULT '',
    CHECK (target_id IS NOT NULL OR document_id IS NOT NULL OR parent_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_project_comments_project  ON project_comments(project_id, created_at);
CREATE INDEX IF NOT EXISTS idx_project_comments_target   ON project_comments(target_id);
CREATE INDEX IF NOT EXISTS idx_project_comments_document ON project_comments(document_id);
CREATE INDEX IF NOT EXISTS idx_project_comments_parent   ON project_comments(parent_id);

-- Embedded terminal sessions; project_id NULL = a standalone terminal.
CREATE TABLE IF NOT EXISTS terminal_sessions (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id        INTEGER REFERENCES projects(id) ON DELETE CASCADE,
    kind              TEXT NOT NULL CHECK(kind IN ('claude','shell')),
    title             TEXT NOT NULL,
    title_source      TEXT NOT NULL DEFAULT 'auto' CHECK(title_source IN ('auto','ai','user')),
    target_id         INTEGER REFERENCES targets(id) ON DELETE SET NULL,
    folder_path       TEXT NOT NULL,
    claude_session_id TEXT,
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    last_active_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    closed_at         TEXT, -- legacy, unused since 2026-10-01 (no Close action): not a "session open" flag
    CHECK (title != '' AND folder_path != ''),
    CHECK (kind = 'shell' OR claude_session_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_terminal_sessions_project ON terminal_sessions(project_id, last_active_at);
CREATE INDEX IF NOT EXISTS idx_terminal_sessions_target ON terminal_sessions(target_id);
