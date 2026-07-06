import Foundation
import GRDB
import WatchtowerKit

/// Pushes a handful of representative records through the transport so every
/// tab renders REAL decoded models (not hardcoded view stubs). Each record is
/// a raw slice row encoded exactly like the desktop publisher encodes them
/// (`RowPayloadCoder`), so the hydrator + `ReplicaStore.fetchAll` decode path
/// is exercised end-to-end.
///
/// DEBUG-only: production builds connect a real transport and never seed.
enum DemoSeed {
    static func load(into transport: any CloudSyncTransport) async throws {
        let now = Date()
        let today = Self.day.string(from: now)

        var records: [CloudRecord] = []

        // MARK: Briefing (Today headline)
        records.append(try record(.briefing, "1", now, [
            "id": 1,
            "user_id": "U_DEMO",
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
        records.append(try record(.calendarEvent, "evt-1", now, [
            "id": "evt-1",
            "title": "Daily Standup",
            "location": "Zoom",
            "start_time": Self.iso.string(from: now.addingTimeInterval(3600)),
            "end_time": Self.iso.string(from: now.addingTimeInterval(3600 + 900)),
            "event_status": "confirmed",
        ]))
        records.append(try record(.calendarEvent, "evt-2", now, [
            "id": "evt-2",
            "title": "Mobile app design review",
            "location": "Room 4B",
            "start_time": Self.iso.string(from: now.addingTimeInterval(3 * 3600)),
            "end_time": Self.iso.string(from: now.addingTimeInterval(4 * 3600)),
            "event_status": "tentative",
        ]))

        // MARK: Inbox items
        records.append(try record(.inboxItem, "1", now, [
            "id": 1,
            "channel_id": "C_DEMO",
            "message_ts": String(now.timeIntervalSince1970),
            "sender_user_id": "U_ALICE",
            "trigger_type": "mention",
            "snippet": "Can you review the launch checklist before Friday?",
            "status": "pending",
            "priority": "high",
            "item_class": "actionable",
            "created_at": Self.iso.string(from: now),
        ]))
        records.append(try record(.inboxItem, "2", now, [
            "id": 2,
            "channel_id": "D_DEMO",
            "message_ts": String(now.timeIntervalSince1970 - 300),
            "sender_user_id": "U_BOB",
            "trigger_type": "dm",
            "snippet": "Thanks for the update — I'll take it from here.",
            "status": "pending",
            "priority": "medium",
            "item_class": "actionable",
            "created_at": Self.iso.string(from: now),
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

        try await transport.save(records)
    }

    // MARK: - Helpers

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
