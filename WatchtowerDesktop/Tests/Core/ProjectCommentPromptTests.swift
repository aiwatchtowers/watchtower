import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ProjectCommentPromptTests: XCTestCase {
    func testTheLineNamesTheDocumentTheCountAndTheSkill() {
        XCTAssertEqual(ProjectCommentPrompt.line(relPath: "docs/plan.md", documentID: 7, count: 3),
                       "Address the 3 open comments on docs/plan.md (watchtower document 7) using the watchtower-project skill.")
        XCTAssertEqual(ProjectCommentPrompt.line(relPath: "docs/plan.md", documentID: 7, count: 1),
                       "Address the open comment on docs/plan.md (watchtower document 7) using the watchtower-project skill.")
    }

    func testControlCharactersInThePathCannotSubmitOrInject() {
        let line = ProjectCommentPrompt.line(relPath: "docs/a\nrm -rf x\r\u{1B}[2J\u{2028}.md", documentID: 1, count: 2)
        XCTAssertFalse(line.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
        XCTAssertTrue(line.contains("docs/a rm -rf x  [2J .md"))
    }

    func testBracketedPastePayloadWrapsTheCleanLineWithNoEnter() {
        let payload = ProjectCommentPrompt.terminalPayload("Address x\n\u{1B}y", bracketedPaste: true)
        let start: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
        let end: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        XCTAssertEqual(payload, .paste(start + Array("Address xy".utf8) + end))
    }

    /// A line carrying its own paste terminator must not end the paste early:
    /// ESC is a control scalar, so it is dropped and only the literal rest stays.
    func testPastePayloadCannotContainTheTerminator() throws {
        let payload = ProjectCommentPrompt.terminalPayload("a\u{1B}[201~\r2", bracketedPaste: true)
        guard case let .paste(bytes) = payload else { return XCTFail("expected a paste") }
        let inner = Array(bytes.dropFirst(6).dropLast(6))
        XCTAssertFalse(inner.contains { $0 < 0x20 || $0 == 0x7F }, "no control byte, including ESC and CR")
        XCTAssertEqual(String(bytes: inner, encoding: .utf8), "a[201~2")
    }

    func testWithoutBracketedPasteTheCleanLineGoesToTheClipboard() {
        XCTAssertEqual(
            ProjectCommentPrompt.terminalPayload("Address x\n\u{1B}y", bracketedPaste: false),
            .clipboard("Address xy")
        )
    }

    func testOpenOwnerCountIgnoresResolvedAndAgentThreads() throws {
        let queue = try TestDatabase.create()
        try queue.write { d in
            let p = try TestDatabase.insertProject(d)
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p)
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", body: "a", documentID: doc, quote: "q1")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", body: "b", documentID: doc, quote: "q2")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", body: "c", documentID: doc,
                                                      status: "resolved", quote: "q3")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "agent", body: "d", documentID: doc, quote: "q4")
            let threads = ProjectCommentThread.group(try ProjectQueries.comments(d, documentID: doc))
            XCTAssertEqual(ProjectCommentPrompt.openOwnerCount(threads), 2)
        }
    }
}
