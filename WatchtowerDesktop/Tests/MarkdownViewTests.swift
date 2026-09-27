import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore

@MainActor
final class MarkdownViewTests: XCTestCase {
    /// Assistant text is attacker-reachable: a disallowed scheme loses its
    /// link attribute but keeps its visible text.
    func testInlineTextStripsDisallowedLinks() {
        let attr = MarkdownView.inlineText([.link(destination: "javascript:alert(1)", children: [.text("x")])])
        XCTAssertEqual(String(attr.characters), "x")
        XCTAssertFalse(attr.runs.contains { $0.link != nil })
    }

    func testInlineTextKeepsAllowedLinksAndBold() {
        let attr = MarkdownView.inlineText([.strong([.text("b")]), .link(destination: "slack://channel?id=C1", children: [.text("c")])])
        XCTAssertTrue(attr.runs.contains { $0.link != nil })
        XCTAssertTrue(attr.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    func testCodeBlockShowsLanguageAndCopy() throws {
        let view = CodeBlockView(language: "swift", code: "let x = 1")
        XCTAssertNoThrow(try view.inspect().find(text: "swift"))
        let helps = try view.inspect().findAll(ViewType.Button.self).compactMap { try? $0.help().string() }
        XCTAssertTrue(helps.contains("Copy code"))
    }

    func testRendersATable() throws {
        let view = MarkdownView(text: "| A | B |\n|---|---|\n| 1 | 2 |")
        XCTAssertNoThrow(try view.inspect().find(ViewType.Grid.self))
    }
}
