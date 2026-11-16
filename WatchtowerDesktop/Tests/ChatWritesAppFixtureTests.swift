import Foundation
import GRDB
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerCore
@testable import WatchtowerDesktop

/// The app-target half of `ChatWritesFixtureTests` (Tests/Core): the cases of
/// `chat_writes.json` whose Swift writer lives in the app target.
final class ChatWritesAppFixtureTests: XCTestCase {
    func testAppWritersMatchTheirGoCases() async throws {
        let mine = try ChatWritesFixture.cases().filter { $0.swift == "TuningChatSurface.setTitleIfEmpty" }
        XCTAssertFalse(mine.isEmpty)
        for fixtureCase in mine {
            let (pool, path) = try ChatWritesFixture.seeded(fixtureCase)
            defer { TestDatabase.cleanup(path: path) }
            let conv = fixtureCase.params.int64("conversation_id") ?? 0
            try await pool.write { try TuningChatSurface.setTitleIfEmpty($0, conversationID: conv) }
            for mismatch in try ChatWritesFixture.mismatches(fixtureCase, in: pool) {
                XCTFail("\(fixtureCase.name) (\(fixtureCase.swift)): \(mismatch)")
            }
        }
    }
}
