import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class CommentThreadContentTests: XCTestCase {
    func testProjectThreadMapsAuthorsQuoteAndStatus() throws {
        let queue = try TestDatabase.create()
        try queue.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let doc = try TestDatabase.insertWorkbenchDocument(d, projectID: p)
            let root = try TestDatabase.insertWorkbenchComment(d, projectID: p, author: "owner", body: "Why?",
                                                               documentID: doc, quote: "retry")
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, author: "agent", body: "Because.",
                                                        documentID: doc, parentID: root)
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, author: "owner", body: "Old",
                                                        documentID: doc, status: "outdated", quote: "gone")
            let threads = WorkbenchCommentThread.group(try WorkbenchQueries.comments(d, documentID: doc))

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
