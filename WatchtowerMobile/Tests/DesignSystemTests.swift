import SwiftUI
import WatchtowerKit
import XCTest
@testable import WatchtowerMobile

/// The phone's design layer (design pass spec §2): tones, metrics, the
/// target status table, the priority dot, card paints and the wrapping row.
final class DesignSystemTests: XCTestCase {
    /// §2.2: teal (in review) and gray (dismissed) are the system colours.
    func testTheNewTonesAreTheSystemTealAndGray() {
        XCTAssertEqual(PhoneTone.teal.color, .teal)
        XCTAssertEqual(PhoneTone.gray.color, .gray)
        XCTAssertNotEqual(PhoneTone.waitingForYou, .teal)
        XCTAssertNotEqual(PhoneTone.waitingForYou, .gray)
    }

    /// §2.9: the Mac's spacing steps plus 20 for page margins; one radius
    /// per role; the flat row's insets.
    func testTheMetricsNameTheMacsSteps() {
        XCTAssertEqual(
            [Spacing.tight, Spacing.small, Spacing.compact, Spacing.regular, Spacing.medium, Spacing.large, Spacing.page],
            [2, 4, 6, 8, 12, 16, 20]
        )
        XCTAssertEqual([Radius.chip, Radius.row, Radius.card], [6, 8, 12])
        XCTAssertEqual(RowInsets.flat, EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        XCTAssertEqual(RowInsets.card, EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}
