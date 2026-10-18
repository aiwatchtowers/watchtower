import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The `session_chat` slice: only watched feeds are published.
final class SessionChatSliceTests: XCTestCase {
    private var dbPool: DatabasePool!
    private var dbPath: String!

    override func setUpWithError() throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
    }

    override func tearDownWithError() throws {
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    func testNoWatchPublishesNothing() async throws {
        let runner = SessionChatRunner(fetch: { id, _ in
            try JSONDecoder().decode(SessionFeedPayload.self, from: Data(#"{"session_id":\#(id)}"#.utf8))
        }, isLive: { _ in false })
        let slice = SessionChatSlice(runner: runner)
        XCTAssertEqual(slice.kind, .sessionChat)
        let empty = try await dbPool.read { try slice.records($0) }
        XCTAssertTrue(empty.isEmpty)

        runner.request(sessionID: 7, agentID: nil)
        runner.request(sessionID: 7, agentID: "a1b2")
        await runner.runDue()
        let records = try await dbPool.read { try slice.records($0) }
        XCTAssertEqual(Set(records.map(\.recordName)), ["session_chat-7", "session_chat-7-a1b2"])
        XCTAssertEqual(Set(records.map(\.id)), ["7", "7-a1b2"])
    }
}
