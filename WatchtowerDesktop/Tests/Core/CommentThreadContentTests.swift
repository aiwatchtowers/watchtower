import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class CommentThreadContentTests: XCTestCase {
    func testTargetThreadMapsAuthorsAndStatus() throws {
        let queue = try TestDatabase.create()
        try queue.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let target = try TestDatabase.insertWorkbenchTarget(d, projectID: p)
            let root = try TestDatabase.insertWorkbenchComment(d, projectID: p, author: "owner", body: "Why?",
                                                               targetID: target)
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, author: "agent", body: "Because.",
                                                        targetID: target, parentID: root)
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, author: "owner", body: "Old",
                                                        targetID: target, status: "outdated")
            let threads = WorkbenchCommentThread.group(try WorkbenchQueries.comments(d, targetID: target))

            let open = threads[0].content
            XCTAssertEqual(open.id, root)
            XCTAssertEqual(open.quote, "", "a target thread quotes nothing")
            XCTAssertNil(open.statusNote)
            XCTAssertEqual(open.entries.map(\.author), ["You", "Agent"])
            XCTAssertEqual(open.entries.map(\.body), ["Why?", "Because."])
            XCTAssertEqual(threads[1].content.statusNote, "Outdated — the quoted text changed")
        }
    }
}
