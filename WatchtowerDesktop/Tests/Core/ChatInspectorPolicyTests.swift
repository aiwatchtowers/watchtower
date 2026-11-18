import XCTest
@testable import WatchtowerCore
import WatchtowerChatText

/// The chat inspector's panel choice and its sources selection (Core; the grouping itself is tested in
/// WatchtowerChatText).
final class ChatInspectorPolicyTests: XCTestCase {
    // MARK: - Inspector mode

    func testInspectorShowsThePreferredOpenPanelAndFallsBack() {
        XCTAssertEqual(ChatInspectorPolicy.visibleMode(preferred: .sources, artifactOpen: true, sourcesOpen: true),
                       .sources)
        XCTAssertEqual(ChatInspectorPolicy.visibleMode(preferred: .sources, artifactOpen: true, sourcesOpen: false),
                       .artifacts, "closing Sources falls back to the still-open artifact")
        XCTAssertEqual(ChatInspectorPolicy.visibleMode(preferred: .artifacts, artifactOpen: false, sourcesOpen: true),
                       .sources)
        XCTAssertNil(ChatInspectorPolicy.visibleMode(preferred: .artifacts, artifactOpen: false, sourcesOpen: false))
        XCTAssertTrue(ChatInspectorPolicy.showsTabs(artifactOpen: true, sourcesOpen: true))
        XCTAssertFalse(ChatInspectorPolicy.showsTabs(artifactOpen: false, sourcesOpen: true))
    }

    func testSelectionDedupesItsSources() {
        let src = ChatSource(kind: "jira", title: "PAY-1", url: nil, ref: "jira:PAY-1")
        XCTAssertEqual(ChatSourcesSelection(messageID: 1, sources: [src, src]).sources.count, 1)
    }
}
