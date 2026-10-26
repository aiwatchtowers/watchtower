import SwiftUI
import WatchtowerDesign
import XCTest

/// Pins every value of the Tokens table in `docs/design/desktop-style-guide.md`
/// (Surface excepted: it stays macOS-only in the Desktop's DesignKit). The
/// Desktop and the phone read these one copy; a changed value fails here
/// before it moves either app's pixels.
final class TokenTests: XCTestCase {
    func testSpacingSteps() {
        XCTAssertEqual(
            [Spacing.tight, Spacing.small, Spacing.compact, Spacing.regular, Spacing.cozy,
             Spacing.medium, Spacing.large, Spacing.page, Spacing.wide, Spacing.hero],
            [2, 4, 6, 8, 10, 12, 16, 20, 24, 40]
        )
    }

    func testRadii() {
        XCTAssertEqual(
            [Radius.mark, Radius.control, Radius.row, Radius.container, Radius.bubble, Radius.pill],
            [4, 6, 8, 10, 16, 18]
        )
    }

    func testFillsArePrimaryForNeutralAndAccentForSelectedAndOn() {
        XCTAssertEqual(
            [Fill.restOpacity, Fill.cardOpacity, Fill.hoverOpacity, Fill.selectedOpacity, Fill.onOpacity],
            [0.04, 0.06, 0.07, 0.12, 0.20]
        )
        XCTAssertEqual(Fill.rest, Color.primary.opacity(0.04))
        XCTAssertEqual(Fill.card, Color.primary.opacity(0.06))
        XCTAssertEqual(Fill.hover, Color.primary.opacity(0.07))
        XCTAssertEqual(Fill.selected, Color.accentColor.opacity(0.12))
        XCTAssertEqual(Fill.on, Color.accentColor.opacity(0.20))
    }

    func testChipTint() {
        XCTAssertEqual(ChipTint.fillOpacity, 0.14)
        XCTAssertEqual(ChipTint.strokeOpacity, 0.3)
        XCTAssertEqual(ChipTint.strokeWidth, 0.5)
    }

    func testStrokes() {
        XCTAssertEqual(Stroke.hairline, 0.5)
        XCTAssertEqual(Stroke.selection, 1.5)
    }

    func testStatusColourMapWithANeutralFallback() {
        let expected: [String: Color] = [
            "blue": .blue, "teal": .teal, "red": .red, "green": .green,
            "gray": .gray, "purple": .purple, "newer": .secondary
        ]
        for (name, color) in expected {
            XCTAssertEqual(Tone.status(name), color, name)
        }
    }

    func testPriorityColourMap() {
        XCTAssertEqual(Tone.priority("high"), .red)
        XCTAssertEqual(Tone.priority("low"), .blue)
        XCTAssertEqual(Tone.priority("medium"), .orange)
        XCTAssertEqual(Tone.priority("newer"), .orange)
    }

    func testSharedStateTones() {
        XCTAssertEqual(Tone.warning, .orange)
        XCTAssertEqual(Tone.success, .green)
        XCTAssertEqual(Tone.error, .red)
        XCTAssertEqual(Tone.now, .orange)
    }

    func testIconSizes() {
        XCTAssertEqual(
            [IconSize.chevron, IconSize.header, IconSize.composer, IconSize.composerLarge, IconSize.tile],
            [8, 14, 16, 24, 26]
        )
    }

    func testPaneWidths() {
        XCTAssertEqual(
            [PaneWidth.sideListMin, PaneWidth.sideListIdeal, PaneWidth.sideListMax,
             PaneWidth.detailMin, PaneWidth.narrowPage, PaneWidth.gridCardMin],
            [170, 220, 360, 260, 420, 240]
        )
    }

    func testTracking() {
        XCTAssertEqual(Tracking.caps, 0.6)
    }

    func testMotion() {
        XCTAssertEqual(Motion.toggle, .snappy(duration: 0.15))
        XCTAssertEqual(Motion.panel, .easeInOut(duration: 0.2))
    }

    func testFloatingShadow() {
        XCTAssertEqual(FloatingShadow.color, Color.black.opacity(0.2))
        XCTAssertEqual(FloatingShadow.radius, 3)
        XCTAssertEqual(FloatingShadow.y, 1)
    }
}
