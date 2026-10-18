import SwiftUI
@testable import ViewInspector
import XCTest
@testable import WatchtowerDesktop

@MainActor
final class DesignKitComponentsTests: XCTestCase {
    func testSegmentFillFollowsOnAndHover() {
        XCTAssertEqual(SegmentedToggleStyle.fill(isOn: true, isHovered: false), Color.accentColor.opacity(0.20))
        XCTAssertEqual(SegmentedToggleStyle.fill(isOn: false, isHovered: true), Color.primary.opacity(0.07))
        XCTAssertEqual(SegmentedToggleStyle.fill(isOn: false, isHovered: false), .clear)
    }

    func testSegmentReportsHoverToItsParent() throws {
        var reported = false
        let style = SegmentedToggleStyle(isHovered: false) { reported = $0 }
        let button = try style.inspect(isOn: false).find(ViewType.Button.self)
        // ViewInspector's own `callOnHover` is commented out upstream; this
        // reads the same modifier callback it would call.
        let callback = try button.modifierAttribute(
            modifierName: "_HoverRegionModifier", path: "modifier|callback",
            type: ((Bool) -> Void).self, call: "onHover")
        callback(true)
        XCTAssertTrue(reported)
    }

    func testSectionHeaderHidesAZeroCount() throws {
        let view = SectionHeader(title: "Asks", systemImage: "x", count: 0)
        XCTAssertThrowsError(try view.inspect().find(text: "0"))
    }

    func testReadOnlyMenuLabelHasNoChevron() throws {
        let readOnly = MenuLabel(text: "Done", systemImage: "checkmark", color: .green, isMenu: false)
        XCTAssertFalse(try hasChevron(readOnly))
        XCTAssertTrue(try hasChevron(MenuLabel(text: "Open", systemImage: "circle", color: .blue)))
    }

    private func hasChevron(_ label: MenuLabel) throws -> Bool {
        try label.inspect().findAll(ViewType.Image.self).contains { try $0.actualImage().name() == "chevron.down" }
    }
}
