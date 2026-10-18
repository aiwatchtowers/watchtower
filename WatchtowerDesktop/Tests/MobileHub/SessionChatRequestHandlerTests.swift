import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// `session_chat_request`: validates the session, opens the watch, needs no grant.
final class SessionChatRequestHandlerTests: XCTestCase {
    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUpWithError() throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
    }

    override func tearDownWithError() throws {
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    private func action(_ entity: String?, params: [String: JSONValue] = [:], createdAt: Date = Date()) -> ActionRequestPayload {
        ActionRequestPayload(id: UUID().uuidString, kind: .sessionChatRequest, entityID: entity, params: params, createdAt: createdAt)
    }

    @MainActor
    func testUnknownSessionFails() async throws {
        let shell = try await dbPool.write { db -> Int64 in
            let project = try TestDatabase.insertWorkbench(db)
            return try SliceSeed.insertSession(db, projectID: project, kind: "shell")
        }
        let runner = SessionChatRunner(fetch: { _, _ in throw CocoaError(.fileReadUnknown) }, isLive: { _ in false })
        let sessions = TerminalSessionSlice(liveness: { SessionLiveness() }, reportSummary: { _, _ in nil })
        let dispatcher = MobileHubCommandDispatcher()
        SessionChatRequestHandler(dbPool: dbPool, runner: runner, sessions: sessions).register(on: dispatcher)

        for entity in ["999999", String(shell)] {
            let refused = try await dispatcher.dispatch(action(entity))
            XCTAssertEqual(refused?.status, .failed, entity)
            XCTAssertEqual(refused?.reason, .notFound, entity)
            XCTAssertEqual(refused?.errorMessage, "unknown_session", entity)
        }
        let invalid = try await dispatcher.dispatch(action(nil))
        XCTAssertEqual(invalid?.reason, .invalidParams)
        XCTAssertTrue(runner.watches.withLock { $0.isEmpty }, "a refused request opens no watch")
    }

    @MainActor
    func testValidRequestApplies() async throws {
        let session = try await dbPool.write { db -> Int64 in
            try SliceSeed.insertSession(db, projectID: try TestDatabase.insertWorkbench(db))
        }
        let runner = SessionChatRunner(fetch: { _, _ in throw CocoaError(.fileReadUnknown) }, isLive: { _ in false })
        let sessions = TerminalSessionSlice(liveness: { SessionLiveness() }, reportSummary: { _, _ in nil })
        let dispatcher = MobileHubCommandDispatcher()
        SessionChatRequestHandler(dbPool: dbPool, runner: runner, sessions: sessions).register(on: dispatcher)

        let first = try await dispatcher.dispatch(action(String(session)))
        XCTAssertEqual(first, .applied(), "no typing grant is needed")
        let subagent: [String: JSONValue] = ["subagent_id": .string("a1b2"), "tool_use_id": .string("toolu_01a")]
        let second = try await dispatcher.dispatch(action(String(session), params: subagent))
        XCTAssertEqual(second, .applied())
        let keys = runner.watches.withLock { Set($0.keys.map(\.id)) }
        XCTAssertEqual(keys, [String(session), "\(session)-a1b2"])
    }

    @MainActor
    func testSubagentIdsComeTogetherAndSessionIdMustMatch() async throws {
        let session = try await dbPool.write { db -> Int64 in
            try SliceSeed.insertSession(db, projectID: try TestDatabase.insertWorkbench(db))
        }
        let runner = SessionChatRunner(fetch: { _, _ in throw CocoaError(.fileReadUnknown) }, isLive: { _ in false })
        let sessions = TerminalSessionSlice(liveness: { SessionLiveness() }, reportSummary: { _, _ in nil })
        let dispatcher = MobileHubCommandDispatcher()
        SessionChatRequestHandler(dbPool: dbPool, runner: runner, sessions: sessions).register(on: dispatcher)

        let cases: [[String: JSONValue]] = [
            ["subagent_id": .string("a1b2")],
            ["tool_use_id": .string("toolu_01a")],
            ["session_id": .integer(session + 1)]
        ]
        for params in cases {
            let refused = try await dispatcher.dispatch(action(String(session), params: params))
            XCTAssertEqual(refused?.reason, .invalidParams, "\(params)")
        }
        let matching = try await dispatcher.dispatch(action(String(session), params: ["session_id": .integer(session)]))
        XCTAssertEqual(matching, .applied())
        XCTAssertEqual(runner.watches.withLock { $0.count }, 1, "only the valid request opened a watch")
    }

    @MainActor
    func testStaleRequestOpensNoWatchAndAgedOneExpiresSooner() async throws {
        let session = try await dbPool.write { db -> Int64 in
            try SliceSeed.insertSession(db, projectID: try TestDatabase.insertWorkbench(db))
        }
        let clock = TestInstant()
        let runner = SessionChatRunner(
            fetch: { _, _ in throw CocoaError(.fileReadUnknown) },
            isLive: { _ in false },
            clock: { clock.now }
        )
        let sessions = TerminalSessionSlice(liveness: { SessionLiveness() }, reportSummary: { _, _ in nil })
        let dispatcher = MobileHubCommandDispatcher()
        SessionChatRequestHandler(dbPool: dbPool, runner: runner, sessions: sessions).register(on: dispatcher)

        let stale = try await dispatcher.dispatch(action(String(session), createdAt: Date().addingTimeInterval(-600)))
        XCTAssertEqual(stale, .applied())
        XCTAssertTrue(runner.watches.withLock { $0.isEmpty }, "a 10-minute-old request opens no watch")

        let aged = try await dispatcher.dispatch(action(String(session), createdAt: Date().addingTimeInterval(-120)))
        XCTAssertEqual(aged, .applied())
        let start = clock.now
        let expires = try XCTUnwrap(runner.watches.withLock { $0.values.first?.expires })
        let left = expires - start
        XCTAssertLessThanOrEqual(left, .seconds(180))
        XCTAssertGreaterThan(left, .seconds(178), "a 2-minute-old request ends 3 minutes from now")
    }
}
