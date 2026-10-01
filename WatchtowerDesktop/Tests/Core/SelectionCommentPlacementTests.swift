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
        let cutAtTop = SelectionCommentPlacement.origin(
            selection: CGRect(x: 20, y: -30, width: 100, height: 60), container: container, button: button
        )
        XCTAssertEqual(cutAtTop, CGPoint(x: 126, y: 0), "a selection scrolled half off the top keeps the button on screen")
    }

    /// #165: a selection running to the right edge (several full lines) left
    /// no room beside it, and the clamped button landed on the selected text.
    func testAWideSelectionPutsTheButtonAboveItNotOnIt() throws {
        let selection = CGRect(x: 20, y: 120, width: 560, height: 60)
        let origin = try XCTUnwrap(SelectionCommentPlacement.origin(selection: selection, container: container, button: button))
        XCTAssertEqual(origin, CGPoint(x: 500, y: 90), "above, flush with the selection's trailing edge")
        XCTAssertFalse(CGRect(origin: origin, size: button).intersects(selection))
    }

    func testBelowWhenThereIsNoRoomAbove() throws {
        let selection = CGRect(x: 20, y: 10, width: 560, height: 40)
        let origin = try XCTUnwrap(SelectionCommentPlacement.origin(selection: selection, container: container, button: button))
        XCTAssertEqual(origin, CGPoint(x: 500, y: 56))
        XCTAssertFalse(CGRect(origin: origin, size: button).intersects(selection))
    }

    func testASelectionFillingTheViewStillGetsAButtonInside() throws {
        let origin = try XCTUnwrap(SelectionCommentPlacement.origin(
            selection: CGRect(x: 0, y: -100, width: 600, height: 700), container: container, button: button
        ))
        XCTAssertTrue(CGRect(origin: .zero, size: container).contains(CGRect(origin: origin, size: button)))
    }

    func testNoButtonWithoutAVisibleSelection() {
        XCTAssertNil(SelectionCommentPlacement.origin(selection: nil, container: container, button: button))
        XCTAssertNil(SelectionCommentPlacement.origin(
            selection: CGRect(x: 20, y: 500, width: 100, height: 20), container: container, button: button
        ), "scrolled out of view")
        XCTAssertNil(SelectionCommentPlacement.origin(selection: .null, container: container, button: button))
    }
}

final class SelectionCommentCheckTests: XCTestCase {
    /// The guard the removed VM `renderVersion` refusal used to pin: a
    /// composer opened on an older render never saves its stale selection.
    func testRefusesOnlyWhenTheTextWasReRenderedSinceTheComposerOpened() {
        XCTAssertNil(SelectionCommentCheck.refusal(openedOn: "7#2", current: "7#2"))
        XCTAssertEqual(SelectionCommentCheck.refusal(openedOn: "7#2", current: "7#3"), SelectionCommentCheck.staleMessage)
        XCTAssertNotNil(SelectionCommentCheck.refusal(openedOn: "7#2", current: "8#1"), "another document")
    }
}
