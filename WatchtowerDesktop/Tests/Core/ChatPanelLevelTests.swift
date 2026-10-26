import XCTest
@testable import WatchtowerCore

final class ChatPanelLevelTests: XCTestCase {
    func testStorageRoundTrip() {
        for level in [ChatPanelLevel.all, .project(7)] {
            XCTAssertEqual(ChatPanelLevel(storageValue: level.storageValue), level)
        }
        XCTAssertEqual(ChatPanelLevel.project(7).storageValue, "project:7")
        for junk in ["", "project:", "project:x", "proj:1", "All"] {
            XCTAssertNil(ChatPanelLevel(storageValue: junk), junk)
        }
    }

    func testAGoneProjectFallsBackToAllChats() {
        XCTAssertEqual(ChatPanelLevel.project(3).resolved(activeProjectIDs: [3]), .project(3))
        XCTAssertEqual(ChatPanelLevel.project(3).resolved(activeProjectIDs: [4]), .all)
        XCTAssertEqual(ChatPanelLevel.all.resolved(activeProjectIDs: []), .all)
    }

    func testListsFiltersByProject() {
        XCTAssertTrue(ChatPanelLevel.all.lists(projectID: nil))
        XCTAssertTrue(ChatPanelLevel.all.lists(projectID: 2))
        XCTAssertTrue(ChatPanelLevel.project(2).lists(projectID: 2))
        XCTAssertFalse(ChatPanelLevel.project(2).lists(projectID: nil))
        XCTAssertFalse(ChatPanelLevel.project(2).lists(projectID: 3))
    }
}
