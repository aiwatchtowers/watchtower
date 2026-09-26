import XCTest
@testable import WatchtowerCore

final class TargetTreeScopeTests: XCTestCase {
    // Tree: 1 → 2 → 3 → 4, plus 5 (child of 1, sibling branch of 2)
    // and 9 (unrelated root).
    private let parents: [Int: Int?] = [1: nil, 2: 1, 3: 2, 4: 3, 5: 1, 9: nil]

    func testCurrentItselfIsInScope() {
        XCTAssertTrue(TargetTreeScope.isInScope(addressed: 3, current: 3, parents: parents))
    }

    func testDirectChildIsInScope() {
        XCTAssertTrue(TargetTreeScope.isInScope(addressed: 3, current: 2, parents: parents))
    }

    func testDeepDescendantIsInScope() {
        XCTAssertTrue(TargetTreeScope.isInScope(addressed: 4, current: 1, parents: parents))
    }

    func testDirectParentIsInScope() {
        XCTAssertTrue(TargetTreeScope.isInScope(addressed: 2, current: 3, parents: parents))
    }

    func testRootAncestorIsInScope() {
        XCTAssertTrue(TargetTreeScope.isInScope(addressed: 1, current: 4, parents: parents))
    }

    func testSiblingBranchIsOutOfScope() {
        XCTAssertFalse(TargetTreeScope.isInScope(addressed: 5, current: 2, parents: parents))
        XCTAssertFalse(TargetTreeScope.isInScope(addressed: 2, current: 5, parents: parents))
    }

    func testUnrelatedRootIsOutOfScope() {
        XCTAssertFalse(TargetTreeScope.isInScope(addressed: 9, current: 3, parents: parents))
    }

    func testUnknownIDIsOutOfScope() {
        XCTAssertFalse(TargetTreeScope.isInScope(addressed: 77, current: 3, parents: parents))
    }

    func testParentCycleDoesNotHang() {
        // Corrupt data: 10 ↔ 11 parent cycle. Must terminate and reject 3.
        let cyclic: [Int: Int?] = [10: 11, 11: 10, 3: nil]
        XCTAssertFalse(TargetTreeScope.isInScope(addressed: 10, current: 3, parents: cyclic))
        XCTAssertFalse(TargetTreeScope.isInScope(addressed: 3, current: 10, parents: cyclic))
        // Within the cycle, each is the other's ancestor — in scope, must terminate.
        XCTAssertTrue(TargetTreeScope.isInScope(addressed: 11, current: 10, parents: cyclic))
    }
}
