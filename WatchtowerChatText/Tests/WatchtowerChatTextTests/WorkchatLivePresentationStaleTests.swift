import Foundation
@testable import WatchtowerChatText
import XCTest

/// The live line's out-of-date wording (#2112 F6): the snapshot's real age in its largest unit.
final class WorkchatLivePresentationStaleTests: XCTestCase {
    func testTheAgeReadsInItsLargestUnit() {
        let cases: [(TimeInterval, String)] = [
            (-5, "0s"), (0, "0s"), (42, "42s"), (59.9, "59s"), (60, "1m"), (2_417, "40m"), (3_599, "59m"),
            (3_600, "1h"), (86_399, "23h"), (86_400, "1d"), (200_000, "2d")
        ]
        for (age, text) in cases {
            XCTAssertEqual(WorkchatLivePresentation.compactAge(age), text, "\(age)")
        }
        XCTAssertEqual(WorkchatLivePresentation.outOfDate(age: 2_417), "Activity out of date · 40m ago")
    }

    func testAStaleRowSaysHowLongAgo() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let live = SessionFeedLive(observedAt: now.addingTimeInterval(-2_417), turnActive: true)
        let row = try XCTUnwrap(WorkchatLivePresentation.row(snapshot: live, error: nil, loaded: true, working: true,
                                                             stateAt: nil, now: now))
        XCTAssertEqual(row.text, "Activity out of date · 40m ago")
        XCTAssertNil(row.elapsed)
        XCTAssertTrue(row.retry)
    }
}
