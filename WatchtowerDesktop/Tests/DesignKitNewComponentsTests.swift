import AppKit
import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop

/// The kit's new components (style guide #719, Task 6): settings rows with a
/// small switch and no dividers, the secondary button's disabled plate, the
/// row fill and the panel split's hidden panel.
@MainActor
final class DesignKitNewComponentsTests: XCTestCase {
    func testSettingRowStylesAToggleAsASmallSwitch() throws {
        let row = SettingRow(title: "Notify me", caption: "When a run finishes") {
            Toggle("Notify me", isOn: .constant(true)).labelsHidden()
        }
        let toggle = try row.inspect().find(ViewType.Toggle.self)
        XCTAssertTrue(try toggle.toggleStyle() is SwitchToggleStyle)
        XCTAssertEqual(try toggle.controlSize(), .small)
        XCTAssertNoThrow(try row.inspect().find(text: "When a run finishes"))
    }

    func testSettingsSectionDrawsNoDivider() throws {
        let section = SettingsSection(title: "General", footer: "Applies to acme only") {
            SettingRow(title: "One") { Toggle("One", isOn: .constant(true)) }
            SettingRow(title: "Two") { Toggle("Two", isOn: .constant(false)) }
        }
        XCTAssertNoThrow(try section.inspect().find(text: "General"))
        XCTAssertNoThrow(try section.inspect().find(text: "Applies to acme only"))
        XCTAssertThrowsError(try section.inspect().find(ViewType.Divider.self))
    }

    func testSecondaryButtonDimsWhenDisabled() throws {
        let probe = ViewRenderProbe(size: NSSize(width: 120, height: 40))
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        func plate(disabled: Bool) throws -> ViewRenderProbe.RGBA {
            let view = Button("Cancel") {}
                .buttonStyle(.kitSecondary)
                .disabled(disabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(Spacing.regular)
                .background(Color.white)
            // Inside the plate, left of the label.
            return try probe.pixel(probe.render(view, aqua), x: Int(Spacing.regular) + 3, y: Int(Spacing.regular) + 10)
        }
        let enabled = try plate(disabled: false)
        let disabled = try plate(disabled: true)
        XCTAssertLessThan(enabled.red, 250, "no plate drawn: \(enabled)")
        XCTAssertGreaterThan(disabled.red, enabled.red, "disabled \(disabled) not lighter than enabled \(enabled)")
    }

    func testKitRowFillFollowsSelection() {
        XCTAssertEqual(KitRow.fill(isSelected: true, isHovered: true), Fill.selected)
        XCTAssertEqual(KitRow.fill(isSelected: true, isHovered: false), Fill.selected)
        XCTAssertEqual(KitRow.fill(isSelected: false, isHovered: true), Fill.hover)
        XCTAssertEqual(KitRow.fill(isSelected: false, isHovered: false), .clear)
    }

    func testPanelSplitHidesThePanel() throws {
        let width = PanelSplitWidth(key: "DesignKitNewComponentsTests.panelWidth", range: 200...400, ideal: 260)
        let hidden = PanelSplit(isPanelShown: false, width: width) { Text("main") } panel: { Text("panel") }
        XCTAssertNoThrow(try hidden.inspect().find(text: "main"))
        XCTAssertThrowsError(try hidden.inspect().find(text: "panel"))

        let shown = PanelSplit(isPanelShown: true, width: width) { Text("main") } panel: { Text("panel") }
        XCTAssertNoThrow(try shown.inspect().find(text: "panel"))
    }
}
