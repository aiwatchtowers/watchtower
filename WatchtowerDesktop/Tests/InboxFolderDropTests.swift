import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// A folder drop's loaded data: the live drag's own folder moves; anything
/// else ends the drag at once, so no stale drag outlives a failed drop.
final class InboxFolderDropTests: XCTestCase {
    private let drop = InboxFolderDrop(targetID: 3, placement: .into)

    func testTheLiveDragsFolderMoves() {
        XCTAssertEqual(FolderDropDelegate.action(for: Data("5".utf8), draggedID: 5, drop: drop),
                       .drop(dragged: 5, drop))
    }

    func testEveryOtherAnswerEndsTheDrag() {
        XCTAssertEqual(FolderDropDelegate.action(for: nil, draggedID: 5, drop: drop), .endDrag, "no data")
        XCTAssertEqual(FolderDropDelegate.action(for: Data("five".utf8), draggedID: 5, drop: drop), .endDrag,
                       "not an id")
        XCTAssertEqual(FolderDropDelegate.action(for: Data([0xFF, 0xFE]), draggedID: 5, drop: drop), .endDrag,
                       "not text")
        XCTAssertEqual(FolderDropDelegate.action(for: Data("6".utf8), draggedID: 5, drop: drop), .endDrag,
                       "another folder than the drag")
    }
}
