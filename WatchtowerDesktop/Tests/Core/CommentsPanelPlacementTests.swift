import XCTest
@testable import WatchtowerCore

final class CommentsPanelPlacementTests: XCTestCase {
    func testTheListGoesBesideTheTextOnlyWhenBothFit() {
        let both = CommentsPanelPlacement.listWidth + CommentsPanelPlacement.minTextWidth
        XCTAssertTrue(CommentsPanelPlacement.besideText(width: both))
        XCTAssertTrue(CommentsPanelPlacement.besideText(width: 900))
        XCTAssertFalse(CommentsPanelPlacement.besideText(width: both - 1), "a narrow panel puts the list below")
        XCTAssertFalse(CommentsPanelPlacement.besideText(width: 320))
    }
}
