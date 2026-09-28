import XCTest
@testable import WatchtowerCore

/// The branch tree behind regenerate/edit (spec §2.3). Fixture:
///   1 user ─ 2 asst ─ 3 user ─┬ 4 asst
///                   │          └ 5 asst   (regenerate of 4)
///                   └ 6 user ─ 7 asst     (edit of 3)
final class ChatTreeTests: XCTestCase {
    private let tree = ChatTree(nodes: [
        .init(id: 1, parentID: nil), .init(id: 2, parentID: 1), .init(id: 3, parentID: 2),
        .init(id: 4, parentID: 3), .init(id: 5, parentID: 3), .init(id: 6, parentID: 2),
        .init(id: 7, parentID: 6)
    ])

    func testPathRunsRootToLeaf() {
        XCTAssertEqual(tree.path(toLeaf: 5), [1, 2, 3, 5])
        XCTAssertEqual(tree.path(toLeaf: 7), [1, 2, 6, 7])
    }

    func testUnknownLeafYieldsEmptyPath() {
        XCTAssertEqual(tree.path(toLeaf: 99), [])
    }

    func testSiblingsShareAParentInIdOrder() {
        XCTAssertEqual(tree.siblings(of: 5), [4, 5])
        XCTAssertEqual(tree.siblings(of: 3), [3, 6])
        XCTAssertEqual(tree.siblings(of: 1), [1])
    }

    func testRootsAreSiblingsOfEachOther() {
        let forest = ChatTree(nodes: [.init(id: 1, parentID: nil), .init(id: 10, parentID: nil)])
        XCTAssertEqual(forest.siblings(of: 10), [1, 10])
    }

    func testNewestLeafIsTheHighestIdLeafUnderTheNode() {
        XCTAssertEqual(tree.newestLeaf(under: 3), 5)
        XCTAssertEqual(tree.newestLeaf(under: 2), 7)
        XCTAssertEqual(tree.newestLeaf(under: 4), 4)
    }

    /// A corrupt parent cycle must terminate, not hang the UI.
    func testParentCycleTerminates() {
        let cyclic = ChatTree(nodes: [.init(id: 8, parentID: 9), .init(id: 9, parentID: 8)])
        XCTAssertEqual(cyclic.path(toLeaf: 8).count, 2)
    }
}
