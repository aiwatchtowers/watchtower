import XCTest
@testable import WatchtowerDesktop

/// The target checklist is a 2-column `LazyVGrid`, not a `List`, so SwiftUI's
/// built-in `onMove` is unavailable and each row carries its own
/// `.draggable`/`.dropDestination` pair. `TargetSubItemDrag` owns the two things
/// that silently go wrong in that hand-rolled path: the payload must be scoped
/// to one target (plain text dropped from another app, or a badge dragged from
/// another view, must reorder nothing) and the destination index must be
/// translated into the `move(fromOffsets:toOffset:)` offset, which is one PAST
/// the destination when the item travels downwards.
final class TargetSubItemDragTests: XCTestCase {

    // MARK: - Payload scoping

    func testPayloadRoundTrips() {
        let payload = TargetSubItemDrag.payload(targetID: 42, index: 2)
        XCTAssertEqual(
            TargetSubItemDrag.sourceIndex(from: payload, targetID: 42, itemCount: 5),
            2
        )
    }

    func testRejectsPayloadFromAnotherTarget() {
        let payload = TargetSubItemDrag.payload(targetID: 42, index: 2)
        XCTAssertNil(TargetSubItemDrag.sourceIndex(from: payload, targetID: 43, itemCount: 5))
    }

    func testRejectsForeignText() {
        for text in ["hello", "", "watchtower.target-subitem", "watchtower.target-subitem:42",
                     "watchtower.target-subitem:42:x", "watchtower.target-subitem:42:2:3",
                     "other.prefix:42:2"] {
            XCTAssertNil(
                TargetSubItemDrag.sourceIndex(from: text, targetID: 42, itemCount: 5),
                "expected \"\(text)\" to be rejected"
            )
        }
    }

    /// The list can shrink under a drag in flight (a CLI write, another window,
    /// a Remove from the row's own context menu) — a stale index must be
    /// dropped, not passed to `move(fromOffsets:)`, which traps out of range.
    func testRejectsIndexOutsideCurrentList() {
        XCTAssertNil(
            TargetSubItemDrag.sourceIndex(
                from: TargetSubItemDrag.payload(targetID: 42, index: 5),
                targetID: 42,
                itemCount: 5
            )
        )
        XCTAssertNil(
            TargetSubItemDrag.sourceIndex(
                from: TargetSubItemDrag.payload(targetID: 42, index: -1),
                targetID: 42,
                itemCount: 5
            )
        )
    }

    func testAcceptsFirstAndLastIndex() {
        XCTAssertEqual(
            TargetSubItemDrag.sourceIndex(
                from: TargetSubItemDrag.payload(targetID: 1, index: 0),
                targetID: 1,
                itemCount: 3
            ),
            0
        )
        XCTAssertEqual(
            TargetSubItemDrag.sourceIndex(
                from: TargetSubItemDrag.payload(targetID: 1, index: 2),
                targetID: 1,
                itemCount: 3
            ),
            2
        )
    }

    // MARK: - Move offset

    func testDropOnSelfIsANoOp() {
        XCTAssertNil(TargetSubItemDrag.moveOffset(from: 2, to: 2))
    }

    func testMovingDownwardsOffsetsPastTheDestination() {
        XCTAssertEqual(TargetSubItemDrag.moveOffset(from: 0, to: 3), 4)
    }

    func testMovingUpwardsLandsOnTheDestination() {
        XCTAssertEqual(TargetSubItemDrag.moveOffset(from: 3, to: 0), 0)
    }

    /// The offsets are only correct if they actually reorder the array the way
    /// the user sees it: the dragged item ends up AT the row it was dropped on,
    /// for every source/destination pair in the list.
    func testEveryPairLandsTheItemOnTheDroppedRow() {
        let original = ["a", "b", "c", "d", "e"]
        for source in original.indices {
            for destination in original.indices where source != destination {
                var items = original
                guard let offset = TargetSubItemDrag.moveOffset(from: source, to: destination) else {
                    XCTFail("expected a move for \(source) -> \(destination)")
                    continue
                }
                items.move(fromOffsets: IndexSet(integer: source), toOffset: offset)
                XCTAssertEqual(
                    items[destination], original[source],
                    "\(source) -> \(destination) put \(items[destination]) on the dropped row"
                )
                XCTAssertEqual(items.sorted(), original.sorted(), "move lost or duplicated an item")
            }
        }
    }
}
