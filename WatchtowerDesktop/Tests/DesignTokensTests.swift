import XCTest
import SwiftUI
@testable import WatchtowerDesktop

/// The design tokens carry the style guide's scale (spec §1–§4); a changed value
/// is a deliberate design change, so these pin it.
final class DesignTokensTests: XCTestCase {
    func testSpacingScaleMatchesTheSpec() {
        XCTAssertEqual([Spacing.tight, Spacing.small, Spacing.compact, Spacing.regular, Spacing.cozy,
                        Spacing.medium, Spacing.large, Spacing.page, Spacing.wide, Spacing.hero],
                       [2, 4, 6, 8, 10, 12, 16, 20, 24, 40])
    }

    func testRadiiMatchTheSpec() {
        XCTAssertEqual([Radius.mark, Radius.control, Radius.row, Radius.container, Radius.bubble, Radius.pill],
                       [4, 6, 8, 10, 16, 18])
    }

    func testFillOpacitiesMatchTheSpec() {
        XCTAssertEqual([Fill.restOpacity, Fill.cardOpacity, Fill.hoverOpacity, Fill.selectedOpacity, Fill.onOpacity],
                       [0.04, 0.06, 0.07, 0.12, 0.20])
        XCTAssertEqual(ChipTint.fillOpacity, 0.14)
        XCTAssertEqual(ChipTint.strokeOpacity, 0.3)
        XCTAssertEqual(Stroke.hairline, 0.5)
        XCTAssertEqual(Stroke.selection, 1.5)
    }

    func testToneKeepsTheTargetsTabMapping() {
        XCTAssertEqual(Tone.status("teal"), .teal)
        XCTAssertEqual(Tone.status("nope"), .secondary)
        XCTAssertEqual(Tone.priority("high"), .red)
        XCTAssertEqual(Tone.priority("low"), .blue)
        XCTAssertEqual(Tone.priority("medium"), .orange)
    }
}
