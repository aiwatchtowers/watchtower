import XCTest
@testable import WatchtowerCore

final class SwitcherSegmentTests: XCTestCase {
    func testWorkbenchTonesMapOntoTheNeutralTones() {
        typealias Segment = WorkbenchSwitcherPresentation.Segment
        XCTAssertEqual(Segment(text: "2 new comments", tone: .comments).switcherSegment,
                       SwitcherSegment(text: "2 new comments", tone: .badge))
        XCTAssertEqual(Segment(text: "1 blocked", tone: .blocked).switcherSegment,
                       SwitcherSegment(text: "1 blocked", tone: .warning))
        XCTAssertEqual(Segment(text: "1 working", tone: .sessions).switcherSegment,
                       SwitcherSegment(text: "1 working", tone: .secondary))
        XCTAssertEqual(Segment(text: "2h", tone: .age).switcherSegment,
                       SwitcherSegment(text: "2h", tone: .secondary))
    }
}
