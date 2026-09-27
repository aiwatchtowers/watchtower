import XCTest
@testable import WatchtowerCore

/// The auto-scroll "is the user at the bottom" decision (Task P): a
/// streaming delta or a new message should only pull the viewport down while
/// this stays true, never yank the user back down after they scrolled up.
final class ChatAutoScrollPolicyTests: XCTestCase {
    func testConstant() {
        XCTAssertEqual(ChatAutoScrollPolicy.bottomThreshold, 40)
    }

    func testExactlyAtTheBottomIsAtBottom() {
        XCTAssertTrue(ChatAutoScrollPolicy.isAtBottom(distanceFromBottom: 0))
    }

    func testNegativeDistanceOverscrollIsAtBottom() {
        XCTAssertTrue(ChatAutoScrollPolicy.isAtBottom(distanceFromBottom: -12))
    }

    func testWithinThresholdIsAtBottom() {
        XCTAssertTrue(ChatAutoScrollPolicy.isAtBottom(distanceFromBottom: 40))
    }

    func testJustPastThresholdIsNotAtBottom() {
        XCTAssertFalse(ChatAutoScrollPolicy.isAtBottom(distanceFromBottom: 40.01))
    }

    func testFarScrolledUpIsNotAtBottom() {
        XCTAssertFalse(ChatAutoScrollPolicy.isAtBottom(distanceFromBottom: 400))
    }
}
