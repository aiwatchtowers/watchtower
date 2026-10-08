import Foundation
import GRDB
import os
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The `session_timeline` projection (mobile POC spec §4.9): its sources,
/// the hub-observed state milestones, the caps and the sidecar's pruning.
final class SessionTimelineSliceTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var sidecar: HubSyncState!
    private let now = Date()

    /// Every milestone kind of the Kit mirror (`SessionTimeline.Milestone.Kind`).
    private static let kitKinds: Set<String> = [
        "state", "ask_opened", "ask_answered", "ask_withdrawn", "target_linked", "target_status", "phase", "pr", "finished"
    ]

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

    private func slice(live: Set<Int64> = []) -> SessionTimelineSlice {
        let liveness = SessionLiveness(liveIDs: live, startedAt: Dictionary(uniqueKeysWithValues: live.map { ($0, Date()) }))
        let sessions = TerminalSessionSlice(liveness: { liveness }, reportSummary: { _, _ in nil })
        let now = self.now
        return SessionTimelineSlice(sessions: sessions, sidecar: sidecar) { now }
    }

    private func payloads(_ source: SessionTimelineSlice) throws -> [Int64: [String: Any]] {
        var byID: [Int64: [String: Any]] = [:]
        for object in try SliceJSON.objects(try dbPool.read { try source.records($0) }) {
            byID[try XCTUnwrap(object["session_id"] as? Int64)] = object
        }
        return byID
    }

    private func milestones(_ payload: [String: Any]?) throws -> [[String: Any]] {
        try XCTUnwrap(payload?["milestones"] as? [[String: Any]])
    }

    /// A workbench with one session created an hour ago and active now.
    private func seedSession() throws -> (project: Int64, session: Int64) {
        try dbPool.write { db in
            let project = try TestDatabase.insertWorkbench(db)
            let session = try SliceSeed.insertSession(db, projectID: project, lastActiveAt: now)
            try db.execute(
                sql: "UPDATE terminal_sessions SET created_at = ? WHERE id = ?",
                arguments: [dbStamp(now.addingTimeInterval(-3600)), session]
            )
            return (project, session)
        }
    }

    private func addHistory(_ db: Database, target: Int64, from: String?, to: String, at: Date, actor: String = "agent") throws {
        try db.execute(
            sql: "INSERT INTO target_status_history (target_id, from_status, to_status, changed_at, actor) VALUES (?, ?, ?, ?, ?)",
            arguments: [target, from, to, dbStamp(at), actor]
        )
    }

    // MARK: - Wire shape

    func testPayloadMatchesTheKitFixture() throws {
        let (project, session) = try seedSession()
        _ = try dbPool.write { db in
            try TestDatabase.insertOwnerAsk(db, projectID: project, sessionID: session, createdAt: dbStamp(now.addingTimeInterval(-60)))
        }
        try sidecar.addStateMilestone(.init(sessionID: session, at: now.addingTimeInterval(-120), text: "Started"))
        let payload = try XCTUnwrap(try payloads(slice())[session])
        let fixture = try SliceJSON.kitFixture("workbench/session_timeline.json")

        assertWireShape(payload, matches: fixture, optionalKeys: ["milestones_more"])
        let list = try milestones(payload)
        XCTAssertEqual(list.map { $0["kind"] as? String }, ["ask_opened", "state"], "newest first")
        let fixtureList = try XCTUnwrap(fixture["milestones"] as? [[String: Any]])
        assertWireShape(list[0], matches: fixtureList[0], optionalKeys: ["text_clipped"])
        assertWireShape(list[1], matches: fixtureList[2], optionalKeys: ["text_clipped"])
        XCTAssertNil(list[1]["ref"], "a state milestone has no ref")
        XCTAssertEqual(list[0]["text"] as? String, "Asked: Which way?")
    }

    // MARK: - Caps

    func testA150MilestoneTimelineKeepsTheNewest100() throws {
        let (project, session) = try seedSession()
        try dbPool.write { db in
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: project)
            try db.execute(sql: "DELETE FROM target_status_history WHERE target_id = ?", arguments: [target])
            try SliceSeed.linkSession(db, sessionID: session, targetID: target)
            for index in 0..<149 {
                try addHistory(db, target: target, from: "todo", to: "in_progress", at: now.addingTimeInterval(Double(index - 1000)))
            }
        }
        let payload = try XCTUnwrap(try payloads(slice())[session])
        let list = try milestones(payload)

        XCTAssertEqual(list.count, 100)
        XCTAssertEqual(payload["milestones_more"] as? Int, 50, "149 status moves plus the link")
        let stamps = list.compactMap { $0["at"] as? Double }
        XCTAssertEqual(stamps, stamps.sorted(by: >), "newest first")
        XCTAssertEqual(list.first?["kind"] as? String, "target_linked", "the link (now) is the newest")
        // The 50 oldest status moves (0…49) are the ones left out.
        XCTAssertEqual(try XCTUnwrap(stamps.last), now.addingTimeInterval(50 - 1000).timeIntervalSince1970, accuracy: 1)
    }

    func testALongTextIsClippedAt200() throws {
        let (_, session) = try seedSession()
        try sidecar.addStateMilestone(.init(sessionID: session, at: now, text: "Error: " + String(repeating: "👩‍👩‍👧", count: 300)))
        let milestone = try XCTUnwrap(try milestones(try payloads(slice())[session]).first)
        let text = try XCTUnwrap(milestone["text"] as? String)
        XCTAssertEqual(text.count, 200)
        XCTAssertTrue(text.hasSuffix("…"))
        XCTAssertEqual(milestone["text_clipped"] as? Bool, true)
    }

    // MARK: - Sources

    func testAStateTransitionObservedByTheHubIsAStateMilestone() async throws {
        let (project, session) = try seedSession()
        let state = OSAllocatedUnfairLock(initialState: SessionSwitcherPresentation.State.live(.working))
        let stateAt = now.addingTimeInterval(-30)
        let hookTime = OSAllocatedUnfairLock(initialState: now)
        let reports = SessionReportRunner(
            fetch: { _, _, _ in throw CLIRunnerError.launchFailed(underlying: CancellationError()) },
            sidecar: sidecar,
            now: { hookTime.withLock { $0 } },
            window: {
                [SessionReportSlice.Windowed(
                    sessionID: session, workbenchID: project, live: true, createdAt: nil, lastActiveAt: Date(),
                    state: state.withLock { $0 }, stateAt: stateAt
                )]
            }
        )
        let changes = OSAllocatedUnfairLock(initialState: 0)
        reports.setOnChange { changes.withLock { $0 += 1 } }

        reports.sessionStatesChanged()
        await reports.runDue()
        reports.sessionStatesChanged()
        await reports.runDue()
        XCTAssertEqual(try sidecar.stateMilestones()[session]?.map(\.text), ["Working"], "an unchanged state adds nothing")

        state.withLock { $0 = .live(.needsApproval) }
        hookTime.withLock { $0 = now.addingTimeInterval(10) }
        await reports.runDue()
        XCTAssertEqual(try sidecar.stateMilestones()[session]?.count, 1, "nothing is resolved before the fast lane reports a change")
        reports.sessionStatesChanged()
        await reports.runDue()

        let list = try milestones(try payloads(slice(live: [session]))[session])
        XCTAssertEqual(list.map { $0["text"] as? String }, ["Needs approval", "Working"])
        XCTAssertEqual(list.map { $0["kind"] as? String }, ["state", "state"])
        XCTAssertEqual(list[0]["at"] as? Double, now.addingTimeInterval(10).timeIntervalSince1970, "the transition at the lane's report")
        XCTAssertEqual(list[1]["at"] as? Double, stateAt.timeIntervalSince1970, "the first sighting at the state's own time")
        XCTAssertGreaterThanOrEqual(changes.withLock { $0 }, 2)
    }

    func testStatusHistoryOfALinkedTargetBeforeTheSessionIsExcluded() throws {
        let (project, session) = try seedSession()
        let target = try dbPool.write { db -> Int64 in
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: project, text: "Export")
            try db.execute(sql: "DELETE FROM target_status_history WHERE target_id = ?", arguments: [target])
            try SliceSeed.linkSession(db, sessionID: session, targetID: target)
            try addHistory(db, target: target, from: nil, to: "todo", at: now.addingTimeInterval(-7200), actor: "owner")
            try addHistory(db, target: target, from: "todo", to: "in_progress", at: now.addingTimeInterval(-1800))
            return target
        }
        let list = try milestones(try payloads(slice())[session])
        let statuses = list.filter { $0["kind"] as? String == "target_status" }

        XCTAssertEqual(statuses.map { $0["text"] as? String }, ["todo → in_progress (agent)"])
        XCTAssertEqual(statuses.first?["ref"] as? Int64, target)
        XCTAssertEqual(list.filter { $0["kind"] as? String == "target_linked" }.map { $0["text"] as? String }, ["Linked: Export"])
    }

    /// Every source at once: only the Kit's kinds come out, never a
    /// subagent event, and the sidecar refuses any kind but `state`.
    func testNoSubagentMilestoneIsEverProduced() throws {
        let (project, session) = try seedSession()
        try dbPool.write { db in
            let target = try TestDatabase.insertWorkbenchTarget(db, projectID: project)
            try SliceSeed.linkSession(db, sessionID: session, targetID: target)
            try addHistory(db, target: target, from: "todo", to: "done", at: now)
            let ask = try TestDatabase.insertOwnerAsk(db, projectID: project, sessionID: session, status: "answered", answer: "{}")
            try db.execute(sql: "UPDATE owner_asks SET answered_at = ? WHERE id = ?", arguments: [dbStamp(now), ask])
            try TestDatabase.insertOwnerAsk(db, projectID: project, sessionID: session, status: "withdrawn", withdrawnReason: "agent")
            try db.execute(
                sql: "UPDATE terminal_sessions SET finished_at = ?, finish_summary = 'Shipped' WHERE id = ?",
                arguments: [dbStamp(now), session]
            )
        }
        let report = try JSONDecoder().decode(SessionReport.self, from: Data(#"""
        {"session":{"id":\#(session)},"phases":[{"target_id":1,"text":"Export","started_at":"\#(dbStamp(now))",
        "finished_at":"\#(dbStamp(now))","items":[]}],
        "prs":[{"ref":"pr:7","pr_number":7,"state":"merged","merged_at":"\#(dbStamp(now))","targets":[1]}]}
        """#.utf8))
        try sidecar.saveSessionReport(try SessionReportSlice.encode(report), sessionID: session, at: now)
        try sidecar.addStateMilestone(.init(sessionID: session, at: now, text: "Working"))

        let kinds = Set(try milestones(try payloads(slice())[session]).compactMap { $0["kind"] as? String })
        XCTAssertEqual(kinds, Self.kitKinds, "every source shows")
        XCTAssertEqual(Set(SessionTimelineSlice.MilestoneKind.allCases.map(\.rawValue)), Self.kitKinds,
                       "the hub has no kind beyond the Kit's, so no subagent kind")
        XCTAssertFalse(kinds.contains { $0.contains("subagent") })
    }

    func testASessionWithNoMilestonesHasAnEmptyList() throws {
        let (_, session) = try seedSession()
        let payload = try XCTUnwrap(try payloads(slice())[session], "a record, not a missing one")
        XCTAssertEqual(try milestones(payload).count, 0)
        XCTAssertNil(payload["milestones_more"])
    }

    // MARK: - Sidecar

    func testTheSidecarPrunesAfter14DaysAndKeeps100PerSession() async throws {
        try sidecar.addStateMilestone(.init(sessionID: 1, at: now.addingTimeInterval(-15 * 86_400), text: "Stopped"))
        try sidecar.addStateMilestone(.init(sessionID: 1, at: now.addingTimeInterval(-13 * 86_400), text: "Working"))
        for index in 0..<120 {
            try sidecar.addStateMilestone(.init(sessionID: 2, at: now.addingTimeInterval(Double(index)), text: "State \(index)"))
        }
        XCTAssertEqual(try sidecar.stateMilestones()[2]?.count, 100, "an insert keeps the newest 100")
        XCTAssertEqual(try sidecar.stateMilestones()[2]?.first?.text, "State 119")

        // The runner's pass prunes, even with no session in the window.
        let now = self.now
        let runner = SessionReportRunner(
            fetch: { _, _, _ in throw CLIRunnerError.launchFailed(underlying: CancellationError()) },
            sidecar: sidecar,
            now: { now },
            window: { [] }
        )
        await runner.runDue()
        XCTAssertEqual(try sidecar.stateMilestones()[1]?.map(\.text), ["Working"], "the 15-day-old milestone is gone")
        XCTAssertEqual(try sidecar.stateMilestones()[2]?.count, 100)
    }
}
