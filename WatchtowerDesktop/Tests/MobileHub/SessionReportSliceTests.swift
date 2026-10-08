import Foundation
import GRDB
import os
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The `session_report` projection (mobile POC spec §4.8): the per-session
/// CLI report, its caps, its window, its cadence and the phone's
/// `session_report_request`.
final class SessionReportSliceTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var sidecar: HubSyncState!

    override func setUpWithError() throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
        sidecar = try HubSyncState.inMemory()
    }

    override func tearDownWithError() throws {
        dbPool = nil
        sidecar = nil
        TestDatabase.cleanup(path: dbPath)
    }

    // MARK: - Helpers

    private func sessions(live: Set<Int64> = []) -> TerminalSessionSlice {
        let liveness = SessionLiveness(liveIDs: live, startedAt: Dictionary(uniqueKeysWithValues: live.map { ($0, Date()) }))
        return TerminalSessionSlice(liveness: { liveness }, reportSummary: { _, _ in nil })
    }

    private static func windowed(_ id: Int64, workbench: Int64 = 1, live: Bool) -> SessionReportSlice.Windowed {
        SessionReportSlice.Windowed(
            sessionID: id, workbenchID: workbench, live: live, createdAt: Date(), lastActiveAt: Date(),
            state: live ? .live(.working) : .init(kind: .stopped, live: false), stateAt: nil
        )
    }

    /// The CLI's JSON for a small report about `sessionID`.
    private static func cliJSON(_ sessionID: Int64, title: String = "Archive closed targets") -> Data {
        Data(#"""
        {"session":{"id":\#(sessionID),"title":"\#(title)","target_id":415,"kind":"claude","created_at":"2026-01-01T08:59:00Z",
        "last_active_at":"2026-01-01T10:06:00Z","agent_state":"stop","agent_state_at":"2026-01-01T10:06:00Z",
        "finished_at":"","finish_summary":""},"progress":{"done":1,"total":2},
        "on_you":[{"id":12,"kind":"question","title":"Which release?","target_id":415,"created_at":"2026-01-01T10:05:00Z"}],
        "now":[{"id":416,"text":"Header menu item","status":"in_progress","branch":"feature/acme-export","since":"2026-01-01T10:00:00Z"}],
        "next":[{"id":417,"text":"Undo Archive Now","status":"todo"}],
        "phases":[{"target_id":415,"text":"Archive Closed Targets Now","done":1,"total":2,"started_at":"2026-01-01T09:00:00Z",
        "finished_at":"","items":[{"id":416,"text":"Header menu item","status":"in_progress"}]}],
        "prs":[{"ref":"pr:175","pr_number":175,"title":"Archive Closed Targets Now","state":"open","additions":120,"deletions":8,
        "merged_at":"","checked_at":"2026-01-01T10:00:00Z","targets":[415]}],"pr_note":""}
        """#.utf8)
    }

    private static func report(_ sessionID: Int64) throws -> SessionReport {
        try JSONDecoder().decode(SessionReport.self, from: cliJSON(sessionID))
    }

    private func runner(
        fetch: @escaping SessionReportRunner.Fetch,
        clock: TestInstant,
        window: @escaping SessionReportRunner.Window
    ) -> SessionReportRunner {
        SessionReportRunner(fetch: fetch, sidecar: sidecar, clock: { clock.now }, window: window)
    }

    private static func keys(_ object: Any?) throws -> Set<String> {
        Set(try XCTUnwrap(object as? [String: Any]).keys)
    }

    // MARK: - Wire shape

    func testPayloadMatchesTheKitFixture() throws {
        let payload = try SliceJSON.object(try SessionReportSlice.encode(try Self.report(31)))
        let fixture = try SliceJSON.kitFixture("workbench/session_report.json")
        let more: Set<String> = ["on_you_more", "now_more", "next_more", "phases_more", "phases_clipped", "prs_more"]
        assertWireShape(payload, matches: fixture, optionalKeys: more)
        // The array elements, which assertWireShape does not descend into.
        for key in ["on_you", "now", "next", "phases", "prs"] {
            let element = try XCTUnwrap((payload[key] as? [[String: Any]])?.first, key)
            let expected = try XCTUnwrap((fixture[key] as? [[String: Any]])?.first, key)
            assertWireShape(element, matches: expected, optionalKeys: ["items_more", "target_id", "pr_number", "additions", "deletions"])
        }
        let phase = try XCTUnwrap((payload["phases"] as? [[String: Any]])?.first)
        let item = try XCTUnwrap((phase["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(item.keys), ["id", "text", "status"])
        XCTAssertNil(payload["phases_clipped"], "a report under the cap is not clipped")
        XCTAssertTrue(SliceJSON.allKeys(payload).isDisjoint(with: neverPublishedKeys))
    }

    func testListAndTextCapsSetTheMoreCounts() throws {
        var report = try Self.report(31)
        let long = String(repeating: "é", count: 600)
        report.session.title = long
        report.onYou = Array(repeating: report.onYou[0], count: 40)
        report.now = Array(repeating: report.now[0], count: 25)
        report.next = Array(repeating: .init(id: 1, text: long, status: "todo"), count: 25)
        report.phases = Array(
            repeating: .init(targetID: 1, text: "Phase", done: 0, total: 60, items: Array(repeating: report.next[0], count: 60)),
            count: 35
        )
        report.prs = Array(repeating: report.prs[0], count: 12)
        let payload = try SliceJSON.object(try SessionReportSlice.encode(report))

        XCTAssertEqual((payload["on_you"] as? [Any])?.count, 30)
        XCTAssertEqual(payload["on_you_more"] as? Int, 10)
        XCTAssertEqual((payload["now"] as? [Any])?.count, 20)
        XCTAssertEqual(payload["now_more"] as? Int, 5, "the phone counts in progress from the capped now")
        XCTAssertEqual((payload["next"] as? [Any])?.count, 20)
        XCTAssertEqual(payload["next_more"] as? Int, 5)
        XCTAssertEqual((payload["prs"] as? [Any])?.count, 10)
        XCTAssertEqual(payload["prs_more"] as? Int, 2)
        let phases = try XCTUnwrap(payload["phases"] as? [[String: Any]])
        XCTAssertLessThanOrEqual(phases.count, 30)
        XCTAssertEqual(phases.count + (payload["phases_more"] as? Int ?? 0), 35)
        let title = try XCTUnwrap((payload["session"] as? [String: Any])?["title"] as? String)
        XCTAssertEqual(title.count, 500)
        XCTAssertTrue(title.hasSuffix("…"))
        let nextText = try XCTUnwrap((payload["next"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertEqual(nextText.count, 500)
    }

    /// A 200 KiB report fits under 128 KiB by dropping the oldest phases'
    /// items first; the newest phase keeps all of its items.
    func testA200KiBReportIsCutUnder128KiBDroppingTheOldestPhaseItems() throws {
        var report = try Self.report(31)
        let text = String(repeating: "x", count: 480)
        // Board order is newest first, so "oldest" must come from started_at.
        report.phases = (0..<10).map { (index: Int) -> SessionReport.Phase in
            let items: [SessionReport.Item] = (0..<40).map { (item: Int) -> SessionReport.Item in
                SessionReport.Item(id: Int64(index * 100 + item), text: text, status: "todo")
            }
            let started = String(format: "2026-01-%02dT09:00:00Z", 20 - index)
            return SessionReport.Phase(
                targetID: Int64(100 + index), text: "Phase \(index)", done: 0, total: 40, startedAt: started, items: items
            )
        }
        let uncapped = try SessionReportSlice.encoder().encode(SessionReportSlice.capped(report))
        XCTAssertGreaterThan(uncapped.count, 200 * 1024 - 8 * 1024, "the fixture is about 200 KiB")

        let data = try SessionReportSlice.encode(report)
        XCTAssertLessThanOrEqual(data.count, 128 * 1024)
        let payload = try SliceJSON.object(data)
        XCTAssertEqual(payload["phases_clipped"] as? Bool, true)
        let phases = try XCTUnwrap(payload["phases"] as? [[String: Any]])
        XCTAssertEqual(phases.count, 10, "items go before whole phases")
        func items(_ number: Int) -> (kept: Int, more: Int) {
            let phase = phases[number]
            return ((phase["items"] as? [Any])?.count ?? 0, phase["items_more"] as? Int ?? 0)
        }
        XCTAssertEqual(items(9).kept, 0, "the oldest phase (started first, last on the board) lost its items")
        XCTAssertEqual(items(9).more, 40)
        XCTAssertEqual(items(0).kept, 40, "the newest phase is intact")
        XCTAssertNil(phases[0]["items_more"])
        for index in 0..<10 {
            XCTAssertEqual(items(index).kept + items(index).more, 40, "every dropped item is counted")
        }
    }

    // MARK: - Window

    func testOnlyLiveOrRecentSessionsHaveARecord() throws {
        let now = Date()
        let (old, recent, liveOld) = try dbPool.write { db -> (Int64, Int64, Int64) in
            let project = try TestDatabase.insertWorkbench(db)
            return (
                try SliceSeed.insertSession(db, projectID: project, lastActiveAt: now.addingTimeInterval(-8 * 86_400)),
                try SliceSeed.insertSession(db, projectID: project, lastActiveAt: now.addingTimeInterval(-86_400)),
                try SliceSeed.insertSession(db, projectID: project, lastActiveAt: now.addingTimeInterval(-9 * 86_400))
            )
        }
        for id in [old, recent, liveOld] {
            try sidecar.saveSessionReport(try SessionReportSlice.encode(try Self.report(id)), sessionID: id, at: now)
        }
        let slice = SessionReportSlice(sessions: sessions(live: [liveOld]), sidecar: sidecar) { now }
        let ids = try dbPool.read { try slice.records($0) }.map(\.recordName)

        XCTAssertEqual(Set(ids), ["session_report-\(recent)", "session_report-\(liveOld)"],
                       "a session active 8 days ago has no record; a live one always has")
    }

    // MARK: - Runner

    func testArgvMatchesTheCenterAndThePeriodicRunIsOfflineEvery120Seconds() async throws {
        let runner = FakeCLIRunner(stdout: Self.cliJSON(31))
        let clock = TestInstant()
        let reports = self.runner(fetch: SessionReportRunner.cliFetch(runner), clock: clock) { [Self.windowed(31, workbench: 7, live: true)] }
        let changes = OSAllocatedUnfairLock(initialState: 0)
        reports.setOnChange { changes.withLock { $0 += 1 } }

        await reports.runDue()
        XCTAssertEqual(runner.invocations, [
            ["workbench", "session-report", "--workbench", "7", "--session", "31", "--json", "--no-network"]
        ])
        XCTAssertEqual(changes.withLock { $0 }, 1)
        let stored = try XCTUnwrap(try sidecar.sessionReports()[31])
        XCTAssertEqual(try SessionReportSlice.decode(stored.payload).session.title, "Archive closed targets")

        clock.advance(by: .seconds(119))
        await reports.runDue()
        XCTAssertEqual(runner.invocations.count, 1, "not due before 120 s")
        clock.advance(by: .seconds(1))
        await reports.runDue()
        XCTAssertEqual(runner.invocations.count, 2, "due at 120 s")
        XCTAssertEqual(runner.invocations.last?.last, "--no-network")
        XCTAssertEqual(changes.withLock { $0 }, 1, "an unchanged report nudges nothing")
    }

    func testARequestTwiceWithin60SecondsRunsTheNetworkCLIOnce() async throws {
        let runner = FakeCLIRunner(stdout: Self.cliJSON(31))
        let clock = TestInstant()
        // Not live and already reported: only a request runs it.
        try sidecar.saveSessionReport(try SessionReportSlice.encode(try Self.report(31)), sessionID: 31, at: Date())
        let reports = self.runner(fetch: SessionReportRunner.cliFetch(runner), clock: clock) { [Self.windowed(31, workbench: 7, live: false)] }

        XCTAssertTrue(reports.requestReport(sessionID: 31))
        clock.advance(by: .seconds(30))
        XCTAssertFalse(reports.requestReport(sessionID: 31), "throttled inside 60 s")
        await reports.runDue()
        await reports.runDue()
        XCTAssertEqual(runner.invocations, [["workbench", "session-report", "--workbench", "7", "--session", "31", "--json"]],
                       "one run, with the network")

        clock.advance(by: .seconds(30))
        XCTAssertTrue(reports.requestReport(sessionID: 31), "accepted again 60 s after the last accepted one")
        await reports.runDue()
        XCTAssertEqual(runner.invocations.count, 2)
    }

    @MainActor
    func testTheRequestHandlerIsIdempotentAndRefusesAnUnknownSession() async throws {
        let session = try await dbPool.write { db in
            try SliceSeed.insertSession(db, projectID: try TestDatabase.insertWorkbench(db))
        }
        let runner = FakeCLIRunner(stdout: Self.cliJSON(session))
        let clock = TestInstant()
        let window = [Self.windowed(session, live: false)]
        try sidecar.saveSessionReport(try SessionReportSlice.encode(try Self.report(session)), sessionID: session, at: Date())
        let reports = self.runner(fetch: SessionReportRunner.cliFetch(runner), clock: clock) { window }
        let dispatcher = MobileHubCommandDispatcher()
        SessionReportRequestHandler(dbPool: dbPool, runner: reports).register(on: dispatcher)
        func action(_ entity: String?) -> ActionRequestPayload {
            ActionRequestPayload(id: UUID().uuidString, kind: .sessionReportRequest, entityID: entity, params: [:], createdAt: Date())
        }

        let first = try await dispatcher.dispatch(action(String(session)))
        let second = try await dispatcher.dispatch(action(String(session)))
        XCTAssertEqual(first, .applied())
        XCTAssertEqual(second, .applied(), "a second request inside 60 s is applied too")
        await reports.runDue()
        XCTAssertEqual(runner.invocations.count, 1, "and runs nothing more")
        XCTAssertFalse(runner.invocations[0].contains("--no-network"))

        let missing = try await dispatcher.dispatch(action("999999"))
        XCTAssertEqual(missing?.status, .failed)
        XCTAssertEqual(missing?.reason, .notFound)
        let invalid = try await dispatcher.dispatch(action(nil))
        XCTAssertEqual(invalid?.reason, .invalidParams)
    }

    func testAStateChangeRunsTheSessionCoalescedAfter5Seconds() async throws {
        let calls = OSAllocatedUnfairLock(initialState: [Bool]())
        let clock = TestInstant()
        let state = OSAllocatedUnfairLock(initialState: SessionSwitcherPresentation.State.live(.working))
        let reports = runner(
            fetch: { _, id, network in
                calls.withLock { $0.append(network) }
                return try Self.report(id)
            },
            clock: clock,
            window: { // swiftlint:disable:this trailing_closure
                let current = state.withLock { $0 }
                return [SessionReportSlice.Windowed(
                    sessionID: 31, workbenchID: 7, live: current.live, createdAt: Date(), lastActiveAt: Date(), state: current, stateAt: nil
                )]
            }
        )
        reports.sessionStatesChanged()
        await reports.runDue()
        XCTAssertEqual(calls.withLock { $0 }.count, 1, "the first run")

        state.withLock { $0 = .live(.needsApproval) }
        reports.sessionStatesChanged()
        clock.advance(by: .seconds(2))
        await reports.runDue()
        XCTAssertEqual(calls.withLock { $0 }.count, 1, "a change waits for the 5 s spacing")
        reports.sessionStatesChanged()
        clock.advance(by: .seconds(3))
        await reports.runDue()
        await reports.runDue()
        XCTAssertEqual(calls.withLock { $0 }, [false, false], "one offline run for the change")
    }

    func testAFailedRunKeepsTheStoredReportAndASessionLeavingTheWindowDropsIt() async throws {
        let failing = OSAllocatedUnfairLock(initialState: false)
        let listed = OSAllocatedUnfairLock(initialState: [Self.windowed(31, live: true)])
        let clock = TestInstant()
        let reports = runner(
            fetch: { _, id, _ in
                if failing.withLock({ $0 }) { throw CLIRunnerError.launchFailed(underlying: CancellationError()) }
                return try Self.report(id)
            },
            clock: clock,
            window: { listed.withLock { $0 } } // swiftlint:disable:this trailing_closure
        )
        await reports.runDue()
        let first = try XCTUnwrap(try sidecar.sessionReports()[31])

        failing.withLock { $0 = true }
        clock.advance(by: .seconds(120))
        let attempted = await reports.runDue()
        XCTAssertEqual(attempted, [31])
        XCTAssertEqual(try sidecar.sessionReports()[31], first, "a failure keeps the stored report")

        listed.withLock { $0 = [] }
        await reports.runDue()
        XCTAssertNil(try sidecar.sessionReports()[31], "a session that left the window loses its stored report")
    }

    func testAHungRunTimesOutAndStoresNothing() async throws {
        let reports = SessionReportRunner(
            fetch: { _, id, _ in
                try await Task.sleep(for: .seconds(30))
                return try Self.report(id)
            },
            sidecar: sidecar,
            timing: .init(
                every: .seconds(120), stateSpacing: .seconds(5), requestSpacing: .seconds(60), timeout: .milliseconds(50), wake: .seconds(5)
            ),
            window: { [Self.windowed(31, live: true)] } // swiftlint:disable:this trailing_closure
        )
        await reports.runDue()
        XCTAssertNil(try sidecar.sessionReports()[31])
    }
}
