import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class GenerateRecapSheetViewTests: XCTestCase {

    /// Header label «AI Recap» виден.
    func testHeaderLabelVisible() throws {
        let view = GenerateRecapSheet(eventID: "ev1")
        XCTAssertNoThrow(try view.inspect().find(text: "AI Recap"))
    }

    /// Описательный текст в редакторе виден.
    func testEditorHelperTextVisible() throws {
        let view = GenerateRecapSheet(eventID: "ev1")
        XCTAssertNoThrow(try view.inspect().find(
            text: "Paste a recap, transcript fragment, or rough notes. The AI will produce a structured summary (decisions, action items, open questions)."
        ))
    }

    /// Без prefilledText кнопка футера называется "Generate".
    func testGenerateLabelWhenNoPrefill() throws {
        let view = GenerateRecapSheet(eventID: "ev1", prefilledText: "")
        XCTAssertNoThrow(try view.inspect().find(text: "Generate"))
    }

    /// С prefilledText кнопка футера называется "Re-generate".
    func testRegenerateLabelWhenPrefilled() throws {
        let view = GenerateRecapSheet(eventID: "ev1", prefilledText: "draft notes")
        XCTAssertNoThrow(try view.inspect().find(text: "Re-generate"))
    }

    /// Кнопка Cancel присутствует.
    func testCancelButtonPresent() throws {
        let view = GenerateRecapSheet(eventID: "ev1")
        XCTAssertNoThrow(try view.inspect().find(button: "Cancel"))
    }
}
