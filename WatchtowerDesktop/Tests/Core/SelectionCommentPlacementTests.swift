import XCTest
@testable import WatchtowerCore

final class SelectionCommentPlacementTests: XCTestCase {
    private let container = CGSize(width: 600, height: 400)
    private let button = CGSize(width: 80, height: 24)

    func testSitsJustPastTheSelectionLevelWithItsFirstLine() {
        let origin = SelectionCommentPlacement.origin(
            selection: CGRect(x: 40, y: 100, width: 200, height: 36), container: container, button: button
        )
        XCTAssertEqual(origin, CGPoint(x: 246, y: 100))
    }

    func testStaysInsideTheVisibleArea() {
        let wide = SelectionCommentPlacement.origin(
            selection: CGRect(x: 20, y: 380, width: 560, height: 40), container: container, button: button
        )
        XCTAssertEqual(wide, CGPoint(x: 514, y: 376), "clamped to the right edge and the bottom")
        let cutAtTop = SelectionCommentPlacement.origin(
            selection: CGRect(x: 20, y: -30, width: 100, height: 60), container: container, button: button
        )
        XCTAssertEqual(cutAtTop?.y, 0, "a selection scrolled half off the top keeps the button on screen")
    }

    func testNoButtonWithoutAVisibleSelection() {
        XCTAssertNil(SelectionCommentPlacement.origin(selection: nil, container: container, button: button))
        XCTAssertNil(SelectionCommentPlacement.origin(
            selection: CGRect(x: 20, y: 500, width: 100, height: 20), container: container, button: button
        ), "scrolled out of view")
        XCTAssertNil(SelectionCommentPlacement.origin(selection: .null, container: container, button: button))
    }
}
