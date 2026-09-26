import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

final class ReactionDictionaryQueriesTests: XCTestCase {
    func testFetchAllReturnsSeededRows() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertReactionCommandMapping(db, emoji: "white_check_mark", tool: "create_target")
            try TestDatabase.insertReactionCommandMapping(db, emoji: "ticket", tool: "create_jira_issue", enabled: false)
        }

        let rows = try queue.read { db in try ReactionDictionaryQueries.fetchAll(db) }

        XCTAssertEqual(rows.map(\.emoji), ["ticket", "white_check_mark"], "alphabetical by emoji")
        let checkMark = try XCTUnwrap(rows.first { $0.emoji == "white_check_mark" })
        XCTAssertEqual(checkMark.kind, "builtin_tool")
        XCTAssertEqual(checkMark.tool, "create_target")
        XCTAssertTrue(checkMark.enabled)
        let ticket = try XCTUnwrap(rows.first { $0.emoji == "ticket" })
        XCTAssertFalse(ticket.enabled)
    }

    func testSetEnabledFlipsTheFlag() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertReactionCommandMapping(db, emoji: "white_check_mark", tool: "create_target", enabled: true)
        }

        try queue.write { db in try ReactionDictionaryQueries.setEnabled(db, emoji: "white_check_mark", enabled: false) }

        let row = try queue.read { db in try ReactionDictionaryQueries.fetchAll(db) }.first
        XCTAssertEqual(row?.enabled, false)
    }

    func testDeleteRemovesTheRow() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertReactionCommandMapping(db, emoji: "white_check_mark", tool: "create_target")
            try TestDatabase.insertReactionCommandMapping(db, emoji: "ticket", tool: "create_jira_issue")
        }

        try queue.write { db in try ReactionDictionaryQueries.delete(db, emoji: "ticket") }

        let rows = try queue.read { db in try ReactionDictionaryQueries.fetchAll(db) }
        XCTAssertEqual(rows.map(\.emoji), ["white_check_mark"])
    }

    func testUpsertInsertsThenUpdates() throws {
        let queue = try TestDatabase.create()

        try queue.write { db in try ReactionDictionaryQueries.upsert(db, emoji: "bulb", tool: "create_idea") }
        var rows = try queue.read { db in try ReactionDictionaryQueries.fetchAll(db) }
        XCTAssertEqual(rows.map(\.tool), ["create_idea"])
        XCTAssertEqual(rows.first?.kind, "builtin_tool")
        XCTAssertTrue(rows.first?.enabled ?? false)

        try queue.write { db in try ReactionDictionaryQueries.upsert(db, emoji: "bulb", tool: "create_track") }
        rows = try queue.read { db in try ReactionDictionaryQueries.fetchAll(db) }
        XCTAssertEqual(rows.count, 1, "repoints the existing emoji rather than adding a second row")
        XCTAssertEqual(rows.first?.tool, "create_track")
    }

    func testTrustForReadsToolTrust() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertToolTrust(db, tool: "create_jira_issue", trust: "ask")
        }

        let trust = try queue.read { db in try ReactionDictionaryQueries.trustFor(db, tool: "create_jira_issue") }
        XCTAssertEqual(trust, "ask")

        let missing = try queue.read { db in try ReactionDictionaryQueries.trustFor(db, tool: "create_target") }
        XCTAssertNil(missing, "no standing trust row yet — Go's default is 'ask' until the owner sets one")
    }
}
