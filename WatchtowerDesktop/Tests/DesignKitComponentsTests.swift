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

    func testPickerSelectsTheTappedSegmentAndKeepsTheSelectedOne() {
        var selection = "b"
        let binding = Binding(get: { selection }, set: { selection = $0 })
        let flags = ["a", "b", "c"].map { KitSegmentedPicker<String>.isOn($0, selection: binding) }
        XCTAssertEqual(flags.map(\.wrappedValue), [false, true, false])
        flags[2].wrappedValue = true
        XCTAssertEqual(selection, "c")
        XCTAssertEqual(flags.filter(\.wrappedValue).count, 1)
        flags[2].wrappedValue = false
        XCTAssertEqual(selection, "c")
    }

    func testPickerRendersOneToggleOnPerSelection() throws {
        let picker = KitSegmentedPicker(title: "Count", selection: .constant(2), segments: [
            KitSegment(value: 1, title: "One"), KitSegment(value: 2, title: "Two", systemImage: "star")
        ])
        let toggles = try picker.inspect().findAll(ViewType.Toggle.self)
        XCTAssertEqual(toggles.count, 2)
        XCTAssertEqual(try toggles.filter { try $0.isOn() }.count, 1)
    }

    /// The group reads as one container named by the title, its segments inside.
    func testPickerIsAGroupLabelledByItsTitle() throws {
        let picker = KitSegmentedPicker(title: "Range", selection: .constant(1), segments: [
            KitSegment(value: 1, title: "Day"), KitSegment(value: 2, title: "Week")
        ])
        XCTAssertEqual(try picker.inspect().hStack().accessibilityLabel().string(), "Range")
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
