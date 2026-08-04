import Foundation
import GRDB
import WatchtowerKit

/// Pushes a handful of representative records through the transport so every
/// tab renders REAL decoded models (not hardcoded view stubs). Each record is
/// a raw slice row encoded exactly like the desktop publisher encodes them
/// (`RowPayloadCoder`), so the hydrator + `ReplicaStore.fetchAll` decode path
/// is exercised end-to-end.
///
/// Runs ONLY on the `.inMemoryDemo` transport kind, and only in DEBUG — the
/// `.cloudKit` kind starts empty and hydrates from the user's own zone
/// (Plan 6 Decision 2; the gate lives in `AppEnvironment.bootstrap`).
enum DemoSeed {
    static func load(into transport: any CloudSyncTransport) async throws {
        let now = Date()
        let today = Self.day.string(from: now)

        var records: [CloudRecord] = []

        // MARK: Briefing (Today headline)
        records.append(try record(.briefing, "1", now, [
            "id": 1,
            "user_id": SlackID.namespaced(accountID: 1, rawID: "U_DEMO"),
            "date": today,
            "role": "Middle Management",
            "attention": #"[{"text":"Q3 launch risk needs a decision","priority":"high","reason":"Deadline Friday"}]"#,
            "your_day": #"[{"text":"Finalize the mobile app skeleton","priority":"high","status":"in_progress"},{"text":"Review the refund fix PR","priority":"medium","status":"todo"}]"#,
            "what_happened": #"[{"text":"Payments team shipped the refund fix"}]"#,
            "team_pulse": #"[{"text":"Alice is blocked on API access"}]"#,
            "coaching": #"[{"text":"Consider delegating the infra audit"}]"#,
            "model": "claude-demo",
            "input_tokens": 1200,
            "output_tokens": 800,
            "cost_usd": 0.03,
            "prompt_version": 3,
            "created_at": Self.iso.string(from: now),
        ]))

        // MARK: Calendar events (today)
        // Fixed LOCAL wall-clock times, not offsets from `now`: `now + 1 h`
        // crosses midnight on late-evening runs, and the Today tab's
        // `isDateInToday` filter would drop the events (a real near-midnight
        // test/demo flake, same family as 615a75c/bc78989).
        records.append(try record(.calendarEvent, "evt-1", now, [
            "id": "evt-1",
            "title": "Daily Standup",
            "location": "Zoom",
            "start_time": Self.iso.string(from: Self.todayAt(hour: 10, of: now)),
            "end_time": Self.iso.string(from: Self.todayAt(hour: 10, minute: 15, of: now)),
            "event_status": "confirmed",
        ]))
        records.append(try record(.calendarEvent, "evt-2", now, [
            "id": "evt-2",
            "title": "Mobile app design review",
            "location": "Room 4B",
            "start_time": Self.iso.string(from: Self.todayAt(hour: 15, of: now)),
            "end_time": Self.iso.string(from: Self.todayAt(hour: 16, of: now)),
            "event_status": "tentative",
        ]))

        // MARK: Inbox items
        records.append(try record(.inboxItem, "1", now, [
            "id": 1,
            "channel_id": SlackID.namespaced(accountID: 1, rawID: "C_DEMO"),
            "message_ts": String(now.timeIntervalSince1970),
            "sender_user_id": SlackID.namespaced(accountID: 1, rawID: "U_ALICE"),
            "trigger_type": "mention",
            "snippet": "Can you review the launch checklist before Friday?",
            "status": "pending",
            "priority": "high",
            "item_class": "actionable",
            "created_at": Self.iso.string(from: now),
        ]))
        records.append(try record(.inboxItem, "2", now, [
            "id": 2,
            "channel_id": SlackID.namespaced(accountID: 1, rawID: "D_DEMO"),
            "message_ts": String(now.timeIntervalSince1970 - 300),
            "sender_user_id": SlackID.namespaced(accountID: 1, rawID: "U_BOB"),
            "trigger_type": "dm",
            "snippet": "Thanks for the update — I'll take it from here.",
            "status": "pending",
            "priority": "medium",
            "item_class": "actionable",
            "created_at": Self.iso.string(from: now),
        ]))

        // MARK: Situations (Inbox dashboard)
        records.append(try record(.situation, "1", now, [
            "id": 1,
            "title": "Q3 launch checklist needs your review",
            "kind": "external",
            "status": "open",
            "priority": "high",
            "rank": 90.0,
            "summary": "Alice asked for a review of the launch checklist; the Friday deadline is at risk without it.",
            "why_matters": "The Q3 launch gate is Friday — an unreviewed checklist blocks the go/no-go call.",
            "chronology": "Alice flagged the checklist in #launch. Bob confirmed he picked up the rollout notes.",
            "card_status": "ready",
            "signal_ids": "[1,2]",
            "last_signal_at": Self.iso.string(from: now),
            "created_at": Self.iso.string(from: now),
            "updated_at": Self.iso.string(from: now),
        ]))
        records.append(try record(.situation, "2", now, [
            "id": 2,
            "title": "Refund fix rollout wrapped up",
            "kind": "external",
            "status": "open",
            "priority": "medium",
            "rank": 40.0,
            "summary": "The payments team shipped the refund fix and confirmed the rollout finished cleanly.",
            "card_status": "ready",
            "suggested_resolution": "The rollout finished and nobody is waiting on you — this looks resolved.",
            "signal_ids": "[]",
            "last_signal_at": Self.iso.string(from: now.addingTimeInterval(-3600)),
            "created_at": Self.iso.string(from: now),
            "updated_at": Self.iso.string(from: now),
        ]))

        // MARK: Targets (Tasks, grouped by status)
        records.append(try record(.target, "1", now, [
            "id": 1,
            "text": "Ship the mobile app skeleton",
            "level": "week",
            "status": "in_progress",
            "priority": "high",
            "due_date": today,
            "created_at": Self.iso.string(from: now),
        ]))
        records.append(try record(.target, "2", now, [
            "id": 2,
            "text": "Draft the CloudKit packaging plan",
            "level": "week",
            "status": "todo",
            "priority": "medium",
            "created_at": Self.iso.string(from: now),
        ]))
        records.append(try record(.target, "3", now, [
            "id": 3,
            "text": "Land the replica store + hydrator",
            "level": "week",
            "status": "done",
            "priority": "high",
            "created_at": Self.iso.string(from: now),
        ]))

        // MARK: Tracks
        records.append(try record(.track, "1", now, [
            "id": 1,
            "text": "Refund flow redesign discussion",
            "category": "decision",
            "ownership": "mine",
            "priority": "high",
            "has_updates": true,
            "updated_at": Self.iso.string(from: now),
            "created_at": Self.iso.string(from: now),
        ]))
        records.append(try record(.track, "2", now, [
            "id": 2,
            "text": "API access provisioning for Alice",
            "category": "blocker",
            "ownership": "delegated",
            "priority": "medium",
            "read_at": Self.iso.string(from: now),
            "has_updates": false,
            "updated_at": Self.iso.string(from: now),
            "created_at": Self.iso.string(from: now),
        ]))

        // MARK: Desktop heartbeat (Chat liveness)
        // Refreshed every launch so the Chat tab demos the reachable state;
        // it goes stale — and the "Mac unreachable" banner appears — if the
        // app stays in the foreground past the 12-minute threshold.
        records.append(try CloudRecordFactory.record(
            for: HeartbeatPayload(updatedAt: now, appVersion: "demo"),
            modifiedAt: now
        ))

        try await transport.save(records)
    }

