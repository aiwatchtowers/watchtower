import GRDB
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// `chat_queued_drafts` (#604 S15): the queued embedded-chat draft.
final class QueuedDraftQueriesTests: XCTestCase {
    func testSaveReplaceAndClear() throws {
        let db = try TestDatabase.create()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        try db.write { try QueuedDraftQueries.save($0, key: "track:1:10", text: "first", at: at) }
        try db.write { try QueuedDraftQueries.save($0, key: "track:1:10", text: "second", at: at) }
        XCTAssertEqual(try db.read { try QueuedDraftQueries.text($0, key: "track:1:10") }, "second")
        XCTAssertNil(try db.read { try QueuedDraftQueries.text($0, key: "track:1:11") })
        try db.write { try QueuedDraftQueries.clear($0, key: "track:1:10") }
        XCTAssertNil(try db.read { try QueuedDraftQueries.text($0, key: "track:1:10") })
        try db.write { try QueuedDraftQueries.clear($0, key: "missing") }
    }
}
