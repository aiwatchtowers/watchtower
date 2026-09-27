import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class MentionSearchTests: XCTestCase {
    func testMixesKindsCapsAtEightAndRanksLabelPrefixFirst() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            for i in 0..<6 {
                try TestDatabase.insertUser(d, id: "1:U\(i)", name: "pa\(i)", displayName: "Old Pa\(i)")
            }
            try TestDatabase.insertChannel(d, id: "1:C1", name: "payments")
            _ = try TestDatabase.insertTarget(d, text: "Payments launch")
            _ = try TestDatabase.insertTrack(d, text: "Payout review")
            let hits = try MentionSearch.search(d, query: "pa")
            XCTAssertEqual(hits.count, MentionSearch.resultLimit)
            XCTAssertEqual(Array(hits.prefix(3)).map(\.kind), [.channel, .target, .track],
                           "label-prefix hits ('#payments', 'Payments launch', 'Payout review') beat word-prefix people")
        }
    }

    func testNeverReturnsJiraProjects() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let acct = try TestDatabase.insertJiraAccount(d, cloudID: "a")
            try d.execute(sql: """
                INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category,
                                         created_at, updated_at, synced_at)
                VALUES (?, 'PAY-1', 'PAY', 'x', 'Open', 'todo', 't', 't', 't')
                """, arguments: [acct])
            XCTAssertEqual(try MentionSearch.search(d, query: "PAY").map(\.referenceToken), ["jira:PAY-1"])
        }
    }
}
