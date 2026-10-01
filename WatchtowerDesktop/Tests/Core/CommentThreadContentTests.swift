import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class CommentThreadContentTests: XCTestCase {
    func testProjectThreadMapsAuthorsQuoteAndStatus() throws {
        let queue = try TestDatabase.create()
        try queue.write { d in
            let p = try TestDatabase.insertProject(d)
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p)
            let root = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", body: "Why?",
                                                             documentID: doc, quote: "retry")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "agent", body: "Because.",
                                                      documentID: doc, parentID: root)
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", body: "Old",
                                                      documentID: doc, status: "outdated", quote: "gone")
            let threads = ProjectCommentThread.group(try ProjectQueries.comments(d, documentID: doc))

            let open = threads[0].content
            XCTAssertEqual(open.id, root)
            XCTAssertEqual(open.quote, "retry")
            XCTAssertNil(open.statusNote)
            XCTAssertEqual(open.entries.map(\.author), ["You", "Agent"])
            XCTAssertEqual(open.entries.map(\.body), ["Why?", "Because."])
            XCTAssertEqual(threads[1].content.statusNote, "Outdated — the quoted text changed")
        }
    }
}
