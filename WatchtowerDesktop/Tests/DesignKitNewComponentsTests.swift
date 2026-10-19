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

    /// One element labelled by the title, so a control with a hidden label
    /// still reads as the setting.
    func testSettingRowIsOneAccessibilityElementLabelledByTheTitle() throws {
        let row = SettingRow(title: "Notify me", caption: "When a run finishes") {
            Toggle("", isOn: .constant(true)).labelsHidden()
        }
        let root = try row.inspect().hStack()
        XCTAssertEqual(try root.accessibilityLabel().string(), "Notify me")
        XCTAssertEqual(try root.accessibilityHint().string(), "When a run finishes")
    }

    func testSoftButtonsShowTheHoverFillOnlyWhenEnabled() {
        let rest = Color.clear
        func fill(hovered: Bool, enabled: Bool, pressed: Bool = false) -> Color {
            KitSoftButton.fill(restFill: rest, isHovered: hovered, isEnabled: enabled, isPressed: pressed)
        }
        XCTAssertEqual(fill(hovered: true, enabled: true), Fill.hover)
        XCTAssertEqual(fill(hovered: true, enabled: false), rest)
        XCTAssertEqual(fill(hovered: false, enabled: true), rest)
        XCTAssertEqual(fill(hovered: false, enabled: true, pressed: true), Fill.hover)
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

    /// A caller's own `.focused` binding still works on a kit field: setting
    /// it in code reaches the field (the caller sees it true) and the field
    /// then draws its accent border, which the same field without focus
    /// does not draw.
    func testCallersFocusBindingReachesAKitField() async throws {
        let unfocused = try await renderKitField(requestFocus: false)
        XCTAssertFalse(unfocused.focused, "the field took focus nobody asked for")
        XCTAssertFalse(Self.hasAccentLine(unfocused.rep), "an accent border on the unfocused field")

        let focused = try await renderKitField(requestFocus: true)
        XCTAssertTrue(focused.focused, "the caller's focus binding did not follow its own write")
        XCTAssertTrue(Self.hasAccentLine(focused.rep), "no accent border on the focused field")
    }

    private final class FocusBox { var focused = false }

    private struct FocusHarness: View {
        let box: FocusBox
        let requestFocus: Bool
        @FocusState private var callerFocus: Bool
        @State private var text = ""
        var body: some View {
            TextField("Search acme", text: $text)
                .textFieldStyle(.kit)
                .focused($callerFocus)
                .onChange(of: callerFocus) { _, new in box.focused = new }
                .frame(width: 200, height: 40)
                .padding(Spacing.regular)
                .task { if requestFocus { callerFocus = true } }
        }
    }

    /// Hosts the field in a key window, waits (up to 5 s) for a requested
    /// focus to land, and renders it. Skips when the window cannot become
    /// key here (a headless runner), since focus then never arrives.
    private func renderKitField(requestFocus: Bool) async throws -> (focused: Bool, rep: NSBitmapImageRep) {
        let box = FocusBox()
        let host = NSHostingView(rootView: FocusHarness(box: box, requestFocus: requestFocus))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let deadline = Date().addingTimeInterval(requestFocus ? 5 : 0.5)
        while Date() < deadline, !(requestFocus && box.focused) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if requestFocus, !box.focused, !window.isKeyWindow {
            throw XCTSkip("the test window cannot become key here, so focus never arrives")
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return (box.focused, rep)
    }

    /// A long saturated horizontal line: the accent border's top or bottom edge.
    private static func hasAccentLine(_ rep: NSBitmapImageRep) -> Bool {
        for y in 0..<rep.pixelsHigh {
            var run = 0
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let spread = max(c.redComponent, c.greenComponent, c.blueComponent)
                    - min(c.redComponent, c.greenComponent, c.blueComponent)
                run = spread > 0.3 ? run + 1 : 0
                if run >= 100 { return true }
            }
        }
        return false
    }
}
