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

    private func action(_ entity: String?, params: [String: JSONValue] = [:]) -> ActionRequestPayload {
        ActionRequestPayload(id: UUID().uuidString, kind: .sessionChatRequest, entityID: entity, params: params, createdAt: Date())
    }

    @MainActor
    func testUnknownSessionFails() async throws {
        let (agent, shell) = try await dbPool.write { db -> (Int64, Int64) in
            let project = try TestDatabase.insertWorkbench(db)
            return (try SliceSeed.insertSession(db, projectID: project), try SliceSeed.insertSession(db, projectID: project, kind: "shell"))
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
        _ = agent
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
        let second = try await dispatcher.dispatch(action(String(session), params: ["subagent_id": .string("a1b2")]))
        XCTAssertEqual(second, .applied())
        let keys = runner.watches.withLock { Set($0.keys.map(\.id)) }
        XCTAssertEqual(keys, [String(session), "\(session)-a1b2"])
    }
}
