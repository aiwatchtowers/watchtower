import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerCore

/// The Knowledge card's row: its hover-only remove button takes no focus
/// and is hidden from VoiceOver while unseen; the row carries the remove
/// as its own VoiceOver action.
@MainActor
final class ProjectKnowledgeRowTests: XCTestCase {
    func testTheHiddenRemoveButtonTakesNoFocusAndTheRowNamesTheAction() throws {
        let row = ProjectKnowledgeRow(item: ProjectKnowledgeItem(id: .file(1), kind: .pdf, title: "spec.pdf")) {}
        let button = try row.inspect().find(ViewType.Button.self)
        XCTAssertTrue(button.isDisabled(), "not hovered: no focus, no click")
        XCTAssertTrue(try button.accessibilityHidden())
        XCTAssertEqual(row.removeLabel, "Remove spec.pdf")

        let source = ProjectKnowledgeRow(item: ProjectKnowledgeItem(id: .source(2), kind: .jira, title: "ACME")) {}
        XCTAssertEqual(source.removeLabel, "Unpin ACME")
    }
}
