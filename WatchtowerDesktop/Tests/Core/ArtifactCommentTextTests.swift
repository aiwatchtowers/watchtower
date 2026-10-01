import XCTest
@testable import WatchtowerCore

/// #181: the text an artifact's comments anchor on is rendered the way the
/// artifact reads — markdown for a document, a table for CSV.
final class ArtifactCommentTextTests: XCTestCase {
    func testADocumentRendersItsMarkdown() {
        let doc = ArtifactCommentText.render(kind: "document", content: "# Plan\n\n- **one**\n\n| A | B |\n|---|---|\n| 1 | 2 |")
        XCTAssertFalse(doc.text.contains("#") || doc.text.contains("*") || doc.text.contains("|"), doc.text)
        XCTAssertEqual(doc.headings.map(\.title), ["Plan"])
    }

    func testATableArtifactRendersItsCSVAsATable() {
        let doc = ArtifactCommentText.render(kind: "table", content: "Name,Owner\nretry,ops\n")
        XCTAssertEqual(doc.text, "Name\nOwner\nretry\nops\n\n")
        XCTAssertTrue(doc.runs.contains { if case .tableCell = $0.style { return true } else { return false } })
    }

    func testCodeIsOneCodeBlockAndMessagesAreVerbatim() {
        let code = ArtifactCommentText.render(kind: "code", content: "let x = 1 // *not emphasis*")
        XCTAssertEqual(code.text, "let x = 1 // *not emphasis*")
        XCTAssertEqual(code.runs.map(\.style), [.codeBlock])
        let mail = ArtifactCommentText.render(kind: "email", content: "Hi *team*,")
        XCTAssertEqual(mail.text, "Hi *team*,", "a draft message shows exactly what will be sent")
        XCTAssertTrue(mail.runs.isEmpty)
    }
}
