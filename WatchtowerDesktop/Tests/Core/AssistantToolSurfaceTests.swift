import XCTest
@testable import WatchtowerCore

final class AssistantToolSurfaceTests: XCTestCase {
    func testEveryRegistrySurfaceHasAHumanLabel() {
        XCTAssertEqual(AssistantToolSurface.label(for: "main"), "Chat")
        XCTAssertEqual(AssistantToolSurface.label(for: "target"), "Target chat")
        XCTAssertEqual(AssistantToolSurface.label(for: "reaction"), "Slack reactions")
        XCTAssertEqual(AssistantToolSurface.label(for: "project"), "Workbench")
    }

    /// `tools.AutomationSurface` is a trust place since Automations P2: Settings
    /// shows its switch as "Automations".
    func testAutomationLabel() {
        XCTAssertEqual(AssistantToolSurface.label(for: "automation"), "Automations")
    }

    /// `tools.AutomationEditorSurface` (Automations P3): save_automation's
    /// places on Settings → Assistant tools include the editor chat.
    func testAutomationEditorLabel() {
        XCTAssertEqual(AssistantToolSurface.label(for: "automation_editor"), "Automation editor")
    }

    /// A surface added on the Go side before its label still shows, as its id.
    func testAnUnknownSurfaceShowsItsID() {
        XCTAssertEqual(AssistantToolSurface.label(for: "brand_new"), "brand_new")
    }
}
