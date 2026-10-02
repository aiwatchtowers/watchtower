import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatEntitySearchTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    private func insertIssue(
        _ d: Database,
        accountID: Int64,
        key: String,
        project: String,
        summary: String,
        updatedAt: String = "2026-09-01T00:00:00Z",
        deleted: Bool = false
    ) throws {
        try d.execute(
            sql: """
                INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category,
                                         created_at, updated_at, synced_at, is_deleted)
                VALUES (?, ?, ?, ?, 'Open', 'todo', ?, ?, ?, ?)
                """,
            arguments: [accountID, key, project, summary, updatedAt, updatedAt, updatedAt, deleted ? 1 : 0]
        )
    }

    func testPeopleMatchPrefixAndWordPrefixAndSkipBotsAndDeleted() throws {
        try db.write { d in
            try TestDatabase.insertUser(d, id: "1:U1", name: "anna", displayName: "Anna Ivanova", realName: "")
            try TestDatabase.insertUser(d, id: "1:U2", name: "ivan", displayName: "", realName: "Ivan Petrov")
            try TestDatabase.insertUser(d, id: "1:U3", name: "ivanbot", displayName: "Ivan Bot", isBot: true)
            try TestDatabase.insertUser(d, id: "1:U4", name: "ivanold", displayName: "Ivan Old", isDeleted: true)

            let hits = try ChatEntitySearch.people(d, query: "iva")
            XCTAssertEqual(Set(hits.map(\.ref)), ["1:U1", "1:U2"], "word prefix 'Iva' in 'Anna Ivanova' + prefix 'ivan'")
            XCTAssertEqual(hits.first { $0.ref == "1:U2" }?.label, "Ivan Petrov", "falls back to real_name")
            XCTAssertTrue(hits.allSatisfy { $0.kind == .person })
        }
    }

    /// SQLite LIKE folds only ASCII case: a lower-case Cyrillic query must
    /// still find a capitalized name.
    func testPeopleCyrillicLowercaseQueryFindsCapitalizedName() throws {
        try db.write { d in
            try TestDatabase.insertUser(d, id: "1:U9", name: "ivan", displayName: "Иван Петров")
            XCTAssertEqual(try ChatEntitySearch.people(d, query: "ива").map(\.ref), ["1:U9"])
        }
    }

    func testPeopleSkipStubsAndNoMatchIsEmpty() throws {
        try db.write { d in
            try TestDatabase.insertUser(d, id: "1:U5", name: "stubby", displayName: "Stub Person")
            try d.execute(sql: "UPDATE users SET is_stub = 1 WHERE id = '1:U5'")
            XCTAssertTrue(try ChatEntitySearch.people(d, query: "stub").isEmpty)
            XCTAssertTrue(try ChatEntitySearch.people(d, query: "zzz").isEmpty)
            XCTAssertTrue(try ChatEntitySearch.jiraIssues(d, query: "zzz").isEmpty, "no jira data at all")
        }
    }

    func testWildcardsInQueryAreLiteral() throws {
        try db.write { d in
            try TestDatabase.insertUser(d, id: "1:U1", name: "anna", displayName: "Anna")
            XCTAssertTrue(try ChatEntitySearch.people(d, query: "%").isEmpty)
            XCTAssertTrue(try ChatEntitySearch.people(d, query: "_nna").isEmpty)
        }
    }

    func testEmptyQueryListsUpToLimit() throws {
        try db.write { d in
            for i in 0..<12 {
                try TestDatabase.insertUser(d, id: "1:U\(i)", name: "user\(i)", displayName: "User \(i)")
            }
            XCTAssertEqual(try ChatEntitySearch.people(d, query: "").count, ChatEntitySearch.defaultLimit)
            XCTAssertEqual(try ChatEntitySearch.people(d, query: "", limit: 3).count, 3)
        }
    }

    func testChannelsSkipArchivedAndDMs() throws {
        try db.write { d in
            try TestDatabase.insertChannel(d, id: "1:C1", name: "payments")
            try TestDatabase.insertChannel(d, id: "1:C2", name: "payments-old", isArchived: true)
            try TestDatabase.insertChannel(d, id: "1:D1", name: "payuser", type: "dm")
            let hits = try ChatEntitySearch.channels(d, query: "pay")
            XCTAssertEqual(hits.map(\.ref), ["1:C1"])
            XCTAssertEqual(hits.first?.label, "#payments")
        }
    }

    func testJiraIssuesByKeyOrSummaryDedupedAcrossSites() throws {
        try db.write { d in
            let a = try TestDatabase.insertJiraAccount(d, cloudID: "a")
            let b = try TestDatabase.insertJiraAccount(d, cloudID: "b")
            try insertIssue(d, accountID: a, key: "PAY-12", project: "PAY", summary: "Refund flow")
            try insertIssue(d, accountID: b, key: "PAY-12", project: "PAY", summary: "Refund flow")
            try insertIssue(d, accountID: a, key: "OPS-1", project: "OPS", summary: "Payout alerts")
            try insertIssue(d, accountID: a, key: "PAY-99", project: "PAY", summary: "gone", deleted: true)

            XCTAssertEqual(try ChatEntitySearch.jiraIssues(d, query: "pay-1").map(\.ref), ["PAY-12"])
            XCTAssertEqual(Set(try ChatEntitySearch.jiraIssues(d, query: "payout").map(\.ref)), ["OPS-1"])
            let hit = try XCTUnwrap(ChatEntitySearch.jiraIssues(d, query: "PAY-12").first)
            XCTAssertEqual(hit.label, "PAY-12")
            XCTAssertEqual(hit.detail, "Refund flow")
        }
    }

    func testJiraProjectsAreDistinctKeys() throws {
        try db.write { d in
            let a = try TestDatabase.insertJiraAccount(d, cloudID: "a")
            try insertIssue(d, accountID: a, key: "PAY-1", project: "PAY", summary: "x")
            try insertIssue(d, accountID: a, key: "PAY-2", project: "PAY", summary: "y")
            try insertIssue(d, accountID: a, key: "OPS-1", project: "OPS", summary: "z")
            let hits = try ChatEntitySearch.jiraProjects(d, query: "")
            XCTAssertEqual(hits.map(\.ref), ["OPS", "PAY"])
            XCTAssertEqual(hits.last?.detail, "2 issues")
        }
    }

    func testTargetsSkipDoneAndDismissedTracksSkipDismissed() throws {
        try db.write { d in
            let live = try TestDatabase.insertTarget(d, text: "Ship refunds\nsecond line")
            _ = try TestDatabase.insertTarget(d, text: "Ship old thing", status: "done")
            _ = try TestDatabase.insertTarget(d, text: "Ship dropped", status: "dismissed")
            let targets = try ChatEntitySearch.targets(d, query: "ship")
            XCTAssertEqual(targets.map(\.ref), [String(live)])
            XCTAssertEqual(targets.first?.label, "Ship refunds", "first line only")

            let track = try TestDatabase.insertTrack(d, text: "Refund review")
            let gone = try TestDatabase.insertTrack(d, text: "Refund dismissed")
            try d.execute(sql: "UPDATE tracks SET dismissed_at = '2026-01-01' WHERE id = ?", arguments: [gone])
            XCTAssertEqual(try ChatEntitySearch.tracks(d, query: "refund").map(\.ref), [String(track)])
        }
    }

    func testConfluenceSpacesMatchKeyOrNameAndDedupeAcrossSites() throws {
        try db.write { d in
            let siteA = try TestDatabase.insertJiraAccount(d, cloudID: "a")
            let siteB = try TestDatabase.insertJiraAccount(d, cloudID: "b")
            try TestDatabase.insertExtSource(d, jiraAccountID: siteA, containerKey: "ENG", containerName: "Engineering")
            try TestDatabase.insertExtSource(d, jiraAccountID: siteB, containerKey: "ENG", containerName: "Engineering")
            try TestDatabase.insertExtSource(d, jiraAccountID: siteA, containerKey: "DOC", containerName: "")

            let byKey = try ChatEntitySearch.confluenceSpaces(d, query: "en")
            XCTAssertEqual(byKey, [ChatEntityHit(kind: .confluenceSpace, ref: "ENG", label: "Engineering",
                                                 detail: "Confluence space ENG")], "one hit for a key two sites share")
            XCTAssertEqual(try ChatEntitySearch.confluenceSpaces(d, query: "engin").map(\.ref), ["ENG"], "name prefix")
            let unnamed = try ChatEntitySearch.search(d, kind: .confluenceSpace, query: "doc")
            XCTAssertEqual(unnamed.map(\.label), ["DOC"], "an unnamed space is labelled by its key")
            XCTAssertEqual(try ChatEntitySearch.confluenceSpaces(d, query: "").map(\.ref), ["DOC", "ENG"])
        }
    }

    func testSearchByKindDispatches() throws {
        try db.write { d in
            try TestDatabase.insertChannel(d, id: "1:C1", name: "general")
            XCTAssertEqual(try ChatEntitySearch.search(d, kind: .channel, query: "gen").map(\.ref), ["1:C1"])
            XCTAssertTrue(try ChatEntitySearch.search(d, kind: .person, query: "gen").isEmpty)
        }
    }

    func testProjectSourceKindMapping() {
        XCTAssertEqual(ChatProjectSource.Kind(entity: .person), .person)
        XCTAssertEqual(ChatProjectSource.Kind(entity: .channel), .slackChannel)
        XCTAssertEqual(ChatProjectSource.Kind(entity: .jiraProject), .jiraProject)
        XCTAssertEqual(ChatProjectSource.Kind(entity: .confluenceSpace), .confluenceSpace)
        XCTAssertEqual(ChatProjectSource.Kind(entity: .target), .target)
        XCTAssertEqual(ChatProjectSource.Kind(entity: .track), .track)
        XCTAssertNil(ChatProjectSource.Kind(entity: .jiraIssue), "an issue is a mention, not a project source")
    }
}
