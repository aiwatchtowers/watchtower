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
        conferenceURL: String = "",
        updatedAt: String = ""
    ) throws {
        try ensureCalendar(db, id: calendarID)
        try db.execute(sql: """
            INSERT INTO calendar_events (id, calendar_id, title, description, location,
                start_time, end_time, organizer_email, attendees, is_recurring,
                is_all_day, event_status, event_type, html_link, conference_url, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [id, calendarID, title, description, location,
                             startTime, endTime, organizerEmail, attendees,
                             isRecurring ? 1 : 0, isAllDay ? 1 : 0, eventStatus,
                             eventType, htmlLink, conferenceURL, updatedAt])
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

    @discardableResult
    package static func insertAgentAction(
        _ db: Database,
        tool: String = "create_target",
        external: Bool = false,
        argsJSON: String = #"{"text":"Call Vasya","reason":"r"}"#,
        reason: String = "r",
        surface: String = "main",
        conversationID: Int64 = 1,
        turnID: String = "turn-1",
        status: String = "pending",
        resultJSON: String = "",
        error: String = "",
        createdAt: String = "2026-09-04T10:00:00Z",
        decidedAt: String = "",
        appliedAt: String = ""
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO agent_actions
                (tool, external, args_json, reason, surface, conversation_id, turn_id, status,
                 result_json, error, created_at, decided_at, applied_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [tool, external, argsJSON, reason, surface, conversationID, turnID, status,
                             resultJSON, error, createdAt, decidedAt, appliedAt])
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
