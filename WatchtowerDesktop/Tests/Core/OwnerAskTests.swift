import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// An `owner_asks` row's level and origin (spec 2026-10-10 Part 3.4) and the
/// questions of an ask raised from chat with no options (Part 3.5, E18a).
final class OwnerAskTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    private static let twoOptions = #"{"questions":[{"id":"1","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#

    private static func zeroOptionsFixture() throws -> String {
        let url = OwnerAskFixtures.directory("cards").appendingPathComponent("owner_ask_zero_options.json")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func setLevel(_ d: Database, _ id: Int64, level: String, origin: String, chatAskedAt: String = "") throws {
        try d.execute(sql: "UPDATE owner_asks SET level = ?, origin = ?, chat_asked_at = ? WHERE id = ?",
                      arguments: [level, origin, chatAskedAt, id])
    }

    private func row(level: String?, origin: String?) -> Row {
        var values: [String: (any DatabaseValueConvertible)?] = [
            "id": 9, "project_id": 1, "kind": "question", "title": "Ask", "status": "open", "payload": Self.twoOptions
        ]
        if let level { values["level"] = level }
        if let origin { values["origin"] = origin }
        return Row(values)
    }

    func testQuickFullAndChatRowsDecode() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let old = try TestDatabase.insertOwnerAsk(d, projectID: p, payload: Self.twoOptions)
            let quick = try TestDatabase.insertOwnerAsk(d, projectID: p, payload: Self.twoOptions)
            try setLevel(d, quick, level: "quick", origin: "agent")
            let chat = try TestDatabase.insertOwnerAsk(d, projectID: p, payload: Self.twoOptions)
            try setLevel(d, chat, level: "quick", origin: "chat", chatAskedAt: "2026-10-10T09:15:00.000Z")

            let asks = try XCTUnwrap(OwnerAskQueries.ask(d, id: old, projectID: p))
            XCTAssertEqual(asks.level, .full, "a row filed before 00107 reads the column default")
            XCTAssertEqual(asks.origin, .agent)
            XCTAssertEqual(asks.chatAskedAt, "")

            let quickAsk = try XCTUnwrap(OwnerAskQueries.ask(d, id: quick, projectID: p))
            XCTAssertEqual(quickAsk.level, .quick)
            XCTAssertEqual(quickAsk.origin, .agent)
            XCTAssertEqual(quickAsk.chatAskedAt, "")

            let chatAsk = try XCTUnwrap(OwnerAskQueries.ask(d, id: chat, projectID: p))
            XCTAssertEqual(chatAsk.level, .quick)
            XCTAssertEqual(chatAsk.origin, .chat)
            XCTAssertEqual(chatAsk.chatAskedAt, "2026-10-10T09:15:00.000Z", "kept raw, as Go wrote it")
        }
    }

    /// A level or origin this build does not know is a broken row, as an
    /// unknown kind is: never shown as some other level.
    func testAnUnknownOrMissingLevelOrOriginMakesTheRowUnreadable() throws {
        XCTAssertNoThrow(try OwnerAsk(row: row(level: "full", origin: "agent")))
        for (level, origin, named) in [("x", "agent", "unknown ask level x"), ("full", "x", "unknown ask origin x"),
                                       (nil, "agent", "unknown ask level "), ("full", nil, "unknown ask origin ")] {
            XCTAssertThrowsError(try OwnerAsk(row: row(level: level, origin: origin))) { error in
                guard case let DecodingError.dataCorrupted(context) = error else {
                    return XCTFail("\(error)")
                }
                XCTAssertEqual(context.debugDescription, named)
            }
        }
    }

    /// The stack's error line names a row whose level it cannot read; the
    /// asks around it still list.
    func testAnUnknownLevelIsNamedInTheStacksErrorLine() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let good = try TestDatabase.insertOwnerAsk(d, projectID: p, payload: Self.twoOptions, createdAt: "2026-10-10T09:00:00Z")
            let bad = try TestDatabase.insertOwnerAsk(d, projectID: p, payload: Self.twoOptions, createdAt: "2026-10-10T09:01:00Z")
            // The column's CHECK refuses 'x'; a newer Go could still widen it.
            try d.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try setLevel(d, bad, level: "x", origin: "agent")
            try d.execute(sql: "PRAGMA ignore_check_constraints = OFF")

            let open = try OwnerAskQueries.openAsks(d, projectID: p)
            XCTAssertEqual(open.asks.map(\.id), [good])
            XCTAssertEqual(open.unreadableIDs, [bad])
            XCTAssertEqual(open.problem, "1 ask could not be read (#\(bad)).")
        }
    }

    /// E18a: a question raised from chat with no options (free reply only)
    /// is a readable owner ask.
    func testZeroOptionAskDecodes() throws {
        let payload = try OwnerAskPayload.decode(Self.zeroOptionsFixture())
        XCTAssertEqual(payload.questions.map(\.id), ["q1"])
        XCTAssertEqual(payload.questions.first?.question, "What is the staging host name?")
        XCTAssertEqual(payload.questions.first?.options, [])

        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let id = try TestDatabase.insertOwnerAsk(d, projectID: p, payload: try Self.zeroOptionsFixture())
            try setLevel(d, id, level: "quick", origin: "chat", chatAskedAt: "2026-10-10T09:15:00.000Z")
            let open = try OwnerAskQueries.openAsks(d, projectID: p)
            XCTAssertEqual(open.unreadableIDs, [])
            XCTAssertEqual(open.asks.first?.payload.questions.first?.options, [])
        }
    }

    /// The allowance is for no options only: one, or more than four, is
    /// still a broken payload.
    func testAOneOrFiveOptionOwnerAskIsStillRefused() {
        let one = #"{"questions":[{"id":"1","question":"Q?","options":[{"label":"A"}]}]}"#
        let five = #"{"questions":[{"id":"1","question":"Q?","options":[{"label":"A"},{"label":"B"},{"label":"C"},{"label":"D"},{"label":"E"}]}]}"#
        XCTAssertThrowsError(try OwnerAskPayload.decode(one))
        XCTAssertThrowsError(try OwnerAskPayload.decode(five))
    }
}
