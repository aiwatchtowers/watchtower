import Foundation
import GRDB

/// In-memory GRDB database with the full watchtower schema for testing.
package enum TestDatabase {
    package static func create() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue(path: ":memory:")
        try dbQueue.write { db in
            try db.execute(sql: schema)
            try db.execute(sql: "PRAGMA user_version = 5")
        }
        return dbQueue
    }

    /// Create a file-based DatabasePool for ViewModel/query tests (DatabasePool requires a file).
    /// `DatabaseManager` itself stays app-side (Sources/Database), so this returns the
    /// pool directly; app-side callers that need the `DatabaseManager` wrapper use
    /// `TestDatabase.createDatabaseManager()` (Tests/Helpers/TestDatabase+DatabaseManager.swift).
    package static func createPool() throws -> (DatabasePool, String) {
        let path = NSTemporaryDirectory() + "watchtower_test_\(UUID().uuidString).db"
        let pool = try DatabasePool(path: path)
        try pool.write { db in
            try db.execute(sql: schema)
            try db.execute(sql: "PRAGMA user_version = 5")
        }
        return (pool, path)
    }

    /// Clean up temp DB files
    package static func cleanup(path: String) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(atPath: path + suffix)
        }
    }

    // MARK: - Fixture Insertion

    package static func insertWorkspace(
        _ db: Database,
        id: String = "T001",
        name: String = "Test Workspace",
        domain: String = "test",
        syncedAt: String? = "2025-01-01T00:00:00Z"
    ) throws {
        try db.execute(sql: """
            INSERT INTO workspace (id, name, domain, synced_at)
            VALUES (?, ?, ?, ?)
            """, arguments: [id, name, domain, syncedAt])
    }

    // Slack multi-account note: post-migration (00048) the real `channels.id`/
    // `users.id`/`messages.channel_id`/`messages.user_id` carry a namespaced
    // `"<accountID>:<rawSlackID>"` value. These fixtures still use bare ids
    // (`C001`/`U001`) — that's fine because each test inserts both sides of a
    // join with the SAME bare id, so it stays internally consistent (the
    // migration never runs against the fresh test schema). Only add a `"1:"`
    // prefix here if a new test asserts a specific namespaced id string.
    package static func insertChannel(
        _ db: Database,
        id: String = "C001",
        name: String = "general",
        type: String = "public",
        topic: String = "",
        purpose: String = "",
        isArchived: Bool = false,
        isMember: Bool = true,
        dmUserID: String? = nil,
        numMembers: Int = 5
    ) throws {
        try db.execute(sql: """
            INSERT INTO channels (id, name, type, topic, purpose, is_archived, is_member, dm_user_id, num_members)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, name, type, topic, purpose, isArchived ? 1 : 0, isMember ? 1 : 0, dmUserID, numMembers])
    }

    package static func insertUser(
        _ db: Database,
        id: String = "U001",
        name: String = "testuser",
        displayName: String = "Test User",
        realName: String = "Test Real Name",
        email: String = "test@example.com",
        isBot: Bool = false,
        isDeleted: Bool = false
    ) throws {
        try db.execute(sql: """
            INSERT INTO users (id, name, display_name, real_name, email, is_bot, is_deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, name, displayName, realName, email, isBot ? 1 : 0, isDeleted ? 1 : 0])
    }

    package static func insertMessage(
        _ db: Database,
        channelID: String = "C001",
        ts: String = "1700000000.000100",
        userID: String = "U001",
        text: String = "Hello world",
        threadTS: String? = nil,
        replyCount: Int = 0,
        isEdited: Bool = false,
        isDeleted: Bool = false,
        subtype: String = "",
        permalink: String = ""
    ) throws {
        try db.execute(sql: """
            INSERT INTO messages (channel_id, ts, user_id, text, thread_ts, reply_count, is_edited, is_deleted, subtype, permalink, raw_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '{}')
            """, arguments: [channelID, ts, userID, text, threadTS, replyCount, isEdited ? 1 : 0, isDeleted ? 1 : 0, subtype, permalink])
    }

    package static func insertDigest(
        _ db: Database,
        channelID: String = "C001",
        periodFrom: Double = 1700000000,
        periodTo: Double = 1700086400,
        type: String = "channel",
        summary: String = "Test summary",
        topics: String = "[]",
        decisions: String = "[]",
        tracksJSON: String = "[]",
        messageCount: Int = 10,
        model: String = "haiku",
        createdAt: String? = nil
    ) throws {
        try db.execute(sql: """
            INSERT INTO digests (channel_id, period_from, period_to, type, summary, topics, decisions, action_items, message_count, model, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE(?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')))
            """, arguments: [channelID, periodFrom, periodTo, type, summary, topics, decisions, tracksJSON, messageCount, model, createdAt])
    }

    package static func insertWatchItem(
        _ db: Database,
        entityType: String = "channel",
        entityID: String = "C001",
        entityName: String = "general",
        priority: String = "normal"
    ) throws {
        try db.execute(sql: """
            INSERT INTO watch_list (entity_type, entity_id, entity_name, priority)
            VALUES (?, ?, ?, ?)
            """, arguments: [entityType, entityID, entityName, priority])
    }

    package static func insertSyncState(
        _ db: Database,
        channelID: String = "C001",
        lastSyncedTS: String = "1700000000.000100",
        oldestSyncedTS: String = "1699900000.000100",
        isInitialSyncComplete: Bool = true,
        messagesSynced: Int = 50
    ) throws {
        try db.execute(sql: """
            INSERT INTO sync_state (channel_id, last_synced_ts, oldest_synced_ts, is_initial_sync_complete, messages_synced)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [channelID, lastSyncedTS, oldestSyncedTS, isInitialSyncComplete ? 1 : 0, messagesSynced])
    }

    package static func insertUserAnalysis(
        _ db: Database,
        userID: String = "U001",
        periodFrom: Double = 1700000000,
        periodTo: Double = 1700604800,
        messageCount: Int = 100,
        channelsActive: Int = 5,
        threadsInitiated: Int = 10,
        threadsReplied: Int = 20,
        avgMessageLength: Double = 42.5,
        activeHoursJSON: String = #"{"9":12,"10":8,"14":15}"#,
        volumeChangePct: Double = 15.0,
        summary: String = "Active contributor",
        communicationStyle: String = "driver",
        decisionRole: String = "approver",
        redFlags: String = "[]",
        highlights: String = #"["Great leadership"]"#,
        styleDetails: String = "",
        recommendations: String = "[]",
        concerns: String = "[]",
        model: String = "haiku"
    ) throws {
        try db.execute(sql: """
            INSERT INTO user_analyses (user_id, period_from, period_to, message_count, channels_active,
                threads_initiated, threads_replied, avg_message_length, active_hours_json,
                volume_change_pct, summary, communication_style, decision_role, red_flags, highlights,
                style_details, recommendations, concerns, model)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [userID, periodFrom, periodTo, messageCount, channelsActive,
                             threadsInitiated, threadsReplied, avgMessageLength, activeHoursJSON,
                             volumeChangePct, summary, communicationStyle, decisionRole, redFlags, highlights,
                             styleDetails, recommendations, concerns, model])
    }

    @discardableResult
    package static func insertTrack(
        _ db: Database,
        text: String = "Fix the bug",
        context: String = "Discussed in standup",
        category: String = "task",
        ownership: String = "mine",
        priority: String = "medium",
        tags: String = "[]",
        channelIDs: String = "[\"C001\"]",
        sourceRefs: String = "[]",
        hasUpdates: Bool = false,
        participants: String = "[]",
        requesterName: String = "",
        blocking: String = "",
        decisionSummary: String = "",
        decisionOptions: String = "[]",
        subItems: String = "[]",
        relatedDigestIDs: String = "[]",
        model: String = "haiku",
        assigneeUserID: String = "",
        ownerUserID: String = "",
        requesterUserID: String = "",
        linkedTargetID: Int? = nil
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO tracks (text, context, category, ownership, priority, tags,
                channel_ids, source_refs, has_updates, participants, requester_name,
                blocking, decision_summary, decision_options, sub_items, related_digest_ids, model,
                assignee_user_id, owner_user_id, requester_user_id, linked_target_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [text, context, category, ownership, priority, tags,
                             channelIDs, sourceRefs, hasUpdates ? 1 : 0, participants,
                             requesterName, blocking, decisionSummary, decisionOptions,
                             subItems, relatedDigestIDs, model,
                             assigneeUserID, ownerUserID, requesterUserID, linkedTargetID])
        return db.lastInsertedRowID
    }

    // MARK: - Schema

    package static let schema = """
    CREATE TABLE IF NOT EXISTS workspace (
        id                TEXT PRIMARY KEY,
        name              TEXT NOT NULL,
        domain            TEXT NOT NULL DEFAULT '',
        synced_at         TEXT,
        -- current_user_id / search_last_date moved to slack_accounts
        -- (migration 00048). Mirror kept in sync with the real post-migration
        -- schema so tests can't accidentally read a dropped column.
        inbox_last_processed_ts REAL NOT NULL DEFAULT 0,
        secretary_profile TEXT NOT NULL DEFAULT '',
        style_profile TEXT NOT NULL DEFAULT '',
        style_profile_updated_at TEXT NOT NULL DEFAULT '',
        compose_last_run_ts REAL NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS users (
        id            TEXT PRIMARY KEY,
        name          TEXT NOT NULL,
        display_name  TEXT NOT NULL DEFAULT '',
        real_name     TEXT NOT NULL DEFAULT '',
        email         TEXT NOT NULL DEFAULT '',
        is_bot        INTEGER NOT NULL DEFAULT 0,
        is_deleted    INTEGER NOT NULL DEFAULT 0,
        is_bot_override INTEGER DEFAULT NULL,
        profile_json  TEXT NOT NULL DEFAULT '{}',
        updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS channels (
        id           TEXT PRIMARY KEY,
        name         TEXT NOT NULL,
        type         TEXT NOT NULL CHECK(type IN ('public', 'private', 'dm', 'group_dm')),
        topic        TEXT NOT NULL DEFAULT '',
        purpose      TEXT NOT NULL DEFAULT '',
        is_archived  INTEGER NOT NULL DEFAULT 0,
        is_member    INTEGER NOT NULL DEFAULT 0,
        dm_user_id   TEXT,
        num_members  INTEGER NOT NULL DEFAULT 0,
        updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS messages (
        channel_id   TEXT NOT NULL,
        ts           TEXT NOT NULL,
        user_id      TEXT NOT NULL DEFAULT '',
        text         TEXT NOT NULL DEFAULT '',
        thread_ts    TEXT,
        reply_count  INTEGER NOT NULL DEFAULT 0,
        is_edited    INTEGER NOT NULL DEFAULT 0,
        is_deleted   INTEGER NOT NULL DEFAULT 0,
        subtype      TEXT NOT NULL DEFAULT '',
        permalink    TEXT NOT NULL DEFAULT '',
        ts_unix      REAL GENERATED ALWAYS AS (
            CASE WHEN INSTR(ts, '.') > 0
            THEN CAST(SUBSTR(ts, 1, INSTR(ts, '.') - 1) AS REAL)
            ELSE CAST(ts AS REAL) END) STORED,
        raw_json     TEXT NOT NULL DEFAULT '{}',
        PRIMARY KEY (channel_id, ts)
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
        text,
        channel_id UNINDEXED,
        ts UNINDEXED,
        user_id UNINDEXED,
        tokenize='porter unicode61'
    );
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
    CREATE TABLE IF NOT EXISTS watch_list (
        entity_type TEXT NOT NULL CHECK(entity_type IN ('channel', 'user')),
        entity_id   TEXT NOT NULL,
        entity_name TEXT NOT NULL DEFAULT '',
        priority    TEXT NOT NULL DEFAULT 'normal' CHECK(priority IN ('high', 'normal', 'low')),
        created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        PRIMARY KEY (entity_type, entity_id)
    );
    CREATE TABLE IF NOT EXISTS digests (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        channel_id    TEXT NOT NULL DEFAULT '',
        period_from   REAL NOT NULL,
        period_to     REAL NOT NULL,
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
        read_at       TEXT,
        prompt_version INTEGER NOT NULL DEFAULT 0,
        people_signals TEXT NOT NULL DEFAULT '[]',
        situations     TEXT NOT NULL DEFAULT '[]',
        running_summary TEXT NOT NULL DEFAULT '',
        UNIQUE(channel_id, type, period_from, period_to)
    );
    CREATE TABLE IF NOT EXISTS digest_participants (
        digest_id      INTEGER NOT NULL REFERENCES digests(id) ON DELETE CASCADE,
        user_id        TEXT NOT NULL,
        situation_idx  INTEGER NOT NULL DEFAULT 0,
        role           TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (digest_id, user_id, situation_idx)
    );
    CREATE INDEX IF NOT EXISTS idx_digest_participants_user ON digest_participants(user_id);
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
        UNIQUE(digest_id, idx)
    );
    CREATE INDEX IF NOT EXISTS idx_digest_topics_digest ON digest_topics(digest_id);
    CREATE TABLE IF NOT EXISTS decision_reads (
        digest_id    INTEGER NOT NULL,
        decision_idx INTEGER NOT NULL,
        read_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        PRIMARY KEY (digest_id, decision_idx)
    );
    CREATE TABLE IF NOT EXISTS decision_importance_corrections (
        id                   INTEGER PRIMARY KEY AUTOINCREMENT,
        digest_id            INTEGER NOT NULL,
        decision_idx         INTEGER NOT NULL,
        topic_id             INTEGER NOT NULL DEFAULT 0,
        decision_text        TEXT NOT NULL DEFAULT '',
        original_importance  TEXT NOT NULL CHECK(original_importance IN ('high', 'medium', 'low')),
        new_importance       TEXT NOT NULL CHECK(new_importance IN ('high', 'medium', 'low')),
        created_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS user_analyses (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id             TEXT NOT NULL,
        period_from         REAL NOT NULL,
        period_to           REAL NOT NULL,
        message_count       INTEGER NOT NULL DEFAULT 0,
        channels_active     INTEGER NOT NULL DEFAULT 0,
        threads_initiated   INTEGER NOT NULL DEFAULT 0,
        threads_replied     INTEGER NOT NULL DEFAULT 0,
        avg_message_length  REAL NOT NULL DEFAULT 0,
        active_hours_json   TEXT NOT NULL DEFAULT '{}',
        volume_change_pct   REAL NOT NULL DEFAULT 0,
        summary             TEXT NOT NULL DEFAULT '',
        communication_style TEXT NOT NULL DEFAULT '',
        decision_role       TEXT NOT NULL DEFAULT '',
        red_flags           TEXT NOT NULL DEFAULT '[]',
        highlights          TEXT NOT NULL DEFAULT '[]',
        style_details       TEXT NOT NULL DEFAULT '',
        recommendations     TEXT NOT NULL DEFAULT '[]',
        concerns            TEXT NOT NULL DEFAULT '[]',
        accomplishments     TEXT NOT NULL DEFAULT '[]',
        model               TEXT NOT NULL DEFAULT '',
        input_tokens        INTEGER NOT NULL DEFAULT 0,
        output_tokens       INTEGER NOT NULL DEFAULT 0,
        cost_usd            REAL NOT NULL DEFAULT 0,
        prompt_version      INTEGER NOT NULL DEFAULT 0,
        created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE(user_id, period_from, period_to)
    );
    CREATE TABLE IF NOT EXISTS period_summaries (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        period_from   REAL NOT NULL,
        period_to     REAL NOT NULL,
        summary       TEXT NOT NULL DEFAULT '',
        attention     TEXT NOT NULL DEFAULT '[]',
        model         TEXT NOT NULL DEFAULT '',
        input_tokens  INTEGER NOT NULL DEFAULT 0,
        output_tokens INTEGER NOT NULL DEFAULT 0,
        cost_usd      REAL NOT NULL DEFAULT 0,
        created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE(period_from, period_to)
    );
    CREATE TABLE IF NOT EXISTS custom_emojis (
        name       TEXT PRIMARY KEY,
        url        TEXT NOT NULL,
        alias_for  TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS tracks (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        assignee_user_id    TEXT NOT NULL DEFAULT '',
        text                TEXT NOT NULL,
        context             TEXT NOT NULL DEFAULT '',
        category            TEXT NOT NULL DEFAULT 'task',
        ownership           TEXT NOT NULL DEFAULT 'mine' CHECK(ownership IN ('mine','delegated','watching')),
        ball_on             TEXT NOT NULL DEFAULT '',
        owner_user_id       TEXT NOT NULL DEFAULT '',
        requester_name      TEXT NOT NULL DEFAULT '',
        requester_user_id   TEXT NOT NULL DEFAULT '',
        blocking            TEXT NOT NULL DEFAULT '',
        decision_summary    TEXT NOT NULL DEFAULT '',
        decision_options    TEXT NOT NULL DEFAULT '[]',
        sub_items           TEXT NOT NULL DEFAULT '[]',
        participants        TEXT NOT NULL DEFAULT '[]',
        source_refs         TEXT NOT NULL DEFAULT '[]',
        tags                TEXT NOT NULL DEFAULT '[]',
        channel_ids         TEXT NOT NULL DEFAULT '[]',
        related_digest_ids  TEXT NOT NULL DEFAULT '[]',
        priority            TEXT NOT NULL DEFAULT 'medium',
        due_date            REAL,
        fingerprint         TEXT NOT NULL DEFAULT '[]',
        read_at             TEXT,
        has_updates         INTEGER NOT NULL DEFAULT 0,
        dismissed_at        TEXT NOT NULL DEFAULT '',
        model               TEXT NOT NULL DEFAULT '',
        input_tokens        INTEGER NOT NULL DEFAULT 0,
        output_tokens       INTEGER NOT NULL DEFAULT 0,
        cost_usd            REAL NOT NULL DEFAULT 0,
        prompt_version      INTEGER NOT NULL DEFAULT 0,
        created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        linked_target_id    INTEGER REFERENCES targets(id) ON DELETE SET NULL
    );
    CREATE TABLE IF NOT EXISTS track_states (
        id                 INTEGER PRIMARY KEY AUTOINCREMENT,
        track_id           INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
        text               TEXT NOT NULL,
        context            TEXT NOT NULL DEFAULT '',
        category           TEXT NOT NULL,
        ownership          TEXT NOT NULL,
        ball_on            TEXT NOT NULL DEFAULT '',
        owner_user_id      TEXT NOT NULL DEFAULT '',
        requester_name     TEXT NOT NULL DEFAULT '',
        requester_user_id  TEXT NOT NULL DEFAULT '',
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
        waiting_user_ids TEXT NOT NULL DEFAULT '',
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
    CREATE INDEX IF NOT EXISTS idx_inbox_status ON inbox_items(status);
    CREATE INDEX IF NOT EXISTS idx_inbox_priority ON inbox_items(priority);
    CREATE INDEX IF NOT EXISTS idx_inbox_updated ON inbox_items(updated_at DESC);
    CREATE INDEX IF NOT EXISTS idx_inbox_sender ON inbox_items(sender_user_id);
    CREATE INDEX IF NOT EXISTS idx_inbox_snooze ON inbox_items(snooze_until);
    CREATE INDEX IF NOT EXISTS idx_inbox_items_class_status ON inbox_items(item_class, status);
    CREATE INDEX IF NOT EXISTS idx_inbox_items_archived ON inbox_items(archived_at);

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

    CREATE TABLE IF NOT EXISTS inbox_feedback (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        inbox_item_id INTEGER NOT NULL,
        rating        INTEGER NOT NULL CHECK(rating IN (-1,1)),
        reason        TEXT DEFAULT '',
        created_at    TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_inbox_feedback_item ON inbox_feedback(inbox_item_id);

    CREATE TABLE IF NOT EXISTS slack_accounts (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        team_id           TEXT NOT NULL DEFAULT '',
        team_name         TEXT NOT NULL DEFAULT '',
        team_domain       TEXT NOT NULL DEFAULT '',
        label             TEXT NOT NULL DEFAULT '',
        current_user_id   TEXT NOT NULL DEFAULT '',
        status            TEXT NOT NULL DEFAULT 'ok',
        error             TEXT NOT NULL DEFAULT '',
        enabled           INTEGER NOT NULL DEFAULT 1,
        search_last_date  TEXT NOT NULL DEFAULT '',
        created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );

    CREATE TABLE IF NOT EXISTS jira_accounts (
        id                            INTEGER PRIMARY KEY AUTOINCREMENT,
        cloud_id                      TEXT NOT NULL DEFAULT '',
        site_url                      TEXT NOT NULL DEFAULT '',
        site_name                     TEXT NOT NULL DEFAULT '',
        label                         TEXT NOT NULL DEFAULT '',
        status                        TEXT NOT NULL DEFAULT 'ok',
        error                         TEXT NOT NULL DEFAULT '',
        enabled                       INTEGER NOT NULL DEFAULT 1,
        memory_jira_last_extracted_ts REAL NOT NULL DEFAULT 0,
        created_at                    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );

    CREATE TABLE IF NOT EXISTS google_accounts (
        id                             INTEGER PRIMARY KEY AUTOINCREMENT,
        email                          TEXT NOT NULL DEFAULT '',
        label                          TEXT NOT NULL DEFAULT '',
        client_id                      TEXT NOT NULL DEFAULT '',
        calendar_enabled               INTEGER NOT NULL DEFAULT 0,
        gmail_enabled                  INTEGER NOT NULL DEFAULT 0,
        status                         TEXT NOT NULL DEFAULT 'ok',
        error                          TEXT NOT NULL DEFAULT '',
        gmail_last_internal_date       REAL NOT NULL DEFAULT 0,
        memory_gmail_last_extracted_ts REAL NOT NULL DEFAULT 0,
        created_at                     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at                     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );

    CREATE TABLE IF NOT EXISTS calendar_calendars (
        id          TEXT PRIMARY KEY,
        name        TEXT NOT NULL,
        is_primary  INTEGER NOT NULL DEFAULT 0,
        is_selected INTEGER NOT NULL DEFAULT 1,
        color       TEXT NOT NULL DEFAULT '',
        synced_at   TEXT NOT NULL DEFAULT '',
        account_id  INTEGER REFERENCES google_accounts(id)
    );

    CREATE TABLE IF NOT EXISTS calendar_events (
        id              TEXT PRIMARY KEY,
        calendar_id     TEXT NOT NULL REFERENCES calendar_calendars(id),
        title           TEXT NOT NULL DEFAULT '',
        description     TEXT NOT NULL DEFAULT '',
        location        TEXT NOT NULL DEFAULT '',
        start_time      TEXT NOT NULL,
        end_time        TEXT NOT NULL,
        organizer_email TEXT NOT NULL DEFAULT '',
        attendees       TEXT NOT NULL DEFAULT '[]',
        is_recurring    INTEGER NOT NULL DEFAULT 0,
        is_all_day      INTEGER NOT NULL DEFAULT 0,
        event_status    TEXT NOT NULL DEFAULT 'confirmed',
        event_type      TEXT NOT NULL DEFAULT '',
        html_link       TEXT NOT NULL DEFAULT '',
        raw_json        TEXT NOT NULL DEFAULT '{}',
        synced_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at      TEXT NOT NULL DEFAULT '',
        ical_uid        TEXT NOT NULL DEFAULT '',
        conference_url  TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX IF NOT EXISTS idx_calendar_events_calendar ON calendar_events(calendar_id);
    CREATE INDEX IF NOT EXISTS idx_calendar_events_start ON calendar_events(start_time);
    CREATE INDEX IF NOT EXISTS idx_calendar_events_end ON calendar_events(end_time);

    CREATE TABLE IF NOT EXISTS calendar_attendee_map (
        email          TEXT PRIMARY KEY,
        slack_user_id  TEXT NOT NULL DEFAULT '',
        resolved_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );

    CREATE TABLE IF NOT EXISTS gmail_messages (
        account_id     INTEGER NOT NULL REFERENCES google_accounts(id) ON DELETE CASCADE,
        id             TEXT NOT NULL,
        thread_id      TEXT NOT NULL DEFAULT '',
        from_email     TEXT NOT NULL DEFAULT '',
        from_name      TEXT NOT NULL DEFAULT '',
        to_json        TEXT NOT NULL DEFAULT '[]',
        cc_json        TEXT NOT NULL DEFAULT '[]',
        subject        TEXT NOT NULL DEFAULT '',
        snippet        TEXT NOT NULL DEFAULT '',
        body_text      TEXT NOT NULL DEFAULT '',
        internal_date  TEXT NOT NULL DEFAULT '',
        labels_json    TEXT NOT NULL DEFAULT '[]',
        is_unread      INTEGER NOT NULL DEFAULT 0,
        permalink      TEXT NOT NULL DEFAULT '',
        synced_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        PRIMARY KEY (account_id, id)
    );
    CREATE INDEX IF NOT EXISTS idx_gmail_messages_thread ON gmail_messages(thread_id);
    CREATE INDEX IF NOT EXISTS idx_gmail_messages_synced ON gmail_messages(synced_at);

    CREATE TABLE IF NOT EXISTS feedback (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        entity_type TEXT NOT NULL CHECK(entity_type IN
            ('digest', 'track', 'decision', 'user_analysis', 'briefing', 'task', 'inbox', 'catchup_theme', 'situation')),
        entity_id   TEXT NOT NULL,
        rating      INTEGER NOT NULL CHECK(rating IN (-1, 1)),
        comment     TEXT NOT NULL DEFAULT '',
        created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE INDEX IF NOT EXISTS idx_feedback_entity ON feedback(entity_type, entity_id);
    CREATE INDEX IF NOT EXISTS idx_feedback_rating ON feedback(entity_type, rating);
    CREATE TABLE IF NOT EXISTS prompts (
        id         TEXT PRIMARY KEY,
        template   TEXT NOT NULL,
        version    INTEGER NOT NULL DEFAULT 1,
        language   TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS prompt_history (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        prompt_id  TEXT NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,
        version    INTEGER NOT NULL,
        template   TEXT NOT NULL,
        reason     TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE INDEX IF NOT EXISTS idx_prompt_history_prompt ON prompt_history(prompt_id);
    CREATE INDEX IF NOT EXISTS idx_prompt_history_version ON prompt_history(prompt_id, version);
    CREATE TABLE IF NOT EXISTS user_interactions (
        user_a              TEXT NOT NULL,
        user_b              TEXT NOT NULL,
        period_from         REAL NOT NULL,
        period_to           REAL NOT NULL,
        messages_to         INTEGER NOT NULL DEFAULT 0,
        messages_from       INTEGER NOT NULL DEFAULT 0,
        shared_channels     INTEGER NOT NULL DEFAULT 0,
        thread_replies_to   INTEGER NOT NULL DEFAULT 0,
        thread_replies_from INTEGER NOT NULL DEFAULT 0,
        shared_channel_ids  TEXT NOT NULL DEFAULT '[]',
        dm_messages_to      INTEGER NOT NULL DEFAULT 0,
        dm_messages_from    INTEGER NOT NULL DEFAULT 0,
        mentions_to         INTEGER NOT NULL DEFAULT 0,
        mentions_from       INTEGER NOT NULL DEFAULT 0,
        reactions_to        INTEGER NOT NULL DEFAULT 0,
        reactions_from      INTEGER NOT NULL DEFAULT 0,
        interaction_score   REAL NOT NULL DEFAULT 0,
        connection_type     TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (user_a, user_b, period_from, period_to)
    );
    CREATE INDEX IF NOT EXISTS idx_user_interactions_a ON user_interactions(user_a, period_from, period_to);

    CREATE TABLE IF NOT EXISTS communication_guides (
        id                        INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id                   TEXT NOT NULL,
        period_from               REAL NOT NULL,
        period_to                 REAL NOT NULL,
        message_count             INTEGER NOT NULL DEFAULT 0,
        channels_active           INTEGER NOT NULL DEFAULT 0,
        threads_initiated         INTEGER NOT NULL DEFAULT 0,
        threads_replied           INTEGER NOT NULL DEFAULT 0,
        avg_message_length        REAL NOT NULL DEFAULT 0,
        active_hours_json         TEXT NOT NULL DEFAULT '{}',
        volume_change_pct         REAL NOT NULL DEFAULT 0,
        summary                   TEXT NOT NULL DEFAULT '',
        communication_preferences TEXT NOT NULL DEFAULT '',
        availability_patterns     TEXT NOT NULL DEFAULT '',
        decision_process          TEXT NOT NULL DEFAULT '',
        situational_tactics       TEXT NOT NULL DEFAULT '[]',
        effective_approaches      TEXT NOT NULL DEFAULT '[]',
        recommendations           TEXT NOT NULL DEFAULT '[]',
        relationship_context      TEXT NOT NULL DEFAULT '',
        model                     TEXT NOT NULL DEFAULT '',
        input_tokens              INTEGER NOT NULL DEFAULT 0,
        output_tokens             INTEGER NOT NULL DEFAULT 0,
        cost_usd                  REAL NOT NULL DEFAULT 0,
        prompt_version            INTEGER NOT NULL DEFAULT 0,
        created_at                TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE(user_id, period_from, period_to)
    );
    CREATE INDEX IF NOT EXISTS idx_communication_guides_user   ON communication_guides(user_id);
    CREATE INDEX IF NOT EXISTS idx_communication_guides_period ON communication_guides(period_from, period_to);

    CREATE TABLE IF NOT EXISTS guide_summaries (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        period_from    REAL NOT NULL,
        period_to      REAL NOT NULL,
        summary        TEXT NOT NULL DEFAULT '',
        tips           TEXT NOT NULL DEFAULT '[]',
        model          TEXT NOT NULL DEFAULT '',
        input_tokens   INTEGER NOT NULL DEFAULT 0,
        output_tokens  INTEGER NOT NULL DEFAULT 0,
        cost_usd       REAL NOT NULL DEFAULT 0,
        prompt_version INTEGER NOT NULL DEFAULT 0,
        created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE(period_from, period_to)
    );

    CREATE TABLE IF NOT EXISTS people_cards (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id             TEXT NOT NULL,
        period_from         REAL NOT NULL,
        period_to           REAL NOT NULL,
        message_count       INTEGER NOT NULL DEFAULT 0,
        channels_active     INTEGER NOT NULL DEFAULT 0,
        threads_initiated   INTEGER NOT NULL DEFAULT 0,
        threads_replied     INTEGER NOT NULL DEFAULT 0,
        avg_message_length  REAL NOT NULL DEFAULT 0,
        active_hours_json   TEXT NOT NULL DEFAULT '{}',
        volume_change_pct   REAL NOT NULL DEFAULT 0,
        summary             TEXT NOT NULL DEFAULT '',
        communication_style TEXT NOT NULL DEFAULT '',
        decision_role       TEXT NOT NULL DEFAULT '',
        red_flags           TEXT NOT NULL DEFAULT '[]',
        highlights          TEXT NOT NULL DEFAULT '[]',
        accomplishments     TEXT NOT NULL DEFAULT '[]',
        communication_guide TEXT NOT NULL DEFAULT '',
        decision_style      TEXT NOT NULL DEFAULT '',
        tactics             TEXT NOT NULL DEFAULT '[]',
        relationship_context TEXT NOT NULL DEFAULT '',
        status              TEXT NOT NULL DEFAULT 'active',
        model               TEXT NOT NULL DEFAULT '',
        input_tokens        INTEGER NOT NULL DEFAULT 0,
        output_tokens       INTEGER NOT NULL DEFAULT 0,
        cost_usd            REAL NOT NULL DEFAULT 0,
        prompt_version      INTEGER NOT NULL DEFAULT 0,
        created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE(user_id, period_from, period_to)
    );
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

    CREATE TABLE IF NOT EXISTS briefings (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id     TEXT NOT NULL DEFAULT '',
        user_id          TEXT NOT NULL,
        date             TEXT NOT NULL,
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

    CREATE TABLE IF NOT EXISTS pipeline_runs (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        pipeline         TEXT NOT NULL,
        source           TEXT NOT NULL DEFAULT 'cli',
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
        duration_seconds REAL NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS pipeline_steps (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        run_id           INTEGER NOT NULL REFERENCES pipeline_runs(id) ON DELETE CASCADE,
        step             INTEGER NOT NULL,
        total            INTEGER NOT NULL,
        status           TEXT NOT NULL DEFAULT '',
        channel_id       TEXT NOT NULL DEFAULT '',
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
    CREATE TABLE IF NOT EXISTS channel_settings (
        channel_id         TEXT PRIMARY KEY,
        is_muted_for_llm   INTEGER NOT NULL DEFAULT 0,
        is_favorite        INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS user_profile (
        id                    INTEGER PRIMARY KEY,
        slack_user_id         TEXT NOT NULL UNIQUE,
        role                  TEXT NOT NULL DEFAULT '',
        team                  TEXT NOT NULL DEFAULT '',
        responsibilities      TEXT NOT NULL DEFAULT '[]',
        reports               TEXT NOT NULL DEFAULT '[]',
        peers                 TEXT NOT NULL DEFAULT '[]',
        manager               TEXT NOT NULL DEFAULT '',
        starred_channels      TEXT NOT NULL DEFAULT '[]',
        starred_people        TEXT NOT NULL DEFAULT '[]',
        pain_points           TEXT NOT NULL DEFAULT '[]',
        track_focus           TEXT NOT NULL DEFAULT '[]',
        onboarding_done       INTEGER NOT NULL DEFAULT 0,
        custom_prompt_context TEXT NOT NULL DEFAULT '',
        created_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS day_plans (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id             TEXT NOT NULL,
        plan_date           TEXT NOT NULL,
        status              TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
        has_conflicts       INTEGER NOT NULL DEFAULT 0,
        conflict_summary    TEXT,
        generated_at        TEXT NOT NULL,
        last_regenerated_at TEXT,
        regenerate_count    INTEGER NOT NULL DEFAULT 0,
        feedback_history    TEXT,
        prompt_version      TEXT,
        briefing_id         INTEGER,
        read_at             TEXT,
        created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE (user_id, plan_date)
    );
    CREATE TABLE IF NOT EXISTS day_plan_items (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        day_plan_id  INTEGER NOT NULL REFERENCES day_plans(id) ON DELETE CASCADE,
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
        created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );

    CREATE TABLE IF NOT EXISTS targets (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        text                TEXT NOT NULL,
        intent              TEXT NOT NULL DEFAULT '',
        level               TEXT NOT NULL DEFAULT 'day'
                            CHECK(level IN ('quarter','month','week','day','custom')),
        custom_label        TEXT NOT NULL DEFAULT '',
        period_start        TEXT NOT NULL DEFAULT '',
        period_end          TEXT NOT NULL DEFAULT '',
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
                            CHECK(source_type IN ('extract','track','digest','briefing','manual','chat',
                                                   'inbox','jira','slack','promoted_subitem','idea')),
        source_id           TEXT NOT NULL DEFAULT '',
        ai_level_confidence REAL DEFAULT NULL,
        created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        notified_at         TEXT NOT NULL DEFAULT '',
        next_step           TEXT NOT NULL DEFAULT '',
        next_step_at        TEXT NOT NULL DEFAULT ''
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

    CREATE TABLE IF NOT EXISTS target_links (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        source_target_id    INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
        target_target_id    INTEGER REFERENCES targets(id) ON DELETE CASCADE,
        external_ref        TEXT NOT NULL DEFAULT '',
        relation            TEXT NOT NULL
                            CHECK(relation IN ('contributes_to','blocks','related','duplicates')),
        confidence          REAL DEFAULT NULL,
        created_by          TEXT NOT NULL DEFAULT 'ai'
                            CHECK(created_by IN ('ai','user')),
        created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
    );
    CREATE INDEX IF NOT EXISTS idx_target_links_source ON target_links(source_target_id);
    CREATE INDEX IF NOT EXISTS idx_target_links_target ON target_links(target_target_id);

    CREATE TABLE IF NOT EXISTS catchup_sessions (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        created_at     TEXT NOT NULL,
        status         TEXT NOT NULL CHECK(status IN ('building','active','done','failed')),
        total_themes   INTEGER NOT NULL DEFAULT 0,
        reviewed_count INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS catchup_themes (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id       INTEGER NOT NULL REFERENCES catchup_sessions(id) ON DELETE CASCADE,
        order_idx        INTEGER NOT NULL DEFAULT 0,
        title            TEXT NOT NULL DEFAULT '',
        narrative        TEXT NOT NULL DEFAULT '',
        priority         TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('high','medium','low')),
        needs_you        INTEGER NOT NULL DEFAULT 0,
        suggested_action TEXT NOT NULL DEFAULT '',
        refs             TEXT NOT NULL DEFAULT '[]',
        gen_state        TEXT NOT NULL DEFAULT 'skeleton' CHECK(gen_state IN ('skeleton','expanding','ready','failed')),
        review_state     TEXT NOT NULL DEFAULT 'pending' CHECK(review_state IN ('pending','reviewed','snoozed')),
        snooze_until     TEXT NOT NULL DEFAULT '',
        task_id          INTEGER NOT NULL DEFAULT 0,
        created_at       TEXT NOT NULL,
        updated_at       TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_catchup_themes_session ON catchup_themes(session_id, order_idx);

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
        suggested_resolution TEXT NOT NULL DEFAULT '',
        created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE INDEX IF NOT EXISTS idx_situations_status_rank ON situations(status, rank DESC);
    CREATE INDEX IF NOT EXISTS idx_situations_updated ON situations(updated_at DESC);

    CREATE TABLE IF NOT EXISTS situation_signals (
        situation_id   INTEGER NOT NULL REFERENCES situations(id) ON DELETE CASCADE,
        inbox_item_id  INTEGER NOT NULL REFERENCES inbox_items(id) ON DELETE CASCADE,
        UNIQUE(situation_id, inbox_item_id)
    );
    CREATE INDEX IF NOT EXISTS idx_situation_signals_item ON situation_signals(inbox_item_id);

    CREATE TABLE IF NOT EXISTS meeting_prep_cache (
        event_id      TEXT PRIMARY KEY,
        result_json   TEXT NOT NULL DEFAULT '',
        user_notes    TEXT NOT NULL DEFAULT '',
        generated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
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
    -- meeting_recaps).
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
        updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE INDEX IF NOT EXISTS idx_meeting_transcripts_event ON meeting_transcripts(event_id);
    CREATE TABLE IF NOT EXISTS voice_prints (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        person_key   TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        embedding    BLOB NOT NULL,
        sample_count INTEGER NOT NULL DEFAULT 1,
        updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS feed_items (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        item_type   TEXT NOT NULL CHECK (item_type IN ('situation','meeting','briefing','meeting_recap','day_plan')),
        source_id   TEXT NOT NULL,
        event_ts    TEXT NOT NULL,
        importance  INTEGER NOT NULL DEFAULT 50,
        hidden_at   TEXT,
        seen_at     TEXT,
        created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        UNIQUE(item_type, source_id)
    );
    CREATE INDEX IF NOT EXISTS idx_feed_items_event_ts ON feed_items(event_ts DESC);

    CREATE TABLE IF NOT EXISTS memory_nodes (
        id            TEXT PRIMARY KEY,
        type          TEXT NOT NULL CHECK (type IN ('entity','episode','rollup','belief')),
        tier          TEXT NOT NULL DEFAULT 'long' CHECK (tier IN ('short','long')),
        status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed','tombstone','shaken','retired')),
        redirect_to   TEXT,
        title         TEXT NOT NULL DEFAULT '',
        path          TEXT NOT NULL DEFAULT '',
        content_hash  TEXT NOT NULL DEFAULT '',
        indexed_at    TEXT NOT NULL DEFAULT '',
        subject       TEXT NOT NULL DEFAULT '',
        confidence    REAL NOT NULL DEFAULT 0,
        importance_score REAL NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS memory_aliases (
        alias    TEXT PRIMARY KEY COLLATE NOCASE,
        node_id  TEXT NOT NULL REFERENCES memory_nodes(id)
    );
    CREATE TABLE IF NOT EXISTS memory_provenance (
        node_id     TEXT NOT NULL REFERENCES memory_nodes(id),
        scheme      TEXT NOT NULL DEFAULT '',
        channel_id  TEXT NOT NULL,
        ts_raw      TEXT NOT NULL,
        ts_unix     REAL NOT NULL,
        sender_id   TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (node_id, channel_id, ts_raw)
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
        id UNINDEXED, title, body
    );
    CREATE TABLE IF NOT EXISTS memory_dispute_flags (
        node_id     TEXT PRIMARY KEY REFERENCES memory_nodes(id),
        flagged_at  TEXT NOT NULL,
        reason      TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS email_accounts (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        provider       TEXT NOT NULL CHECK(provider IN ('imap','outlook')),
        email_address  TEXT NOT NULL DEFAULT '',
        host           TEXT NOT NULL DEFAULT '',
        port           INTEGER NOT NULL DEFAULT 0,
        security       TEXT NOT NULL DEFAULT 'ssl' CHECK(security IN ('ssl','starttls','none')),
        folder         TEXT NOT NULL DEFAULT 'INBOX',
        label          TEXT NOT NULL DEFAULT '',
        status         TEXT NOT NULL DEFAULT 'ok',
        error          TEXT NOT NULL DEFAULT '',
        last_uid       INTEGER NOT NULL DEFAULT 0,
        uidvalidity    INTEGER NOT NULL DEFAULT 0,
        created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS calendar_accounts (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        provider       TEXT NOT NULL CHECK(provider IN ('caldav','ics')),
        username       TEXT NOT NULL DEFAULT '',
        url            TEXT NOT NULL DEFAULT '',
        label          TEXT NOT NULL DEFAULT '',
        status         TEXT NOT NULL DEFAULT 'ok',
        error          TEXT NOT NULL DEFAULT '',
        created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS imap_messages (
        account_id     INTEGER NOT NULL REFERENCES email_accounts(id) ON DELETE CASCADE,
        uid            INTEGER NOT NULL,
        uidvalidity    INTEGER NOT NULL DEFAULT 0,
        from_email     TEXT NOT NULL DEFAULT '',
        from_name      TEXT NOT NULL DEFAULT '',
        to_json        TEXT NOT NULL DEFAULT '[]',
        cc_json        TEXT NOT NULL DEFAULT '[]',
        subject        TEXT NOT NULL DEFAULT '',
        snippet        TEXT NOT NULL DEFAULT '',
        body_text      TEXT NOT NULL DEFAULT '',
        internal_date  TEXT NOT NULL DEFAULT '',
        is_unread      INTEGER NOT NULL DEFAULT 0,
        permalink      TEXT NOT NULL DEFAULT '',
        synced_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        PRIMARY KEY (account_id, uidvalidity, uid)
    );

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
    """

    // MARK: - Briefing Fixtures

    package static func insertBriefing(
        _ db: Database,
        userID: String = "U001",
        date: String = "2024-01-15",
        role: String = "engineer",
        attention: String = "[]",
        yourDay: String = "[]",
        whatHappened: String = "[]",
        teamPulse: String = "[]",
        coaching: String = "[]",
        model: String = "haiku",
        readAt: String? = nil
    ) throws {
        try db.execute(sql: """
            INSERT INTO briefings (user_id, date, role, attention, your_day,
                what_happened, team_pulse, coaching, model, read_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [userID, date, role, attention, yourDay,
                             whatHappened, teamPulse, coaching, model, readAt])
    }

    // MARK: - Profile Fixtures

    package static func insertProfile(
        _ db: Database,
        slackUserID: String = "U001",
        role: String = "",
        team: String = "",
        responsibilities: String = "[]",
        reports: String = "[]",
        peers: String = "[]",
        manager: String = "",
        starredChannels: String = "[]",
        starredPeople: String = "[]",
        painPoints: String = "[]",
        trackFocus: String = "[]",
        onboardingDone: Bool = false,
        customPromptContext: String = ""
    ) throws {
        try db.execute(sql: """
            INSERT INTO user_profile
                (slack_user_id, role, team, responsibilities, reports, peers, manager,
                 starred_channels, starred_people, pain_points, track_focus,
                 onboarding_done, custom_prompt_context)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                slackUserID, role, team, responsibilities, reports, peers, manager,
                starredChannels, starredPeople, painPoints, trackFocus,
                onboardingDone ? 1 : 0, customPromptContext
            ])
    }

    // MARK: - People Card Fixtures

    package static func insertPeopleCard(
        _ db: Database,
        userID: String = "U001",
        periodFrom: Double = 1700000000,
        periodTo: Double = 1700604800,
        messageCount: Int = 100,
        channelsActive: Int = 5,
        threadsInitiated: Int = 10,
        threadsReplied: Int = 20,
        avgMessageLength: Double = 42.5,
        activeHoursJSON: String = #"{"9":12,"10":8,"14":15}"#,
        volumeChangePct: Double = 15.0,
        summary: String = "Active contributor",
        communicationStyle: String = "driver",
        decisionRole: String = "approver",
        redFlags: String = "[]",
        highlights: String = #"["Great leadership"]"#,
        accomplishments: String = "[]",
        communicationGuide: String = "",
        decisionStyle: String = "",
        tactics: String = "[]",
        relationshipContext: String = "",
        status: String = "ok",
        model: String = "haiku"
    ) throws {
        try db.execute(sql: """
            INSERT INTO people_cards (user_id, period_from, period_to, message_count, channels_active,
                threads_initiated, threads_replied, avg_message_length, active_hours_json,
                volume_change_pct, summary, communication_style, decision_role, red_flags, highlights,
                accomplishments, communication_guide, decision_style, tactics, relationship_context, status, model)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [userID, periodFrom, periodTo, messageCount, channelsActive,
                             threadsInitiated, threadsReplied, avgMessageLength, activeHoursJSON,
                             volumeChangePct, summary, communicationStyle, decisionRole, redFlags, highlights,
                             accomplishments, communicationGuide, decisionStyle, tactics, relationshipContext, status, model])
    }

    // MARK: - People Card Summary Fixtures

    package static func insertPeopleCardSummary(
        _ db: Database,
        periodFrom: Double = 1700000000,
        periodTo: Double = 1700604800,
        summary: String = "Team is collaborating well",
        attention: String = #"["Alice is overloaded"]"#,
        tips: String = #"["Consider redistributing tasks"]"#,
        model: String = "haiku",
        inputTokens: Int = 500,
        outputTokens: Int = 200,
        costUSD: Double = 0.001,
        promptVersion: Int = 1
    ) throws {
        try db.execute(sql: """
            INSERT INTO people_card_summaries (period_from, period_to, summary, attention, tips,
                model, input_tokens, output_tokens, cost_usd, prompt_version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [periodFrom, periodTo, summary, attention, tips,
                             model, inputTokens, outputTokens, costUSD, promptVersion])
    }

    // MARK: - Task Fixtures

    package static func insertTask(
        _ db: Database,
        text: String = "Review PR",
        intent: String = "",
        status: String = "todo",
        priority: String = "medium",
        ownership: String = "mine",
        ballOn: String = "",
        dueDate: String = "",
        snoozeUntil: String = "",
        blocking: String = "",
        tags: String = "[]",
        subItems: String = "[]",
        sourceType: String = "manual",
        sourceID: String = ""
    ) throws {
        try db.execute(sql: """
            INSERT INTO targets (text, intent, status, priority, ownership, ball_on,
                due_date, snooze_until, blocking, tags, sub_items, source_type, source_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [text, intent, status, priority, ownership, ballOn,
                             dueDate, snoozeUntil, blocking, tags, subItems, sourceType, sourceID])
    }

    // MARK: - Target Fixtures

    @discardableResult
    package static func insertTarget(
        _ db: Database,
        text: String = "Ship the feature",
        intent: String = "",
        level: String = "week",
        customLabel: String = "",
        periodStart: String = "2026-04-20",
        periodEnd: String = "2026-04-26",
        parentId: Int? = nil,
        status: String = "todo",
        priority: String = "medium",
        ownership: String = "mine",
        ballOn: String = "",
        dueDate: String = "",
        snoozeUntil: String = "",
        blocking: String = "",
        tags: String = "[]",
        subItems: String = "[]",
        notes: String = "[]",
        progress: Double = 0.0,
        sourceType: String = "manual",
        sourceID: String = "",
        aiLevelConfidence: Double? = nil
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO targets (text, intent, level, custom_label, period_start, period_end,
                parent_id, status, priority, ownership, ball_on, due_date, snooze_until,
                blocking, tags, sub_items, notes, progress, source_type, source_id, ai_level_confidence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [text, intent, level, customLabel, periodStart, periodEnd,
                             parentId, status, priority, ownership, ballOn, dueDate, snoozeUntil,
                             blocking, tags, subItems, notes, progress, sourceType, sourceID, aiLevelConfidence])
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertTargetLink(
        _ db: Database,
        sourceTargetId: Int,
        targetTargetId: Int? = nil,
        externalRef: String = "",
        relation: String = "contributes_to",
        confidence: Double? = nil,
        createdBy: String = "ai"
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO target_links (source_target_id, target_target_id, external_ref, relation, confidence, created_by)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [sourceTargetId, targetTargetId, externalRef, relation, confidence, createdBy])
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertDigestTopic(
        _ db: Database,
        digestID: Int = 1,
        idx: Int = 0,
        title: String = "Sample topic",
        summary: String = "Topic summary",
        decisions: String = "[]",
        actionItems: String = "[]",
        situations: String = "[]",
        keyMessages: String = "[]"
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO digest_topics (digest_id, idx, title, summary, decisions, action_items, situations, key_messages)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [digestID, idx, title, summary, decisions, actionItems, situations, keyMessages])
        return db.lastInsertedRowID
    }

    // MARK: - Inbox Fixtures

    @discardableResult
    package static func insertInboxItem(
        _ db: Database,
        channelID: String = "C001",
        messageTS: String = "1700000000.000100",
        threadTS: String = "",
        senderUserID: String = "U002",
        triggerType: String = "mention",
        snippet: String = "Hey, can you review this?",
        permalink: String = "",
        status: String = "pending",
        priority: String = "medium",
        aiReason: String = "",
        resolvedReason: String = "",
        snoozeUntil: String = "",
        taskID: Int? = nil,       // kept for call-site compat; maps to target_id column
        readAt: String? = nil,
        archivedAt: String? = nil,
        itemClass: String = "actionable",
        cardStatus: String = "none",
        whyMatters: String = "",
        threadDigest: String = "",
        draftReply: String = ""
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO inbox_items (channel_id, message_ts, thread_ts, sender_user_id,
                trigger_type, snippet, permalink, status, priority, ai_reason,
                resolved_reason, snooze_until, target_id, read_at, archived_at,
                item_class, card_status, why_matters, thread_digest, draft_reply)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [channelID, messageTS, threadTS, senderUserID,
                             triggerType, snippet, permalink, status, priority, aiReason,
                             resolvedReason, snoozeUntil, taskID, readAt, archivedAt,
                             itemClass, cardStatus, whyMatters, threadDigest, draftReply])
        return db.lastInsertedRowID
    }

    // MARK: - Inbox Learned Rules Fixtures

    package static func insertLearnedRule(
        _ db: Database,
        scopeKey: String = "sender:U1",
        weight: Double = -0.5,
        source: String = "implicit",
        evidenceCount: Int = 3,
        lastUpdated: String = "2026-04-23T10:00:00Z",
        ruleType: String = "source_mute"
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO inbox_learned_rules (rule_type, scope_key, weight, source, evidence_count, last_updated)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [ruleType, scopeKey, weight, source, evidenceCount, lastUpdated]
        )
    }

    // MARK: - Inbox Feedback Fixtures

    package static func insertFeedbackRecord(
        _ db: Database,
        inboxItemId: Int = 1,
        rating: Int = 1,
        reason: String = "useful",
        createdAt: String = "2026-04-23T10:00:00Z"
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO inbox_feedback (inbox_item_id, rating, reason, created_at)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [inboxItemId, rating, reason, createdAt]
        )
    }

    // MARK: - Calendar Fixtures

    package static func ensureCalendar(
        _ db: Database,
        id: String = "primary",
        name: String = "Primary",
        isPrimary: Bool = true,
        isSelected: Bool = true,
        accountID: Int64? = nil
    ) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO calendar_calendars (id, name, is_primary, is_selected, account_id)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [id, name, isPrimary ? 1 : 0, isSelected ? 1 : 0, accountID])
    }

    package static func insertCalendarEvent(
        _ db: Database,
        id: String = "evt_001",
        calendarID: String = "primary",
        title: String = "Team Standup",
        description: String = "",
        startTime: String = "2023-11-14T22:13:20Z",
        endTime: String = "2023-11-14T23:13:20Z",
        isAllDay: Bool = false,
        location: String = "",
        organizerEmail: String = "alice@example.com",
        attendees: String = "[]",
        isRecurring: Bool = false,
        eventStatus: String = "confirmed",
        eventType: String = "",
        htmlLink: String = "",
        updatedAt: String = ""
    ) throws {
        try ensureCalendar(db, id: calendarID)
        try db.execute(sql: """
            INSERT INTO calendar_events (id, calendar_id, title, description, location,
                start_time, end_time, organizer_email, attendees, is_recurring,
                is_all_day, event_status, event_type, html_link, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, calendarID, title, description, location,
                             startTime, endTime, organizerEmail, attendees,
                             isRecurring ? 1 : 0, isAllDay ? 1 : 0, eventStatus,
                             eventType, htmlLink, updatedAt])
    }

    // MARK: - Day Plan Fixtures

    @discardableResult
    package static func insertDayPlan(
        _ db: Database,
        userID: String = "U001",
        planDate: String = "2026-04-23",
        status: String = "active",
        hasConflicts: Bool = false,
        conflictSummary: String? = nil,
        generatedAt: String = "2026-04-23T08:00:00Z",
        lastRegeneratedAt: String? = nil,
        regenerateCount: Int = 0,
        feedbackHistory: String? = nil,
        promptVersion: String? = nil,
        briefingID: Int? = nil,
        readAt: String? = nil
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO day_plans (user_id, plan_date, status, has_conflicts, conflict_summary,
                generated_at, last_regenerated_at, regenerate_count, feedback_history,
                prompt_version, briefing_id, read_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [userID, planDate, status, hasConflicts ? 1 : 0, conflictSummary,
                             generatedAt, lastRegeneratedAt, regenerateCount, feedbackHistory,
                             promptVersion, briefingID, readAt])
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertDayPlanItem(
        _ db: Database,
        dayPlanID: Int64 = 1,
        kind: String = "timeblock",
        sourceType: String = "manual",
        sourceID: String? = nil,
        title: String = "Review PR",
        description: String? = nil,
        rationale: String? = nil,
        startTime: String? = nil,
        endTime: String? = nil,
        durationMin: Int? = nil,
        priority: String? = "medium",
        status: String = "pending",
        orderIndex: Int = 0,
        tags: String? = nil
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO day_plan_items (day_plan_id, kind, source_type, source_id, title,
                description, rationale, start_time, end_time, duration_min, priority,
                status, order_index, tags)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [dayPlanID, kind, sourceType, sourceID, title,
                             description, rationale, startTime, endTime, durationMin,
                             priority, status, orderIndex, tags])
        return db.lastInsertedRowID
    }

    // MARK: - Situation Fixtures

    @discardableResult
    package static func insertSituation(
        _ db: Database,
        title: String = "Renewal deal stalling",
        kind: String = "external",
        status: String = "open",
        snoozeUntil: String = "",
        priority: String = "medium",
        rank: Double = 0,
        aiReason: String = "",
        summary: String = "",
        whyMatters: String = "",
        chronology: String = "",
        cardStatus: String = "none",
        targetID: Int? = nil,
        trackID: Int? = nil,
        convertedTargetID: Int? = nil,
        convertedTrackID: Int? = nil,
        lastSignalAt: String = "",
        resolvedReason: String = "",
        suggestedResolution: String = "",
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO situations (title, kind, status, snooze_until, priority, rank,
                ai_reason, summary, why_matters, chronology, card_status, target_id,
                track_id, converted_target_id, converted_track_id, last_signal_at,
                resolved_reason, suggested_resolution, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                COALESCE(?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
                COALESCE(?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')))
            """, arguments: [title, kind, status, snoozeUntil, priority, rank,
                             aiReason, summary, whyMatters, chronology, cardStatus, targetID,
                             trackID, convertedTargetID, convertedTrackID, lastSignalAt,
                             resolvedReason, suggestedResolution, createdAt, updatedAt])
        return db.lastInsertedRowID
    }

    // MARK: - Feed Item Fixtures

    @discardableResult
    package static func insertFeedItem(
        _ db: Database,
        itemType: String,
        sourceID: String,
        eventTs: String,
        importance: Int = 50,
        hiddenAt: String? = nil,
        seenAt: String? = nil
    ) throws -> Int64 {
        try db.execute(
            sql: """
            INSERT INTO feed_items (item_type, source_id, event_ts, importance, hidden_at, seen_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [itemType, sourceID, eventTs, importance, hiddenAt, seenAt])
        return db.lastInsertedRowID
    }

    package static func insertMeetingRecap(
        _ db: Database,
        eventID: String? = nil,
        transcriptID: Int64? = nil,
        sourceText: String = "",
        recapJSON: String = #"{"summary":"Recap","key_decisions":[],"action_items":["ship it"],"open_questions":[]}"#,
        createdAt: String = "2026-07-09T10:00:00Z"
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO meeting_recaps (event_id, transcript_id, source_text, recap_json, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [eventID, transcriptID, sourceText, recapJSON, createdAt, createdAt])
    }

    package static func insertMeetingTranscript(
        _ db: Database,
        id: Int64? = nil,
        eventID: String? = nil,
        title: String = "Rec",
        audioPath: String? = nil,
        durationSec: Int = 60,
        transcriptText: String = "text",
        summaryJSON: String? = nil,
        notesMD: String? = nil,
        segmentsJSON: String? = nil,
        speakersJSON: String? = nil,
        chaptersJSON: String? = nil,
        createdAt: String? = nil
    ) throws {
        try db.execute(sql: """
            INSERT INTO meeting_transcripts (id, event_id, title, audio_path,
                duration_sec, transcript_text, summary_json, notes_md, segments_json, speakers_json, chapters_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE(?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')))
            """,
            arguments: [id, eventID, title, audioPath, durationSec,
                        transcriptText, summaryJSON, notesMD, segmentsJSON, speakersJSON, chaptersJSON, createdAt])
    }

    package static func insertMeetingPrep(_ db: Database, eventID: String, resultJSON: String) throws {
        try db.execute(
            sql: "INSERT INTO meeting_prep_cache (event_id, result_json) VALUES (?, ?)",
            arguments: [eventID, resultJSON])
    }

    package static func linkSituationSignal(
        _ db: Database,
        situationID: Int64,
        inboxItemID: Int64
    ) throws {
        try db.execute(sql: """
            INSERT INTO situation_signals (situation_id, inbox_item_id)
            VALUES (?, ?)
            """, arguments: [situationID, inboxItemID])
    }

    // MARK: - Idea Fixtures

    @discardableResult
    package static func insertIdea(
        _ db: Database,
        kind: String = "idea",
        title: String = "Ship a weekly digest email",
        essence: String = "",
        status: String = "proposed",
        source: String = "mined",
        snoozeUntil: String = "",
        needsReview: Bool = false,
        reviewReason: String = "",
        similarToID: Int? = nil,
        mergedIntoID: Int? = nil,
        supersededByID: Int? = nil,
        convertedTargetID: Int? = nil,
        ownerRating: Int = 0,
        ratingComment: String = "",
        lastMentionAt: String = "",
        createdAt: String? = nil,
        updatedAt: String? = nil,
        seenAt: String? = nil
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO ideas (kind, title, essence, status, source, snooze_until,
                needs_review, review_reason, similar_to_id, merged_into_id,
                superseded_by_id, converted_target_id, owner_rating, rating_comment,
                last_mention_at, created_at, updated_at, seen_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                COALESCE(?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
                COALESCE(?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
                ?)
            """, arguments: [kind, title, essence, status, source, snoozeUntil,
                             needsReview, reviewReason, similarToID, mergedIntoID,
                             supersededByID, convertedTargetID, ownerRating, ratingComment,
                             lastMentionAt, createdAt, updatedAt, seenAt])
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertIdeaMention(
        _ db: Database,
        ideaID: Int64,
        source: String = "slack",
        ref: String = "",
        quote: String = "",
        author: String = "",
        saidAt: String = "",
        createdAt: String? = nil
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO idea_mentions (idea_id, source, ref, quote, author, said_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?, COALESCE(?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')))
            """, arguments: [ideaID, source, ref, quote, author, saidAt, createdAt])
        return db.lastInsertedRowID
    }

    // MARK: - Stream Digest Fixtures

    @discardableResult
    package static func insertStreamDigest(
        _ db: Database,
        source: String = "gmail",
        accountID: Int = 1,
        scope: String = "",
        periodFrom: String = "2024-01-01T00:00:00Z",
        periodTo: String = "2024-01-02T00:00:00Z",
        topicsJSON: String = "[]",
        createdAt: String? = nil,
        readAt: String? = nil
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO stream_digests (source, account_id, scope, period_from, period_to,
                topics_json, created_at, read_at)
            VALUES (?, ?, ?, ?, ?, ?,
                COALESCE(?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
                ?)
            """, arguments: [source, accountID, scope, periodFrom, periodTo,
                             topicsJSON, createdAt, readAt])
        return db.lastInsertedRowID
    }

    // MARK: - Memory Fixtures

    package static func insertMemoryNode(
        _ db: Database,
        id: String,
        type: String = "entity",
        title: String = "",
        subject: String = "",
        confidence: Double = 0,
        status: String = "active",
        tier: String = "long",
        path: String = "",
        redirectTo: String? = nil,
        indexedAt: String = "",
        importanceScore: Double = 0
    ) throws {
        try db.execute(sql: """
            INSERT INTO memory_nodes (
                id, type, tier, status, redirect_to, title, path, content_hash, indexed_at, subject, confidence, importance_score
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, '', ?, ?, ?, ?)
            """, arguments: [id, type, tier, status, redirectTo, title, path, indexedAt, subject, confidence, importanceScore])
    }

    package static func insertMemoryProvenance(
        _ db: Database,
        nodeID: String,
        channelID: String,
        tsRaw: String,
        tsUnix: Double,
        senderID: String,
        scheme: String = ""
    ) throws {
        try db.execute(sql: """
            INSERT INTO memory_provenance (node_id, scheme, channel_id, ts_raw, ts_unix, sender_id)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [nodeID, scheme, channelID, tsRaw, tsUnix, senderID])
    }

    package static func insertMemoryAlias(
        _ db: Database,
        alias: String,
        nodeID: String
    ) throws {
        try db.execute(sql: """
            INSERT INTO memory_aliases (alias, node_id) VALUES (?, ?)
            """, arguments: [alias, nodeID])
    }

    package static func insertMemoryFTS(
        _ db: Database,
        id: String,
        title: String = "",
        body: String = ""
    ) throws {
        try db.execute(sql: """
            INSERT INTO memory_fts (id, title, body) VALUES (?, ?, ?)
            """, arguments: [id, title, body])
    }

    package static func insertMemoryDispute(
        _ db: Database,
        nodeID: String,
        reason: String = "contested"
    ) throws {
        try db.execute(sql: """
            INSERT INTO memory_dispute_flags (node_id, flagged_at, reason)
            VALUES (?, '2026-07-17T00:00:00Z', ?)
            """, arguments: [nodeID, reason])
    }

    // MARK: - Email Account Fixtures

    @discardableResult
    package static func insertEmailAccount(
        _ db: Database,
        provider: String = "imap",
        emailAddress: String = "me@example.com",
        host: String = "imap.example.com",
        port: Int = 993,
        security: String = "ssl",
        folder: String = "INBOX",
        label: String = "",
        status: String = "ok",
        error: String = "",
        createdAt: String = "2026-01-01T00:00:00Z"
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO email_accounts
                    (provider, email_address, host, port, security, folder, label, status, error, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [provider, emailAddress, host, port, security, folder, label, status, error, createdAt, createdAt]
        )
        return db.lastInsertedRowID
    }

    // MARK: - Calendar Account Fixtures

    @discardableResult
    package static func insertCalendarAccount(
        _ db: Database,
        provider: String = "caldav",
        username: String = "me@example.com",
        url: String = "https://caldav.example.com",
        label: String = "",
        status: String = "ok",
        error: String = "",
        createdAt: String = "2026-01-01T00:00:00Z"
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO calendar_accounts
                    (provider, username, url, label, status, error, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [provider, username, url, label, status, error, createdAt, createdAt]
        )
        return db.lastInsertedRowID
    }

    // MARK: - Google Account Fixtures

    @discardableResult
    package static func insertSlackAccount(
        _ db: Database,
        teamID: String = "",
        teamName: String = "",
        teamDomain: String = "",
        label: String = "",
        currentUserID: String = "",
        status: String = "ok",
        error: String = "",
        enabled: Bool = true,
        searchLastDate: String = "",
        createdAt: String = "2026-01-01T00:00:00Z"
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO slack_accounts
                    (team_id, team_name, team_domain, label, current_user_id, status, error, enabled, search_last_date, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [teamID, teamName, teamDomain, label, currentUserID, status, error, enabled, searchLastDate, createdAt]
        )
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertJiraAccount(
        _ db: Database,
        cloudID: String = "",
        siteURL: String = "",
        siteName: String = "",
        label: String = "",
        status: String = "ok",
        error: String = "",
        enabled: Bool = true,
        createdAt: String = "2026-01-01T00:00:00Z"
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO jira_accounts
                    (cloud_id, site_url, site_name, label, status, error, enabled, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [cloudID, siteURL, siteName, label, status, error, enabled, createdAt]
        )
        return db.lastInsertedRowID
    }

    package static func insertGoogleAccount(
        _ db: Database,
        email: String = "",
        label: String = "",
        clientID: String = "",
        calendarEnabled: Bool = false,
        gmailEnabled: Bool = false,
        status: String = "ok",
        error: String = "",
        createdAt: String = "2026-01-01T00:00:00Z"
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO google_accounts
                    (email, label, client_id, calendar_enabled, gmail_enabled, status, error, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [email, label, clientID, calendarEnabled, gmailEnabled, status, error, createdAt, createdAt]
        )
        return db.lastInsertedRowID
    }
}
