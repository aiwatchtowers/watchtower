import GRDB
import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerKit
import WatchtowerTestSupport
import WatchtowerCore

final class SlicePublisherTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var state: HubSyncState!
    private var transport: InMemoryCloudTransport!
    private var publisher: SlicePublisher!

    override func setUpWithError() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        dbPath = path
        dbPool = manager.dbPool
        state = try HubSyncState.inMemory()
        transport = InMemoryCloudTransport()
        publisher = SlicePublisher(dbPool: dbPool, state: state, transport: transport)
    }

    override func tearDownWithError() throws {
        publisher = nil
        transport = nil
        state = nil
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    func testPublishOncePushesFixtureRows() async throws {
        // Guard: every SliceKind must have a window — a kind missing from
        // sliceSQL would silently never sync.
        XCTAssertEqual(Set(SlicePublisher.sliceSQL.keys), Set(SliceKind.allCases))

        try await dbPool.write { db in
            try TestDatabase.insertTarget(db, text: "Ship slice publisher")
            try TestDatabase.insertTarget(db, text: "Write the tests")
            try TestDatabase.insertInboxItem(db)
        }

        let result = try await publisher.publishOnce()

        XCTAssertEqual(result.pushed, 3)
        XCTAssertEqual(result.deleted, 0)
        XCTAssertTrue(result.skipped.isEmpty)

        let batch = try await transport.changes(in: .data, since: nil)
        XCTAssertEqual(
            Set(batch.changed.map(\.recordName)),
            ["target-1", "target-2", "inbox_item-1"]
        )
        XCTAssertTrue(batch.deletedRecordNames.isEmpty)
    }

    // MARK: - Day plan

    /// Today's plan (and only today's) reaches the phone: yesterday's plan
    /// falling out of the window is exactly what removes it there. Dates are
    /// seeded RELATIVE to now in the LOCAL zone — the publisher's window uses
    /// `date('now','localtime')`, matching `DayPlanQueries.todayDateString()`.
    func testDayPlanSlicePublishesTodayOnly() async throws {
        let today = Self.localDayString(daysFromNow: 0)
        let yesterday = Self.localDayString(daysFromNow: -1)
        try await dbPool.write { db in
            let oldPlan = try TestDatabase.insertDayPlan(db, planDate: yesterday)
            _ = try TestDatabase.insertDayPlanItem(db, dayPlanID: oldPlan, title: "yesterday's block")
            let todayPlan = try TestDatabase.insertDayPlan(
                db, planDate: today, hasConflicts: true, conflictSummary: "two blocks overlap at 14:00"
            )
            _ = try TestDatabase.insertDayPlanItem(
                db, dayPlanID: todayPlan, title: "Deep work",
                startTime: "\(today)T09:30:00Z", endTime: "\(today)T11:00:00Z"
            )
            _ = try TestDatabase.insertDayPlanItem(
                db, dayPlanID: todayPlan, kind: "backlog", title: "Answer in #ops", orderIndex: 1
            )
        }

        _ = try await publisher.publishOnce()

        let batch = try await transport.changes(in: .data, since: nil)
        let planNames = batch.changed.map(\.recordName).filter { $0.hasPrefix("day_plan") }
        XCTAssertEqual(Set(planNames), ["day_plan-2", "day_plan_item-2", "day_plan_item-3"])

        let plan = try await publishedRow(named: "day_plan-2")
        XCTAssertEqual(plan["plan_date"] as String?, today)
        XCTAssertEqual(plan["has_conflicts"] as Int?, 1)
        XCTAssertEqual(plan["conflict_summary"] as String?, "two blocks overlap at 14:00")

        let block = try await publishedRow(named: "day_plan_item-2")
        XCTAssertEqual(block["title"] as String?, "Deep work")
        XCTAssertEqual(block["kind"] as String?, "timeblock")
    }

    /// `yyyy-MM-dd` for `now + days` in the LOCAL zone (never a hardcoded
    /// date — see the project's no-date-bombs rule).
    private static func localDayString(daysFromNow days: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    func testSecondPublishWithNoDBChangePushesNothing() async throws {
        try await dbPool.write { db in
            try TestDatabase.insertTarget(db)
            try TestDatabase.insertInboxItem(db)
        }
        let first = try await publisher.publishOnce()
        XCTAssertEqual(first.pushed, 2)
        let token = try await transport.changes(in: .data, since: nil).newToken

        let second = try await publisher.publishOnce()

        XCTAssertEqual(second.pushed, 0)
        XCTAssertEqual(second.deleted, 0)
        XCTAssertTrue(second.skipped.isEmpty)
        let delta = try await transport.changes(in: .data, since: token)
        XCTAssertTrue(delta.changed.isEmpty)
        XCTAssertTrue(delta.deletedRecordNames.isEmpty)
    }

    func testDeletedRowEmitsTransportDeleteAndDropsHash() async throws {
        let doomedID = try await dbPool.write { db in
            let id = try TestDatabase.insertTarget(db, text: "Soon gone")
            _ = try TestDatabase.insertTarget(db, text: "Stays")
            return id
        }
        _ = try await publisher.publishOnce()
        let token = try await transport.changes(in: .data, since: nil).newToken

        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM targets WHERE id = ?", arguments: [doomedID])
        }
        let result = try await publisher.publishOnce()

        XCTAssertEqual(result.pushed, 0)
        XCTAssertEqual(result.deleted, 1)
        let delta = try await transport.changes(in: .data, since: token)
        XCTAssertEqual(delta.deletedRecordNames, ["target-\(doomedID)"])
        XCTAssertTrue(delta.changed.isEmpty)
        XCTAssertNil(try state.hashes(forKind: .target)["target-\(doomedID)"])
    }

    func testUpdatedRowIsRepushedExactly() async throws {
        let updatedID = try await dbPool.write { db in
            let id = try TestDatabase.insertTarget(db, text: "Old text")
            _ = try TestDatabase.insertTarget(db, text: "Untouched")
            try TestDatabase.insertInboxItem(db)
            return id
        }
        _ = try await publisher.publishOnce()
        let token = try await transport.changes(in: .data, since: nil).newToken

        try await dbPool.write { db in
            try db.execute(sql: "UPDATE targets SET text = 'New text' WHERE id = ?", arguments: [updatedID])
        }
        let result = try await publisher.publishOnce()

        XCTAssertEqual(result.pushed, 1)
        XCTAssertEqual(result.deleted, 0)
        let delta = try await transport.changes(in: .data, since: token)
        XCTAssertEqual(delta.changed.map(\.recordName), ["target-\(updatedID)"])
        XCTAssertTrue(delta.deletedRecordNames.isEmpty)
    }

    /// Fix 4 regression: a mid-cycle wipeSyncState must cause publishOnce to abort
    /// before recording hashes for the new account, so the next cycle re-pushes all records.
    func testWipeBetweenCyclesTriggersFullRepushOnNextCycle() async throws {
        try await dbPool.write { db in
            try TestDatabase.insertTarget(db, text: "Alpha")
            try TestDatabase.insertTarget(db, text: "Beta")
        }

        // First cycle: hashes recorded, records pushed.
        let first = try await publisher.publishOnce()
        XCTAssertEqual(first.pushed, 2)

        // Simulate account reset: wipe bumps generation.
        let genBefore = try state.generation()
        try state.wipeSyncState()
        let genAfter = try state.generation()
        XCTAssertGreaterThan(genAfter, genBefore, "wipeSyncState must bump generation")

        // After wipe, hashes are gone — next publishOnce sees all records as new.
        let second = try await publisher.publishOnce()
        XCTAssertEqual(second.pushed, 2, "after wipeSyncState, all records must be re-pushed")
    }

    /// In-flight abort: a transport whose save() calls wipeSyncState() before
    /// delegating simulates a mid-cycle account reset happening concurrently
    /// with the first save. publishOnce must abort, record NO hashes for the
    /// wiped generation, and the NEXT publishOnce must re-push everything.
    func testInFlightWipeAbortsAndNextCycleRepushes() async throws {
        final class WipingTransport: CloudSyncTransport, Sendable {
            private let inner: InMemoryCloudTransport
            private let state: HubSyncState
            init(inner: InMemoryCloudTransport, state: HubSyncState) {
                self.inner = inner
                self.state = state
            }
            func save(_ records: [CloudRecord]) async throws {
                try state.wipeSyncState()   // wipe BEFORE delegating — bumps generation
                try await inner.save(records)
            }
            func delete(recordNames: [String], in zone: CloudZoneID) async throws {
                try await inner.delete(recordNames: recordNames, in: zone)
            }
            func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
                try await inner.changes(in: zone, since: token)
            }
        }

        try await dbPool.write { db in
            try TestDatabase.insertTarget(db, text: "Alpha")
            try TestDatabase.insertTarget(db, text: "Beta")
        }

        let wipingTransport = WipingTransport(inner: transport, state: state)
        let wipingPublisher = SlicePublisher(dbPool: dbPool, state: state, transport: wipingTransport)

        // First publishOnce — save() triggers wipeSyncState, bumping generation mid-cycle.
        let aborted = try await wipingPublisher.publishOnce()
        // Abort fires after the FIRST save (targets), so pushed is 0 because
        // the generation check fires before hashes are committed.
        XCTAssertEqual(aborted.pushed + aborted.deleted, 0,
                       "aborted cycle must not commit any pushed/deleted counts")

        // No hashes recorded for the wiped generation.
        let hashesAfterAbort = try state.hashes(forKind: .target)
        XCTAssertTrue(hashesAfterAbort.isEmpty, "aborted cycle must not record hashes")

        // Next cycle uses a clean transport (no mid-cycle wipe) — must re-push everything.
        let cleanPublisher = SlicePublisher(dbPool: dbPool, state: state, transport: transport)
        let repushed = try await cleanPublisher.publishOnce()
        XCTAssertEqual(repushed.pushed, 2, "after abort, next cycle must re-push all records")
    }

    // Exercises the two calendar_events-specific paths in publishOnce:
    //   1. rowID(.string) — calendar_events.id is TEXT PRIMARY KEY
    //   2. datetime(start_time) window — only events within −1d..+14d from now
    // Note: insertCalendarEvent's DEFAULT startTime is in 2023 — outside the
    // publish window — so events inserted with defaults never sync (pushed == 0);
    // always pass explicit run-time-relative timestamps here.
    func testCalendarEventTextIdAndDatetimeWindow() async throws {
        let inWindowID  = "cal_future_001"
        let outWindowID = "cal_past_030"

        // Computed from Date() so the test never rots against the SQL's live
        // datetime('now'). ISO8601DateFormatter emits the schema's required
        // 'T'-separated format with a 'Z' suffix.
        let iso = ISO8601DateFormatter()
        // +8h — inside the −1d..+14d window
        let inWindowStart = iso.string(from: Date().addingTimeInterval(8 * 3600))
        let inWindowEnd   = iso.string(from: Date().addingTimeInterval(9 * 3600))
        // −30d — outside the window
        let outWindowStart = iso.string(from: Date().addingTimeInterval(-30 * 24 * 3600))
        let outWindowEnd   = iso.string(from: Date().addingTimeInterval(-30 * 24 * 3600 + 3600))

        try await dbPool.write { db in
            try TestDatabase.insertCalendarEvent(
                db,
                id: inWindowID,
                startTime: inWindowStart,
                endTime: inWindowEnd
            )
            try TestDatabase.insertCalendarEvent(
                db,
                id: outWindowID,
                startTime: outWindowStart,
                endTime: outWindowEnd
            )
        }

        let result = try await publisher.publishOnce()
        XCTAssertEqual(result.pushed, 1, "only the in-window event should be pushed")
        XCTAssertEqual(result.deleted, 0)
        XCTAssertTrue(result.skipped.isEmpty)

        let batch = try await transport.changes(in: .data, since: nil)
        let names = Set(batch.changed.map(\.recordName))
        XCTAssertTrue(
            names.contains("calendar_event-\(inWindowID)"),
            "in-window event must appear as calendar_event-\(inWindowID) (TEXT id branch)"
        )
        XCTAssertFalse(
            names.contains("calendar_event-\(outWindowID)"),
            "out-of-window event must be excluded by the datetime() filter"
        )
    }

    // MARK: - notifyLevel tagging (Plan 6 Decision 3)

    /// Today's local date string, matching Go's briefings.date
    /// (`time.Now().Format("2006-01-02")` — local time zone).
    private func todayString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: Date())
    }

    private func publishedRecord(named name: String) async throws -> CloudRecord? {
        try await transport.changes(in: .data, since: nil).changed.first { $0.recordName == name }
    }

    func testHighPendingInboxItemPublishesUrgentOthersNil() async throws {
        try await dbPool.write { db in
            try TestDatabase.insertInboxItem(db, messageTS: "1700000000.000101", status: "pending", priority: "high")
            try TestDatabase.insertInboxItem(db, messageTS: "1700000000.000102", status: "resolved", priority: "high")
            try TestDatabase.insertInboxItem(db, messageTS: "1700000000.000103", status: "pending", priority: "medium")
            try TestDatabase.insertTarget(db, text: "never tagged")
        }

        _ = try await publisher.publishOnce()

        let urgent = try await publishedRecord(named: "inbox_item-1")
        XCTAssertEqual(urgent?.notifyLevel, "urgent")
        let resolved = try await publishedRecord(named: "inbox_item-2")
        XCTAssertNil(resolved?.notifyLevel)
        XCTAssertNotNil(resolved, "resolved item still syncs, just untagged")
        let medium = try await publishedRecord(named: "inbox_item-3")
        XCTAssertNil(medium?.notifyLevel)
        let target = try await publishedRecord(named: "target-1")
        XCTAssertNil(target?.notifyLevel)
    }

    func testBriefingFirstPublishTagsAndContentRepublishDoesNot() async throws {
        try await dbPool.write { db in
            try TestDatabase.insertBriefing(db, date: self.todayString())
        }

        // First publish: the record is new to the sidecar → tagged.
        _ = try await publisher.publishOnce()
        let first = try await publishedRecord(named: "briefing-1")
        XCTAssertEqual(first?.notifyLevel, "briefing")

        // Content change → hash-changed republish of the SAME record → nil.
        try await dbPool.write { db in
            try db.execute(sql: "UPDATE briefings SET role = 'manager' WHERE id = 1")
        }
        let token = try await transport.changes(in: .data, since: nil).newToken
        let second = try await publisher.publishOnce()
        XCTAssertEqual(second.pushed, 1)
        let repushed = try await transport.changes(in: .data, since: token).changed
        XCTAssertEqual(repushed.map(\.recordName), ["briefing-1"])
        XCTAssertNil(repushed[0].notifyLevel, "republish of a known briefing must not re-carry the tag")
    }

    /// An old briefing hitting the sidecar for the first time (initial full
    /// sync / backfill) is new-to-sidecar but NOT today's — never tagged.
    func testOldBriefingFirstPublishIsNotTagged() async throws {
        try await dbPool.write { db in
            try TestDatabase.insertBriefing(db, date: "2000-01-01")
        }
        _ = try await publisher.publishOnce()
        let record = try await publishedRecord(named: "briefing-1")
        XCTAssertNotNil(record)
        XCTAssertNil(record?.notifyLevel)
    }

    /// Account reset wipes the sidecar hash state; on the next cycle today's
    /// briefing IS new to the fresh zone, so it re-carries "briefing" —
    /// intended: the new zone's replica has never alerted for it.
    func testAccountResetRetagsTodaysBriefingOnRepush() async throws {
        try await dbPool.write { db in
            try TestDatabase.insertBriefing(db, date: self.todayString())
        }
        _ = try await publisher.publishOnce()

        try state.wipeSyncState()
        let token = try await transport.changes(in: .data, since: nil).newToken
        let repush = try await publisher.publishOnce()
        XCTAssertEqual(repush.pushed, 1)
        let records = try await transport.changes(in: .data, since: token).changed
        XCTAssertEqual(records.map(\.notifyLevel), ["briefing"])
    }

    // MARK: - Situation slice

    /// Open situations publish with the member inbox-item ids joined in as a
    /// `signal_ids` JSON array — the phone renders member signals from its
    /// own inbox slice, so the join table itself never syncs. Non-open
    /// situations stay out of the window entirely.
    func testSituationSliceEmbedsSignalIDsAndSkipsClosed() async throws {
        try await dbPool.write { db in
            let itemA = try TestDatabase.insertInboxItem(db)
            let itemB = try TestDatabase.insertInboxItem(db, messageTS: "1700000000.000200")
            let open = try TestDatabase.insertSituation(db, title: "Open story")
            try TestDatabase.linkSituationSignal(db, situationID: open, inboxItemID: itemA)
            try TestDatabase.linkSituationSignal(db, situationID: open, inboxItemID: itemB)
            _ = try TestDatabase.insertSituation(db, title: "Closed story", status: "done")
        }

        _ = try await publisher.publishOnce()

        let batch = try await transport.changes(in: .data, since: nil)
        let situationRecords = batch.changed.filter { $0.kind == SliceKind.situation.rawValue }
        XCTAssertEqual(situationRecords.map(\.recordName), ["situation-1"])

        let row = try RowPayloadCoder.row(from: try XCTUnwrap(situationRecords.first).payload)
        XCTAssertEqual(row["title"], "Open story")
        XCTAssertEqual(row["signal_ids"], "[1,2]")
    }

    /// Closing a situation on the desktop drops it from the slice window, so
    /// the next cycle deletes its record — the phone's row disappears instead
    /// of going stale.
    func testClosedSituationIsDeletedFromSlice() async throws {
        try await dbPool.write { db in
            _ = try TestDatabase.insertSituation(db)
        }
        _ = try await publisher.publishOnce()

        try await dbPool.write { db in
            try SituationQueries.done(db, id: 1)
        }
        let second = try await publisher.publishOnce()

        XCTAssertEqual(second.deleted, 1)
        let batch = try await transport.changes(in: .data, since: nil)
        XCTAssertTrue(batch.deletedRecordNames.contains("situation-1"))
    }

    // MARK: - Meeting-transcript slice (the one PROJECTION)

    private func publishedRow(named name: String) async throws -> Row {
        let record = try await publishedRecord(named: name)
        let unwrapped = try XCTUnwrap(record, "no published record named \(name)")
        return try RowPayloadCoder.row(from: unwrapped.payload)
    }

    /// The heavy and Mac-only columns must never reach the wire: a one-hour
    /// meeting's `transcript_text`/`segments_json` would dominate the record,
    /// `audio_path` is a path on this Mac, and `speakers_json` is 256-float
    /// voice embeddings per cluster — only the labels go out.
    func testMeetingTranscriptSlicePublishesProjectionNotTheRow() async throws {
        let longText = String(repeating: "ab", count: 500)  // 1000 chars
        try await dbPool.write { db in
            try TestDatabase.insertMeetingTranscript(
                db, id: 1, title: "Weekly sync",
                audioPath: "/Users/someone/Library/.../rec_1.caf",
                transcriptText: longText,
                notesMD: "# Notes",
                segmentsJSON: #"[{"idx":0,"start_sec":0,"end_sec":1,"speaker":"Я","text":"hi","deleted":false}]"#,
                speakersJSON: #"[{"speaker":"Я","embedding":[0.1,0.2]},{"speaker":"Speaker 2","embedding":[0.3]}]"#,
                chaptersJSON: #"{"overall_summary":"one topic","chapters":[]}"#)
        }

        _ = try await publisher.publishOnce()
        let row = try await publishedRow(named: "meeting_transcript-1")

        for excluded in ["transcript_text", "segments_json", "audio_path", "speakers_json", "summary_json"] {
            XCTAssertFalse(row.hasColumn(excluded), "\(excluded) must not be published")
        }
        XCTAssertEqual(row["snippet"] as String?, String(longText.prefix(200)))
        XCTAssertEqual(row["title"] as String?, "Weekly sync")
        XCTAssertEqual(row["duration_sec"] as Int?, 60)
        XCTAssertEqual(row["notes_md"] as String?, "# Notes")
        XCTAssertEqual(row["lang_stats"] as String?, "")
        XCTAssertEqual(row["chapters_json"] as String?, #"{"overall_summary":"one topic","chapters":[]}"#)
        // The roster, not the embeddings.
        XCTAssertEqual(row["speakers"] as String?, #"["Я","Speaker 2"]"#)
        // Ad-hoc recording: no event to join.
        XCTAssertTrue((row["event_id"] as DatabaseValue?)?.isNull ?? false)
        XCTAssertTrue((row["event_title"] as DatabaseValue?)?.isNull ?? false)
    }

    /// An un-diarized recording (speakers_json NULL) publishes an empty roster
    /// rather than failing the whole cycle on `json_each(NULL)`.
    func testMeetingTranscriptWithoutSpeakersPublishesEmptyRoster() async throws {
        try await dbPool.write { db in
            try TestDatabase.insertMeetingTranscript(db, id: 1, speakersJSON: nil)
        }
        _ = try await publisher.publishOnce()
        let row = try await publishedRow(named: "meeting_transcript-1")
        XCTAssertEqual(row["speakers"] as String?, "[]")
    }

    /// The desktop's recap rule (RecordingDetailView.load: the event's
    /// meeting_recaps row wins, the recording's own summary_json is the
    /// fallback) is resolved in SQL so the phone never has to re-derive it.
    func testMeetingTranscriptRecapResolutionMirrorsTheDesktopRule() async throws {
        let eventRecap = #"{"summary":"from the event","key_decisions":[],"action_items":[],"open_questions":[]}"#
        let ownRecap = #"{"summary":"from the recording","key_decisions":[],"action_items":[],"open_questions":[]}"#
        try await dbPool.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt-1", title: "Design review")
            try TestDatabase.insertMeetingRecap(db, eventID: "evt-1", recapJSON: eventRecap)
            // 1: both exist — the event's recap wins (the collision guard puts
            // the recording's own recap in summary_json in exactly this case).
            try TestDatabase.insertMeetingTranscript(db, id: 1, eventID: "evt-1", summaryJSON: ownRecap)
            // 2: ad-hoc — only its own recap exists.
            try TestDatabase.insertMeetingTranscript(db, id: 2, summaryJSON: ownRecap)
            // 3: event-linked but that event has no recap row — own recap again.
            try TestDatabase.insertCalendarEvent(db, id: "evt-2", title: "Retro")
            try TestDatabase.insertMeetingTranscript(db, id: 3, eventID: "evt-2", summaryJSON: ownRecap)
            // 4: no recap at all.
            try TestDatabase.insertMeetingTranscript(db, id: 4)
        }

        _ = try await publisher.publishOnce()

        let both = try await publishedRow(named: "meeting_transcript-1")
        XCTAssertEqual(both["recap_json"] as String?, eventRecap)
        XCTAssertEqual(both["event_title"] as String?, "Design review", "the linked event's title joins in")
        let adHoc = try await publishedRow(named: "meeting_transcript-2")
        XCTAssertEqual(adHoc["recap_json"] as String?, ownRecap)
        let eventWithoutRecap = try await publishedRow(named: "meeting_transcript-3")
        XCTAssertEqual(eventWithoutRecap["recap_json"] as String?, ownRecap)
        let none = try await publishedRow(named: "meeting_transcript-4")
        XCTAssertTrue((none["recap_json"] as DatabaseValue?)?.isNull ?? false)
    }

    /// Deleting a recording is a hard DELETE (MeetingTranscriptQueries.delete),
    /// so there is no soft-delete filter in the window: the row simply leaves
    /// the slice and the diff removes it from the phone.
    func testDeletedRecordingIsDeletedFromSlice() async throws {
        try await dbPool.write { db in
            try TestDatabase.insertMeetingTranscript(db, id: 1)
        }
        _ = try await publisher.publishOnce()

        // Plain SQL, not MeetingTranscriptQueries.delete: that path also clears
        // the recording's meeting chat, and `chat_conversations` is one of the
        // tables TestDatabase's schema does not carry. What the publisher sees
        // either way is a row that left the window.
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM meeting_transcripts WHERE id = 1")
        }
        let second = try await publisher.publishOnce()

        XCTAssertEqual(second.deleted, 1)
        let batch = try await transport.changes(in: .data, since: nil)
        XCTAssertTrue(batch.deletedRecordNames.contains("meeting_transcript-1"))
    }

    // MARK: - Payload size guard (plan item 14)

    /// Text long enough that the row's RowPayloadCoder JSON exceeds
    /// `SlicePublisher.maxPayloadBytes` — JSON framing only ever ADDS bytes
    /// on top of the raw text, so text of threshold+1 chars is sufficient.
    private static func oversizedText(filler: String = "x") -> String {
        String(repeating: filler, count: SlicePublisher.maxPayloadBytes + 1)
    }

    /// An oversized row must be skipped WITHOUT recording its hash (so the
    /// diff keeps re-offering it), it must never reach the transport, and a
    /// sibling normal row in the same cycle publishes untouched. Once the row
    /// shrinks below the threshold, the very next cycle publishes it normally.
    func testOversizedRowIsSkippedWithoutHashAndPublishesAfterShrinking() async throws {
        let hugeID = try await dbPool.write { db in
            let id = try TestDatabase.insertTarget(db, text: Self.oversizedText())
            _ = try TestDatabase.insertTarget(db, text: "Normal sibling")
            return id
        }

        let first = try await publisher.publishOnce()

        XCTAssertEqual(first.pushed, 1, "only the normal sibling publishes")
        XCTAssertEqual(first.deleted, 0)
        XCTAssertEqual(first.skipped, ["target-\(hugeID)"])
        let batch = try await transport.changes(in: .data, since: nil)
        XCTAssertEqual(batch.changed.map(\.recordName), ["target-2"])
        XCTAssertNil(
            try state.hashes(forKind: .target)["target-\(hugeID)"],
            "oversized row must not get its hash recorded — the diff would believe it published"
        )

        // Shrink the row: the next cycle must publish it like any new row.
        try await dbPool.write { db in
            try db.execute(sql: "UPDATE targets SET text = 'Now small' WHERE id = ?", arguments: [hugeID])
        }
        let token = batch.newToken
        let second = try await publisher.publishOnce()

        XCTAssertEqual(second.pushed, 1)
        XCTAssertTrue(second.skipped.isEmpty)
        let delta = try await transport.changes(in: .data, since: token)
        XCTAssertEqual(delta.changed.map(\.recordName), ["target-\(hugeID)"])
        XCTAssertNotNil(try state.hashes(forKind: .target)["target-\(hugeID)"])
    }

    /// A stuck oversized row is skipped EVERY cycle (the stat keeps counting)
    /// but warned about only ONCE — until its payload changes, which is a new
    /// situation worth a fresh warning.
    func testOversizedWarningIsThrottledPerPayloadHash() async throws {
        let hugeID = try await dbPool.write { db in
            try TestDatabase.insertTarget(db, text: Self.oversizedText())
        }

        let first = try await publisher.publishOnce()
        let second = try await publisher.publishOnce()

        XCTAssertEqual(first.skipped, ["target-\(hugeID)"])
        XCTAssertEqual(second.skipped, ["target-\(hugeID)"], "still skipped every cycle")
        XCTAssertEqual(
            publisher.oversizedWarningCount.withLock { $0 }, 1,
            "the same stuck payload must warn exactly once"
        )

        // Same row, still oversized, but DIFFERENT content → new warning.
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE targets SET text = ? WHERE id = ?",
                arguments: [Self.oversizedText(filler: "y"), hugeID]
            )
        }
        let third = try await publisher.publishOnce()
        XCTAssertEqual(third.skipped, ["target-\(hugeID)"])
        XCTAssertEqual(publisher.oversizedWarningCount.withLock { $0 }, 2)
    }

    /// Boundary discipline: a payload of exactly `maxPayloadBytes` still fits
    /// (the headroom below CloudKit's 1 MB cap absorbs record overhead); one
    /// byte more does not.
    func testPayloadSizeBoundary() {
        XCTAssertFalse(SlicePublisher.isOversized(Data(count: SlicePublisher.maxPayloadBytes)))
        XCTAssertTrue(SlicePublisher.isOversized(Data(count: SlicePublisher.maxPayloadBytes + 1)))
        XCTAssertFalse(SlicePublisher.isOversized(Data()), "empty payload is degenerate but fine")
    }
}
