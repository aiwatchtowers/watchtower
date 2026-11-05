import XCTest
@testable import WatchtowerCore

final class AutomationEditorModeTests: XCTestCase {
    func testInitialMode() {
        XCTAssertEqual(AutomationEditorMode.initial(toolsAvailable: true), .chat)
        // Ollama has no tools: the chat cannot draft, so the form comes first.
        XCTAssertEqual(AutomationEditorMode.initial(toolsAvailable: false), .form)
        XCTAssertEqual(AutomationEditorMode.allCases, [.chat, .form, .script])
        XCTAssertEqual(AutomationEditorMode.allCases.map(\.title), ["Chat", "Form", "Script"])
    }

    /// The draft column's steps, in the picker's order (spec "The Look step").
    func testEditorSteps() {
        XCTAssertEqual(AutomationEditorStep.allCases, [.collects, .look, .schedule])
        XCTAssertEqual(AutomationEditorStep.allCases.map(\.title), ["What it collects", "Look", "When it runs"])
    }
}
