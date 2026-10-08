import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Spec §14: orange appears only on waiting-for-you and ask elements. The
/// project has no snapshot library, so this runs at the tone level: every
/// screen model the demo seed produces lists each colour it draws
/// (`ToneUse`) with a role decided from its data, and the views paint only
/// model tones. SwiftLint's `orange_outside_phone_tone` keeps views and
/// models from naming orange anywhere but `PhoneTone.swift`.
final class OrangeToneTests: XCTestCase {
    func testOrangeOnlyOnWaitingAndAskElementsAcrossTheDemoScreens() throws {
        let now = Date()
        let snapshot = try demoSnapshot(now: now)
        var uses: [ToneUse] = NowModel(snapshot: snapshot, now: now).toneUses
        for workbench in snapshot.workbenches {
            uses += WorkbenchCardModel(workbench).toneUses
            uses += try XCTUnwrap(WorkbenchMenuModel(workbenchID: workbench.id, snapshot: snapshot, now: now)).toneUses
            for filter in BoardFilter.allCases {
                uses += BoardModel(workbenchID: workbench.id, snapshot: snapshot, filter: filter).toneUses
            }
        }
        for target in snapshot.targets {
            uses += try XCTUnwrap(BoardTargetDetailModel(targetID: target.id, snapshot: snapshot, now: now)).toneUses
        }
        for ask in snapshot.asks {
            uses += try XCTUnwrap(AskFormModel(
                askID: ask.id, snapshot: snapshot, draft: AskDraft(), page: 0, now: now, applied: nil, isSending: false
            )).toneUses
        }
        let details = DemoSeed.sessionDetailSlices(now: now)
        func payload(_ kind: SliceKind, _ id: Int64) -> [String: Any]? {
            details.first { $0.0 == kind && $0.1 == id }?.2
        }
        for session in snapshot.sessions {
            let report = try payload(.sessionReport, session.id).map { try mirror(SessionReport.self, $0) }
            let timeline = try payload(.sessionTimeline, session.id).map { try mirror(SessionTimeline.self, $0) }
            uses += try XCTUnwrap(SessionDetailModel(
                sessionID: session.id, snapshot: snapshot, report: report, timeline: timeline, now: now
            )).toneUses
        }

        let orange = uses.filter { $0.tone == .orange }
        XCTAssertFalse(orange.isEmpty, "the demo must draw orange somewhere, or this test proves nothing")
        for use in orange {
            XCTAssertTrue(use.isWaitingOrAsk, "orange on a non-waiting element: \(use.element)")
        }
        XCTAssertTrue(uses.contains { $0.tone != .orange }, "the demo draws other tones too")
    }

    /// A session's orange counts as waiting only when the record is in one
    /// of the orange states; a mislabelled record would fail the test above.
    func testASessionDotIsWaitingOnlyInTheOrangeStates() throws {
        let waiting = try mirror(TerminalSessionState.self, DemoSeed.JSON.session(1, workbench: 1, [
            "state_kind": "needs_approval", "state_tone": "orange"
        ]))
        XCTAssertTrue(SessionRowModel(waiting, now: Date()).toneUses.allSatisfy(\.isWaitingOrAsk))
        let mislabelled = try mirror(TerminalSessionState.self, DemoSeed.JSON.session(2, workbench: 1, [
            "state_kind": "working", "state_tone": "orange"
        ]))
        XCTAssertFalse(SessionRowModel(mislabelled, now: Date()).toneUses.contains { $0.tone == .orange && $0.isWaitingOrAsk })
    }

    /// The tones the phone computes from data (target status, priority, the
    /// Mac chip) are never orange, for every known value and an unknown one.
    func testDataDrivenTonesAreNeverOrange() throws {
        let statuses = WorkbenchTargetStatus.knownValues + [WorkbenchTargetStatus(rawValue: "newer")]
        for status in statuses {
            XCTAssertNotEqual(BoardRowModel.status(status).tone, .orange, "status \(status.rawValue)")
        }
        let priorities = WorkbenchTargetPriority.knownValues + [WorkbenchTargetPriority(rawValue: "newer")]
        for priority in priorities {
            let target = try mirror(WorkbenchTarget.self, DemoSeed.JSON.target(1, workbench: 1, ["priority": priority.rawValue]))
            let row = BoardRowModel(target, snapshot: WorkbenchReplicaSnapshot())
            XCTAssertTrue(row.toneUses.allSatisfy { $0.tone != .orange }, "priority \(priority.rawValue)")
        }
        var snapshot = WorkbenchReplicaSnapshot()
        let now = Date()
        XCTAssertNotEqual(NowModel(snapshot: snapshot, now: now).macChipTone, .orange)
        snapshot.heartbeat = HeartbeatPayload(
            updatedAt: now, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
            lastPublishAt: now, lastRelayAt: now, relayBacklog: 0, accounts: [],
            enabledAt: now, ownerUser: "_user", sharing: .none
        )
        XCTAssertNotEqual(NowModel(snapshot: snapshot, now: now).macChipTone, .orange)
        XCTAssertNotEqual(NowModel(snapshot: snapshot, now: now.addingTimeInterval(800)).macChipTone, .orange)
    }

    /// The calendar draws red (recording), purple (the Mac transcribing),
    /// green and the accent; never orange (spec §14).
    @MainActor
    func testTheCalendarScreensNeverDrawOrange() async throws {
        let now = Date()
        let store = try makePoolStore()
        let transport = InMemoryCloudTransport()
        try await DemoSeed.load(into: transport, now: now)
        let uploader = RecordingUploader(transport: transport, store: store, deviceID: DemoSeed.device.deviceID)
        try await DemoSeed.loadRecordingDemo(uploader: uploader, store: store, transport: transport, now: now)
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
        let calendar = try await store.reader.read { db in try CalendarReplicaSnapshot.read(from: db, store: store) }
        let recordings = try await store.reader.read { db in try PhoneRecordingsSnapshot.read(from: db, store: store) }

        var uses: [ToneUse] = NextMeetingCardModel(events: calendar.events, now: now, calendar: .current)?.toneUses ?? []
        for offset in -1...1 {
            let day = Calendar.current.date(byAdding: .day, value: offset, to: now) ?? now
            uses += AgendaDayModel(day: day, snapshot: calendar, recordings: recordings, now: now, calendar: .current)
                .cards.flatMap(\.toneUses)
        }
        for event in calendar.events {
            uses += try XCTUnwrap(EventDetailModel(
                eventID: event.id, snapshot: calendar, recordings: recordings, now: now, calendar: .current
            )).toneUses
        }
        XCTAssertTrue(uses.contains { $0.tone == .purple }, "the demo shows a recording the Mac is transcribing")
        XCTAssertTrue(uses.contains { $0.tone == .red && $0.role == .recording })
        XCTAssertFalse(uses.contains { $0.tone == .orange })
    }
}
