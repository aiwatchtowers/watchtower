import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class SearchIndexRebuildNoticeViewTests: XCTestCase {
    func testPendingShowsTheLine() throws {
        let view = SearchIndexRebuildNotice(isPending: true)
        XCTAssertEqual(
            try view.inspect().find(ViewType.Label.self).title().text().string(),
            "Search index is still being updated — older Slack messages may be missing."
        )
    }

    func testNotPendingShowsNothing() {
        let view = SearchIndexRebuildNotice(isPending: false)
        XCTAssertThrowsError(try view.inspect().find(ViewType.Label.self))
    }
}