    /// Seeds one canned chat exchange — a user question plus a streamed,
    /// completed answer — so the Chat tab renders content on first boot.
    /// It rides the REAL pipeline end-to-end: `assembler.send` writes the
    /// turn + placeholder and ships the wire record, the answer chunks land
    /// in the relay zone, and RelayFeed's first poll hands them back to the
    /// assembler — exactly the path a live desktop answer takes.
    ///
    /// Skipped once any session exists: the replica persists across
    /// launches, and re-seeding would mint a duplicate session per launch
    /// (sessions have generated ids, unlike the fixed-id slice rows above).
    static func loadChatExchange(
        via assembler: ChatAssembler,
        into transport: any CloudSyncTransport,
        store: ReplicaStore
    ) async throws {
        guard try store.chatSessions().isEmpty else { return }
        let ids = try await assembler.send(text: "What needs my attention today?", sessionID: nil)
        let parts: [(text: String, done: Bool)] = [
            ("Two things stand out. ", false),
            ("The Q3 launch risk needs a decision by Friday, ", false),
            ("and Alice is still blocked on API access.", true),
        ]
        let now = Date()
        try await transport.save(try parts.enumerated().map { seq, part in
            try CloudRecordFactory.record(
                for: ChatChunkPayload(
                    sessionID: ids.sessionID,
                    messageID: ids.messageID,
                    seq: seq,
                    text: part.text,
                    done: part.done
                ),
                modifiedAt: now
            )
        })
    }

    // MARK: - Helpers

    /// An instant pinned INSIDE `now`'s local day (see the calendar-events
    /// note above). The nil fallback is unreachable for valid hour/minute.
    /// Residual straddle (accepted, Task 7 review): a run that seeds just
    /// before local midnight and asserts after it derives "today" twice on
    /// different days.
    private static func todayAt(hour: Int, minute: Int = 0, of now: Date) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
    }

    private static func record(_ kind: SliceKind, _ id: String, _ at: Date, _ row: Row) throws -> CloudRecord {
        let slice = SliceRecord(
            kind: kind,
            id: id,
            modifiedAt: at,
            payload: try RowPayloadCoder.payload(from: row)
        )
        return CloudRecordFactory.record(for: slice)
    }

    private static let iso: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    private static let day: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()
}
