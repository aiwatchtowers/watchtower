import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Spec review threads on the Desktop (spec 2026-11-08 §3): the thread key
/// Go computes too, the review chain's root, and the reads of the tables Go
/// alone writes.
final class SpecReviewThreadQueriesTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    /// Go's `internal/specreview/testdata/thread_keys.json`, read in place.
    private static var threadKeysFixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/specreview/testdata/thread_keys.json")
    }

    private struct KeyCase: Decodable {
        let workbenchID: Int64
        let rootAskID: Int64
        let itemKey: String
        let contextID: String

        enum CodingKeys: String, CodingKey {
            case workbenchID = "workbench_id", rootAskID = "root_ask_id", itemKey = "item_key", contextID = "context_id"
        }
    }

    func testThreadKeyMatchesGoFixture() throws {
        let cases = try JSONDecoder().decode([KeyCase].self, from: Data(contentsOf: Self.threadKeysFixture))
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            XCTAssertEqual(
                SpecReviewThreadKey.contextID(workbenchID: c.workbenchID, rootAskID: c.rootAskID, itemKey: c.itemKey),
                c.contextID
            )
        }
        XCTAssertEqual(SpecReviewThreadKey.contextType, "spec_review_thread")
    }

    private func reviewAsk(_ d: Database, projectID: Int64, previous: Int64? = nil) throws -> Int64 {
        let id = try TestDatabase.insertOwnerAsk(d, projectID: projectID, kind: "review", docPath: "docs/spec.md")
        try d.execute(sql: "UPDATE owner_asks SET previous_ask_id = ? WHERE id = ?", arguments: [previous, id])
        return id
    }

    func testChainRootWalksPreviousAsks() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let first = try reviewAsk(d, projectID: p)
            let second = try reviewAsk(d, projectID: p, previous: first)
            let third = try reviewAsk(d, projectID: p, previous: second)
            let other = try reviewAsk(d, projectID: p)

            XCTAssertEqual(try SpecReviewThreadQueries.chainRoot(d, askID: third), first)
            XCTAssertEqual(try SpecReviewThreadQueries.chainRoot(d, askID: second), first)
            XCTAssertEqual(try SpecReviewThreadQueries.chainRoot(d, askID: first), first, "a first ask is its own root")
            XCTAssertEqual(try SpecReviewThreadQueries.chainRoot(d, askID: other), other)
            XCTAssertEqual(try SpecReviewThreadQueries.chainRoot(d, askID: 9999), 9999, "an unknown ask is its own root")
        }
    }

    /// A cycle no writer makes still ends, at Go's depth cap.
    func testChainRootStopsAtTheDepthCap() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let a = try reviewAsk(d, projectID: p)
            let b = try reviewAsk(d, projectID: p, previous: a)
            try d.execute(sql: "UPDATE owner_asks SET previous_ask_id = ? WHERE id = ?", arguments: [b, a])
            let root = try SpecReviewThreadQueries.chainRoot(d, askID: b)
            XCTAssertTrue([a, b].contains(root))
        }
    }

    func testThreadFindingsDecode() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let ask = try reviewAsk(d, projectID: p)
            let other = try reviewAsk(d, projectID: p)
            let stored = #"""
            {"key":"tf:a1","kind":"blind_spot","severity":"major","title":"Followed threads","text":"A followed thread stays silent.",
             "chapter":"ch:2","quote":{"source":"thread","text":"what about threads I follow?"},"speaker":"owner",
             "where":{"heading":"Behaviour","quote":"Muting lasts twenty-four hours."},"thread":"1:1:bs:1"}
            """#
            let rows: [(Int64, String, String, String)] = [
                (ask, "tf:a1", stored, "2026-11-08T10:00:01Z"),
                (ask, "tf:b2", #"{"kind":"differs","text":"Mute is a week"}"#, "2026-11-08T10:00:00Z"),
                (ask, "tf:c3", "{not json", "2026-11-08T10:00:02Z"),
                (other, "tf:d4", #"{"kind":"missing","text":"x"}"#, "2026-11-08T10:00:00Z")
            ]
            for (askID, key, json, at) in rows {
                try d.execute(sql: """
                    INSERT INTO spec_review_thread_findings (ask_id, item_key, thread, finding, created_at)
                    VALUES (?, ?, '1:1:bs:1', ?, ?)
                    """, arguments: [askID, key, json, at])
            }

            let found = try SpecReviewThreadQueries.threadFindings(d, askID: ask)
            XCTAssertEqual(found.map(\.key), ["tf:b2", "tf:a1"], "in the order added; an unreadable row is left out")
            let full = try XCTUnwrap(found.last)
            XCTAssertEqual(full.kind, "blind_spot")
            XCTAssertEqual(full.severity, .major)
            XCTAssertEqual(full.title, "Followed threads")
            XCTAssertEqual(full.headline, "Followed threads")
            XCTAssertEqual(full.chapter, "ch:2")
            XCTAssertEqual(full.quote, .init(source: "thread", text: "what about threads I follow?"))
            XCTAssertEqual(full.anchor?.quote, "Muting lasts twenty-four hours.")
            XCTAssertEqual(full.status, .added(key: "tf:a1"))
            XCTAssertEqual(found[0].chapter, "", "no chapter: it goes to Other")
            XCTAssertEqual(found[0].headline, "Mute is a week", "no title: the text heads the card")
            XCTAssertEqual(found[0].key, "tf:b2", "the row's key, even when the JSON has none")
        }
    }

    func testQuestionsOfTheThreads() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let ask = try reviewAsk(d, projectID: p)
            for (thread, state, answer) in [("1:1:ag:1", "answered", "yes"), ("1:1:ag:1", "open", ""), ("1:1:bs:2", "expired", "")] {
                try d.execute(sql: """
                    INSERT INTO spec_review_questions (ask_id, thread, item_key, question, answer, state, created_at)
                    VALUES (?, ?, 'k', 'Why?', ?, ?, '2026-11-08T10:00:00Z')
                    """, arguments: [ask, thread, answer, state])
            }
            let rows = try SpecReviewThreadQueries.questions(d, threads: ["1:1:ag:1"])
            XCTAssertEqual(rows.map(\.state), [.answered, .open])
            XCTAssertEqual(rows.first?.answer, "yes")
            XCTAssertEqual(rows.first?.askID, ask)
            XCTAssertEqual(try SpecReviewThreadQueries.questions(d, threads: []), [])
        }
    }

    func testMessageCountsByThreadKey() throws {
        try db.write { d in
            func conversation(type: String?, id: String) throws -> Int64 {
                try d.execute(sql: """
                    INSERT INTO chat_conversations (context_type, context_id, created_at, updated_at) VALUES (?, ?, 0, 0)
                    """, arguments: [type, id])
                return d.lastInsertedRowID
            }
            func message(_ conversation: Int64, _ role: String, status: String = "complete") throws {
                try d.execute(sql: """
                    INSERT INTO chat_messages (conversation_id, role, text, created_at, status) VALUES (?, ?, 't', 0, ?)
                    """, arguments: [conversation, role, status])
            }
            let thread = try conversation(type: "spec_review_thread", id: "1:1:ag:1")
            try message(thread, "user")
            try message(thread, "assistant")
            try message(thread, "assistant", status: "error")
            try message(thread, "system")
            let other = try conversation(type: "code_question", id: "1:1:bs:2")
            try message(other, "user")

            XCTAssertEqual(
                try SpecReviewThreadQueries.messageCounts(d, contextIDs: ["1:1:ag:1", "1:1:bs:2", "1:1:none"]),
                ["1:1:ag:1": 2]
            )
            XCTAssertEqual(try SpecReviewThreadQueries.messageCounts(d, contextIDs: []), [:])
        }
    }
}
