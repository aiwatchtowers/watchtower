import Foundation
import GRDB
import os
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The `terminal_session` projection (mobile POC spec §4.5): the Mac's
/// resolved state presentation, the session window, and the report summary
/// fields from `workbench session-report --summary --json`.
final class TerminalSessionSliceTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    /// The slice's clock: the background agent count (#411) is judged at it.
    private let now = Date()
    private var started: Date { now.addingTimeInterval(-600) }

    override func setUpWithError() throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
    }

    override func tearDownWithError() throws {
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    private func slice(
        live: Set<Int64> = [],
        at clock: Date? = nil,
        summary: @escaping @Sendable (Int64, Int64) -> SessionReportSummary? = { _, _ in nil }
    ) -> TerminalSessionSlice {
        let liveness = SessionLiveness(liveIDs: live, startedAt: Dictionary(uniqueKeysWithValues: live.map { ($0, started) }))
        let now = clock ?? self.now
        let sliceClock: @Sendable () -> Date = { now }
        return TerminalSessionSlice(liveness: { liveness }, reportSummary: summary, now: sliceClock)
    }

    private func payloads(_ source: TerminalSessionSlice) throws -> [Int64: [String: Any]] {
        let objects = try SliceJSON.objects(try dbPool.read { try source.records($0) })
        var byID: [Int64: [String: Any]] = [:]
        for object in objects { byID[try XCTUnwrap(object["id"] as? Int64)] = object }
        return byID
    }

    /// An `agent_state_at` stamp `offset` seconds after the run started, in
    /// Go's format (UTC, milliseconds).
    private func stamp(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: started.addingTimeInterval(offset))
    }

    private func setState(
        _ db: Database,
        _ id: Int64,
        state: String?,
        at offset: TimeInterval = 1,
        finished: Bool = false,
        failedError: String? = nil,
        background: Int? = nil,
        backgroundAt backgroundOffset: TimeInterval? = nil
    ) throws {
        let at = stamp(offset)
        try db.execute(
            sql: """
                UPDATE terminal_sessions SET agent_state = ?, agent_state_at = ?, finished_at = ?,
                    agent_failed_at = ?, agent_error = ?, agent_background = ?, agent_background_at = ? WHERE id = ?
                """,
            arguments: [state, state == nil ? nil : at, finished ? at : nil, failedError == nil ? nil : at, failedError ?? "",
                        background, background == nil ? nil : stamp(backgroundOffset ?? offset), id]
        )
    }

    // MARK: - Wire shape

    func testPayloadMatchesTheKitFixtureAndHidesTheRawColumns() throws {
        let (session, target) = try dbPool.write { db -> (Int64, Int64) in
            let project = try TestDatabase.insertWorkbench(db)
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: project)
            let session = try SliceSeed.insertSession(db, projectID: project, targetID: target)
            try TestDatabase.insertOwnerAsk(db, projectID: project, sessionID: session)
            try TestDatabase.insertOwnerAsk(db, projectID: project, sessionID: session, status: "answered", answer: "Yes")
            return (session, target)
        }
        let summary = SessionReportSummary(sessionID: session, targetID: target, done: 1, total: 2, prLine: "PR #175 open")
        let payload = try XCTUnwrap(try payloads(slice(live: [session]) { _, id in id == session ? summary : nil })[session])

        assertWireShape(
            payload, matches: try SliceJSON.kitFixture("workbench/terminal_session.json"),
            optionalKeys: ["title_clipped", "target_id", "state_at", "state_caption_clipped", "oldest_ask_id",
                           "finish_summary_clipped", "agent_error_clipped", "report_target_id", "report_done",
                           "report_total", "report_pr_line", "report_pr_line_clipped"]
        )
        XCTAssertTrue(SliceJSON.allKeys(payload).isDisjoint(with: neverPublishedKeys))
        XCTAssertEqual(payload["agent"] as? String, "claude_code")
        XCTAssertEqual(payload["state_kind"] as? String, "waiting_on_ask")
        XCTAssertEqual(payload["open_asks"] as? Int, 1)
        XCTAssertEqual(payload["closed_asks"] as? Int, 1)
        XCTAssertEqual(payload["live"] as? Bool, true)
    }

    // MARK: - Presentation parity

    /// Every kind of §4b, resolved from the stored row exactly as the Mac
    /// resolves it, carries `SessionStatePresentation`'s tone, caption and
    /// glyph.
    func testEveryStateKindPublishesTheMacsPresentation() throws {
        struct Case {
            let name: String
            let live: Bool
            let seed: (Database, Int64, Int64) throws -> Void
            let expected: SessionSwitcherPresentation.State.Kind
            let wire: String
        }
        let cases: [Case] = [
            Case(name: "working", live: true, seed: { db, id, _ in try self.setState(db, id, state: "working") },
                 expected: .working, wire: "working"),
            Case(name: "running", live: true, seed: { _, _, _ in }, expected: .running, wire: "running"),
            Case(name: "waiting on an ask", live: false, seed: { db, id, project in
                try TestDatabase.insertOwnerAsk(db, projectID: project, sessionID: id)
            }, expected: .waitingOnAsk, wire: "waiting_on_ask"),
            Case(name: "needs approval", live: true, seed: { db, id, _ in try self.setState(db, id, state: "approval") },
                 expected: .needsApproval, wire: "needs_approval"),
            Case(name: "finished", live: false, seed: { db, id, _ in try self.setState(db, id, state: nil, finished: true) },
                 expected: .finished, wire: "finished"),
            Case(name: "finished with open asks", live: false, seed: { db, id, project in
                try self.setState(db, id, state: nil, finished: true)
                try TestDatabase.insertOwnerAsk(db, projectID: project, sessionID: id)
                try TestDatabase.insertOwnerAsk(db, projectID: project, sessionID: id)
            }, expected: .finished, wire: "finished"),
            Case(name: "stopped", live: true, seed: { db, id, _ in try self.setState(db, id, state: "waiting") },
                 expected: .stopped, wire: "stopped"),
            // #411: Agents working has no wire kind; it goes out as working.
            Case(name: "agents working", live: true, seed: { db, id, _ in
                try self.setState(db, id, state: "waiting", background: 2)
            }, expected: .background, wire: "working"),
            Case(name: "failed with an error", live: true, seed: { db, id, _ in
                try self.setState(db, id, state: "waiting", failedError: "rate_limit")
            }, expected: .failed, wire: "failed"),
            Case(name: "failed with an empty error", live: true, seed: { db, id, _ in
                try self.setState(db, id, state: "waiting", failedError: "")
            }, expected: .failed, wire: "failed"),
            Case(name: "not started", live: false, seed: { _, _, _ in }, expected: .notStarted, wire: "not_started")
        ]
        let seeded = try dbPool.write { db -> [(Case, Int64)] in
            let project = try TestDatabase.insertWorkbench(db)
            return try cases.map { item in
                let id = try SliceSeed.insertSession(db, projectID: project)
                try item.seed(db, id, project)
                return (item, id)
            }
        }
        let live = Set(seeded.filter { $0.0.live }.map(\.1))
        let published = try payloads(slice(live: live))
        let rows = try dbPool.read { try TerminalSessionQueries.fetchAgentStates($0, liveIDs: []) }
        let statuses = SessionAgentStatus.resolve(
            rows, liveIDs: live, startedAt: Dictionary(uniqueKeysWithValues: live.map { ($0, started) }), now: now
        )

        for (item, id) in seeded {
            let payload = try XCTUnwrap(published[id], item.name)
            let state = SessionSwitcherPresentation.state(of: id, liveIDs: live, statuses: statuses)
            XCTAssertEqual(state.kind, item.expected, item.name)
            XCTAssertEqual(payload["state_kind"] as? String, item.wire, item.name)
            XCTAssertEqual(payload["state_caption"] as? String, SessionStatePresentation.caption(for: state), item.name)
            XCTAssertEqual(payload["state_glyph"] as? String, SessionStatePresentation.glyph(for: state) ?? "", item.name)
            XCTAssertEqual(payload["state_tone"] as? String, Self.wire(SessionStatePresentation.color(for: state)), item.name)
            XCTAssertEqual(payload["is_ring"] as? Bool, SessionStatePresentation.isRing(state), item.name)
            XCTAssertEqual(payload["live"] as? Bool, item.live, item.name)
        }
        let byName = Dictionary(uniqueKeysWithValues: seeded.map { ($0.0.name, published[$0.1] ?? [:]) })
        XCTAssertEqual(byName["finished with open asks"]?["state_tone"] as? String, "orange")
        XCTAssertEqual(byName["finished"]?["state_tone"] as? String, "blue")
        XCTAssertEqual(byName["failed with an error"]?["state_caption"] as? String, "Error: rate limit")
        XCTAssertEqual(byName["failed with an error"]?["agent_error"] as? String, "rate_limit")
        XCTAssertEqual(byName["failed with an empty error"]?["state_caption"] as? String, "Stopped on an error")
        XCTAssertEqual(byName["not started"]?["state_caption"] as? String, "Not running", "no age: the caption never ticks")
        XCTAssertEqual(byName["not started"]?["is_ring"] as? Bool, true)
        XCTAssertEqual(byName["agents working"]?["state_caption"] as? String, "2 agents working")
        XCTAssertEqual(byName["agents working"]?["state_tone"] as? String, "green")
        XCTAssertEqual(byName["agents working"]?["state_glyph"] as? String, "person.2.fill")
    }

    /// #411: a count lowered to zero shows Agents working for the policy's
    /// grace, judged at the slice's clock, then the session is stopped.
    func testAZeroCountIsAgentsWorkingForTheGraceAtTheSlicesClock() throws {
        let session = try dbPool.write { db -> Int64 in
            let project = try TestDatabase.insertWorkbench(db)
            let id = try SliceSeed.insertSession(db, projectID: project)
            try self.setState(db, id, state: "waiting", at: 1, background: 0, backgroundAt: 2)
            return id
        }
        let reported = started.addingTimeInterval(2)
        let inGrace = try XCTUnwrap(try payloads(slice(live: [session], at: reported.addingTimeInterval(60)))[session])
        XCTAssertEqual(inGrace["state_kind"] as? String, "working")
        XCTAssertEqual(inGrace["state_caption"] as? String, "Agents working")
        let after = SessionBackgroundPolicy.grace + 1
        let over = try XCTUnwrap(try payloads(slice(live: [session], at: reported.addingTimeInterval(after)))[session])
        XCTAssertEqual(over["state_kind"] as? String, "stopped")
    }

    private static func wire(_ tone: SessionStatePresentation.Tone) -> String {
        switch tone {
        case .green: "green"
        case .orange: "orange"
        case .blue: "blue"
        case .red: "red"
        case .secondary: "secondary"
        }
    }

    // MARK: - Window

    func testShellSessionsAreNotPublished() throws {
        let (claude, shell) = try dbPool.write { db -> (Int64, Int64) in
            let project = try TestDatabase.insertWorkbench(db)
            return (try SliceSeed.insertSession(db, projectID: project),
                    try SliceSeed.insertSession(db, projectID: project, kind: "shell"))
        }
        let published = try payloads(slice(live: [claude, shell]))
        XCTAssertEqual(Set(published.keys), [claude])
    }

    func testTheWindowIsTheFiftyNewestPlusEveryLiveSession() throws {
        let now = Date()
        let ids = try dbPool.write { db -> [Int64] in
            let project = try TestDatabase.insertWorkbench(db)
            // ids[0] is the newest, ids[59] the oldest.
            return try (0..<60).map { try SliceSeed.insertSession(db, projectID: project, lastActiveAt: now.addingTimeInterval(-Double($0) * 60)) }
        }
        let live: Set<Int64> = [ids[3], ids[55], ids[59]]
        let published = try payloads(slice(live: live))

        XCTAssertEqual(published.count, 52)
        XCTAssertEqual(Set(published.keys), Set(ids.prefix(50)).union(live))
        XCTAssertNil(published[ids[50]], "a session outside the window and not live is not published")
    }

    func testTitleCaptionAndPRLineAreCapped() throws {
        let session = try dbPool.write { db -> Int64 in
            let project = try TestDatabase.insertWorkbench(db)
            let id = try SliceSeed.insertSession(db, projectID: project)
            try db.execute(
                sql: "UPDATE terminal_sessions SET title = ?, finish_summary = ?, finished_at = ? WHERE id = ?",
                arguments: [String(repeating: "t", count: 201), String(repeating: "s", count: 2001), self.stamp(1), id]
            )
            return id
        }
        let summary = SessionReportSummary(sessionID: session, done: 0, total: 0, prLine: String(repeating: "p", count: 121))
        let payload = try XCTUnwrap(try payloads(slice { _, _ in summary })[session])
        XCTAssertEqual((payload["title"] as? String)?.count, 200)
        XCTAssertEqual(payload["title_clipped"] as? Bool, true)
        XCTAssertEqual((payload["finish_summary"] as? String)?.count, 2000)
        XCTAssertEqual(payload["finish_summary_clipped"] as? Bool, true)
        XCTAssertEqual((payload["report_pr_line"] as? String)?.count, 120)
        XCTAssertEqual(payload["report_pr_line_clipped"] as? Bool, true)
        XCTAssertNil(payload["report_target_id"], "a summary without a target carries none")
    }

    func testSessionsOfAnUnpublishedWorkbenchAreNotPublished() throws {
        let now = Date()
        let lastWorkbenchSession = try dbPool.write { db -> Int64 in
            var last: Int64 = 0
            for index in 0...WorkbenchSlice.maxWorkbenches {
                let project = try TestDatabase.insertWorkbench(db, name: "acme \(index)", folder: "/tmp/acme-\(index)")
                last = try SliceSeed.insertSession(db, projectID: project, lastActiveAt: now.addingTimeInterval(-Double(index) * 60))
            }
            return last
        }
        let published = try payloads(slice())
        XCTAssertEqual(published.count, WorkbenchSlice.maxWorkbenches)
        XCTAssertNil(published[lastWorkbenchSession], "the 101st workbench is not published, nor are its sessions")
    }

    func testSessionCountsComeFromThePublishedStates() throws {
        let (project, ids) = try dbPool.write { db -> (Int64, [Int64]) in
            let project = try TestDatabase.insertWorkbench(db)
            var ids: [Int64] = []
            for _ in 0..<7 { ids.append(try SliceSeed.insertSession(db, projectID: project)) }
            try self.setState(db, ids[0], state: "working")
            try self.setState(db, ids[2], state: "approval")
            try TestDatabase.insertOwnerAsk(db, projectID: project, sessionID: ids[3])
            try self.setState(db, ids[4], state: nil, finished: true)
            try self.setState(db, ids[6], state: "waiting", background: 1)
            try SliceSeed.insertSession(db, projectID: project, kind: "shell")
            return (project, ids)
        }
        let source = slice(live: [ids[0], ids[1], ids[2], ids[6]])
        let counts = try XCTUnwrap(try dbPool.read { try source.sessionCounts($0) }[project])
        XCTAssertEqual(counts, .init(working: 3, waiting: 1, needsApproval: 1, finished: 1, failed: 0, stopped: 0, notRunning: 1),
                       "running and Agents working count as working; the shell is not counted")
    }

    // MARK: - Report summary

    func testTheSummaryJSONMapsToTheReportFieldsAndAFailureKeepsTheLastValues() async throws {
        let (project, session) = try await dbPool.write { db -> (Int64, Int64) in
            let project = try TestDatabase.insertWorkbench(db)
            return (project, try SliceSeed.insertSession(db, projectID: project))
        }
        let json = #"[{"session_id":\#(session),"target_id":415,"done":1,"total":2,"pr_line":"PR #175 open","finished_at":""}]"#
        let runner = FakeCLIRunner(stdout: Data(json.utf8))
        let failing = OSAllocatedUnfairLock(initialState: false)
        let cliFetch = SessionReportSummaryRunner.cliFetch(runner)
        let clock = TestInstant()
        let summaries = SessionReportSummaryRunner(
            fetch: { id in
                if failing.withLock({ $0 }) { throw CLIRunnerError.launchFailed(underlying: CancellationError()) }
                return try await cliFetch(id)
            },
            workbenches: { .init(live: [project], published: [project]) },
            clock: { clock.now }
        )
        let changes = OSAllocatedUnfairLock(initialState: 0)
        summaries.setOnChange { changes.withLock { $0 += 1 } }
        let source = slice(live: [session]) { summaries.summary(workbenchID: $0, sessionID: $1) }

        let before = try XCTUnwrap(try payloads(source)[session])
        XCTAssertNil(before["report_target_id"], "absent before the first summary run")
        XCTAssertNil(before["report_done"])

        await summaries.runDue()
        XCTAssertEqual(runner.invocations, [["workbench", "session-report", "--workbench", String(project), "--summary", "--json"]])
        XCTAssertEqual(changes.withLock { $0 }, 1)
        let mapped = try XCTUnwrap(try payloads(source)[session])
        XCTAssertEqual(mapped["report_target_id"] as? Int, 415)
        XCTAssertEqual(mapped["report_done"] as? Int, 1)
        XCTAssertEqual(mapped["report_total"] as? Int, 2)
        XCTAssertEqual(mapped["report_pr_line"] as? String, "PR #175 open")

        failing.withLock { $0 = true }
        clock.advance(by: .seconds(60))
        let attempted = await summaries.runDue()
        XCTAssertEqual(attempted, [project], "the failing run did run")
        let kept = try XCTUnwrap(try payloads(source)[session])
        XCTAssertEqual(kept["report_target_id"] as? Int, 415, "a summary failure keeps the last values")
        XCTAssertEqual(kept["report_pr_line"] as? String, "PR #175 open")
        XCTAssertEqual(changes.withLock { $0 }, 1, "and nudges nothing")
    }

    func testSummaryCadenceIsEvery60SecondsAndAStateChangeIsCoalesced() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let clock = TestInstant()
        let summaries = SessionReportSummaryRunner(
            fetch: { _ in
                calls.withLock { $0 += 1 }
                return []
            },
            workbenches: { .init(live: [7], published: [7, 9]) },
            clock: { clock.now }
        )
        await summaries.runDue()
        clock.advance(by: .seconds(59))
        await summaries.runDue()
        XCTAssertEqual(calls.withLock { $0 }, 1, "not due before 60 s")
        clock.advance(by: .seconds(1))
        await summaries.runDue()
        XCTAssertEqual(calls.withLock { $0 }, 2, "due at 60 s")

        summaries.sessionStateChanged(workbenchID: 7)
        summaries.sessionStateChanged(workbenchID: 7)
        clock.advance(by: .seconds(2))
        await summaries.runDue()
        XCTAssertEqual(calls.withLock { $0 }, 2, "a change waits for the coalescing spacing")
        clock.advance(by: .seconds(3))
        await summaries.runDue()
        await summaries.runDue()
        XCTAssertEqual(calls.withLock { $0 }, 3, "two changes in one spacing run once")

        summaries.sessionStateChanged(workbenchID: 9)
        clock.advance(by: .seconds(5))
        await summaries.runDue()
        XCTAssertEqual(calls.withLock { $0 }, 4, "a state change runs a workbench with no live session left")
    }

    func testAHungSummaryTimesOutAndKeepsTheLastValues() async throws {
        let summaries = SessionReportSummaryRunner(
            fetch: { _ in
                try await Task.sleep(for: .seconds(30))
                return [SessionReportSummary(sessionID: 1, done: 9, total: 9)]
            },
            workbenches: { .init(live: [7], published: [7, 9]) },
            timing: .init(every: .seconds(60), minSpacing: .seconds(5), timeout: .milliseconds(50), wake: .seconds(5))
        )
        await summaries.runDue()
        XCTAssertNil(summaries.summary(workbenchID: 7, sessionID: 1))
    }

    func testAStopMidPassRunsTheUnfinishedWorkbenchesAgainAfterARestart() async throws {
        let gate = FetchGate()
        let clock = TestInstant()
        let summaries = SessionReportSummaryRunner(
            fetch: { id in
                await gate.enter(id)
                return []
            },
            workbenches: { .init(live: [1, 2, 3], published: [1, 2, 3]) },
            clock: { clock.now }
        )
        let pass = Task { await summaries.runDue() }
        await awaitHubCondition("the first run is in flight") { gate.calls == [1] }
        summaries.stop()
        gate.release()
        _ = await pass.value

        await summaries.runDue()
        XCTAssertEqual(gate.calls, [1, 1, 2, 3], "nothing the stop cut waits for the next 60 s")
    }

    /// Review M3: a workbench that is no longer published is forgotten, its
    /// summaries and any pending request with it.
    func testAWorkbenchThatLeavesThePublishedListIsForgotten() async throws {
        let calls = OSAllocatedUnfairLock(initialState: [Int64]())
        let published = OSAllocatedUnfairLock(initialState: Set<Int64>([7]))
        let clock = TestInstant()
        let summaries = SessionReportSummaryRunner(
            fetch: { id in
                calls.withLock { $0.append(id) }
                return [SessionReportSummary(sessionID: 1, done: 1, total: 2)]
            },
            workbenches: { .init(live: [], published: published.withLock { $0 }) },
            clock: { clock.now }
        )
        summaries.sessionStateChanged(workbenchID: 7)
        await summaries.runDue()
        XCTAssertNotNil(summaries.summary(workbenchID: 7, sessionID: 1))

        published.withLock { $0 = [] }
        summaries.sessionStateChanged(workbenchID: 7)
        clock.advance(by: .seconds(10))
        await summaries.runDue()

        XCTAssertNil(summaries.summary(workbenchID: 7, sessionID: 1), "its summaries are dropped")
        XCTAssertEqual(calls.withLock { $0 }, [7], "and its pending request runs nothing")
    }
}
