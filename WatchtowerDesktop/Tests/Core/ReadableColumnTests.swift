import XCTest
@testable import WatchtowerCore

final class ReadableColumnTests: XCTestCase {
    func testNarrowPaneKeepsTheMinimumInset() {
        XCTAssertEqual(ReadableColumn.horizontalInset(forWidth: 400), ReadableColumn.minInset)
        XCTAssertEqual(ReadableColumn.horizontalInset(forWidth: 0), ReadableColumn.minInset)
    }

    func testWidePaneCentresAColumnOfTheMaximumLineWidth() {
        let width: CGFloat = 1600
        let inset = ReadableColumn.horizontalInset(forWidth: width)
        XCTAssertEqual(inset, 420)
        XCTAssertEqual(width - 2 * inset, ReadableColumn.maxLineWidth)
    }

    func testJustPastTheLineWidthStillHonoursTheMinimumInset() {
        let width = ReadableColumn.maxLineWidth + 10
        XCTAssertEqual(ReadableColumn.horizontalInset(forWidth: width), ReadableColumn.minInset)
    }
}
