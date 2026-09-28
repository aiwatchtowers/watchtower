import XCTest
import SwiftUI
import ViewInspector
import WatchtowerCore
@testable import WatchtowerDesktop

@MainActor
final class ArtifactCardViewTests: XCTestCase {
    private let draft = ArtifactDraft(key: "q3", kind: "document", title: "Q3 plan", meta: [:], content: "x", isComplete: false)

    func testWritingStateShowsProgressTitle() throws {
        let card = ArtifactCardView(draft: draft, isWriting: true, version: nil) {}
        XCTAssertNoThrow(try card.inspect().find(text: "Writing Q3 plan…"))
    }

    func testDoneStateShowsTitleVersionAndOpens() throws {
        var opened = 0
        let card = ArtifactCardView(draft: draft, isWriting: false, version: 2) { opened += 1 }
        XCTAssertNoThrow(try card.inspect().find(text: "Q3 plan"))
        XCTAssertNoThrow(try card.inspect().find(text: "Document · v2"))
        try card.inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(opened, 1)
    }

    // `AssistantMessageBody` extends Task 14's existing type in
    // ChatMessageRow.swift (steps/isRunning), not a fresh `isStreaming` init
    // (preflight A36) — `steps: []`/`isRunning: false` is the "not streaming"
    // shape the brief's `isStreaming: false` meant.
    func testAssistantBodySplitsMarkdownAndCards() throws {
        let text = "Intro\n:::artifact key=\"q3\" kind=\"table\" title=\"Numbers\"\na,b\n:::\nOutro"
        let body = AssistantMessageBody(text: text, steps: [], isRunning: false, versions: ["q3": 1]) { _ in }
        XCTAssertNoThrow(try body.inspect().find(ArtifactCardView.self))
        XCTAssertNoThrow(try body.inspect().find(text: "Table · v1"))
    }
}
