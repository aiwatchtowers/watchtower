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

    /// §2.3: the Mac's model table (`Target.swift:280-300`) for every known
    /// status, an unknown one draws a secondary circle, none is orange.
    func testTargetStatusFollowsTheMacsModelTable() {
        let expected: [(WorkbenchTargetStatus, String, PhoneTone)] = [
            (.todo, "circle", .secondary),
            (.inProgress, "circle.dotted.circle", .blue),
            (.inReview, "eye.circle", .teal),
            (.blocked, "exclamationmark.circle", .red),
            (.done, "checkmark.circle.fill", .green),
            (.dismissed, "xmark.circle", .gray),
            (.snoozed, "moon.circle", .purple)
        ]
        XCTAssertEqual(expected.map(\.0), WorkbenchTargetStatus.knownValues, "the table covers every known status")
        for (status, glyph, tone) in expected + [(WorkbenchTargetStatus(rawValue: "newer"), "circle", .secondary)] {
            let style = TargetStatusStyle.of(status)
            XCTAssertEqual(style.glyph, glyph, status.rawValue)
            XCTAssertEqual(style.tone, tone, status.rawValue)
            XCTAssertNotEqual(style.tone, .orange, status.rawValue)
            XCTAssertEqual(BoardRowModel.status(status).glyph, glyph, "the board row forwards")
        }
    }

    /// §2.4: medium and unknown draw no dot; high is red, low blue; never
    /// orange.
    func testOnlyHighAndLowGetAPriorityDot() {
        XCTAssertEqual(PriorityMark.tone(.high), .red)
        XCTAssertEqual(PriorityMark.tone(.low), .blue)
        XCTAssertNil(PriorityMark.tone(.medium))
        XCTAssertNil(PriorityMark.tone(WorkbenchTargetPriority(rawValue: "newer")))
        XCTAssertEqual(PriorityMark.accessibilityLabel(.high), "High priority")
        XCTAssertEqual(PriorityMark.accessibilityLabel(.low), "Low priority")
        XCTAssertNil(PriorityMark.accessibilityLabel(.medium))
    }
}
