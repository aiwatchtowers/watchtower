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

    func testTerminalInputIsTheLineThenExactlyOneEnter() {
        let bytes = ProjectCommentPrompt.terminalInput("Address x\n\u{1B}y")
        XCTAssertEqual(bytes.last, 0x0D)
        XCTAssertEqual(bytes.filter { $0 < 0x20 || $0 == 0x7F }, [0x0D], "no other control byte reaches the terminal")
        XCTAssertEqual(String(bytes: bytes.dropLast(), encoding: .utf8), "Address xy")
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
