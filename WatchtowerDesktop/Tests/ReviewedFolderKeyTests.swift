import XCTest
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// When the reviewer panel reads the reviewed folder's status again (#2003):
/// a Refresh of the same round and tree still re-reads it — the folder may
/// have switched branches meanwhile.
@MainActor
final class ReviewedFolderKeyTests: XCTestCase {
    private var paths: [String] = []

    override func tearDown() {
        paths.forEach { TestDatabase.cleanup(path: $0) }
        paths = []
        super.tearDown()
    }

    func testARefreshOfTheSameTreeRereadsTheReviewedFolder() async throws {
        let h = try ReviewModelHarness()
        paths.append(h.path)
        h.baseScript()
        h.cli.script("start", [startJSON(id: 7, prev: 0), startJSON(id: 7, prev: 0)])
        await h.model.open()
        let before = ReviewedFolderKey(model: h.model, sessionID: h.sessionID)
        await h.model.refresh()
        let after = ReviewedFolderKey(model: h.model, sessionID: h.sessionID)
        XCTAssertEqual(h.model.round?.id, 7)
        XCTAssertEqual(after.roundID, before.roundID)
        XCTAssertEqual(after.diffKey, before.diffKey)
        XCTAssertNotEqual(after, before, "the same round and diff key are read again")
    }
}
