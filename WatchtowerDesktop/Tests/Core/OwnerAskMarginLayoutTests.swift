import XCTest
@testable import WatchtowerCore

final class OwnerAskMarginLayoutTests: XCTestCase {
    func testWithoutCommentsTheMarginTakesNoWidth() {
        XCTAssertEqual(OwnerAskMarginLayout.width(total: 1200, comments: 0), 0)
        XCTAssertEqual(OwnerAskMarginLayout.tops([]), [])
        XCTAssertGreaterThan(OwnerAskMarginLayout.width(total: 1200, comments: 1), 0)
    }

    func testTheMarginStaysWithinItsBounds() {
        XCTAssertEqual(OwnerAskMarginLayout.width(total: 400, comments: 2), OwnerAskMarginLayout.minWidth)
        XCTAssertEqual(OwnerAskMarginLayout.width(total: 3000, comments: 2), OwnerAskMarginLayout.maxWidth)
    }

    func testCommentsOnOverlappingLinesDoNotOverlap() {
        let items: [OwnerAskMarginLayout.Item] = [
            .init(anchorY: 100, height: 60),
            .init(anchorY: 110, height: 40),
            .init(anchorY: 400, height: 30)
        ]
        let tops = OwnerAskMarginLayout.tops(items)
        XCTAssertEqual(tops[0], 100, "the first sits at its line")
        XCTAssertEqual(tops[1], 100 + 60 + OwnerAskMarginLayout.spacing, "pushed below the first")
        XCTAssertEqual(tops[2], 400, "one with room stays at its line")
        for (a, b) in zip(items.indices, items.indices.dropFirst()) {
            XCTAssertLessThanOrEqual(tops[a] + items[a].height, tops[b])
        }
    }

    func testOrderFollowsTheLinesNotTheInput() {
        let tops = OwnerAskMarginLayout.tops([.init(anchorY: 200, height: 50), .init(anchorY: 190, height: 50)])
        XCTAssertEqual(tops[1], 190, "the higher anchor keeps its place")
        XCTAssertEqual(tops[0], 190 + 50 + OwnerAskMarginLayout.spacing)
    }

    func testCommentsWithoutAPlaceFollowTheRest() {
        let tops = OwnerAskMarginLayout.tops([.init(anchorY: nil, height: 30), .init(anchorY: 20, height: 40)])
        XCTAssertEqual(tops[1], 20)
        XCTAssertEqual(tops[0], 20 + 40 + OwnerAskMarginLayout.spacing)
        XCTAssertEqual(OwnerAskMarginLayout.tops([.init(anchorY: nil, height: 30)]), [0], "alone, at the top")
    }

    func testAScrolledOffAnchorStillPushesTheNextOne() {
        let tops = OwnerAskMarginLayout.tops([.init(anchorY: -50, height: 80), .init(anchorY: 0, height: 20)])
        XCTAssertEqual(tops, [-50, -50 + 80 + OwnerAskMarginLayout.spacing])
    }
}
