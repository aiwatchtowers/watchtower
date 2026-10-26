import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatProjectSwitcherTests: XCTestCase {
    private typealias Presentation = ChatProjectSwitcherPresentation
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func summary(_ id: Int64, _ name: String, at: Double, unread: Int = 0, waiting: Int = 0, answering: Int = 0) -> Presentation.Summary {
        Presentation.Summary(
            id: id, name: name, lastActivity: Date(timeIntervalSince1970: at),
            unreadCount: unread, waitingCount: waiting, answeringCount: answering
        )
    }

    func testOrderLatestActivityFirstThenName() {
        let rows = [summary(1, "b", at: 10), summary(2, "a", at: 10), summary(3, "z", at: 50)]
        XCTAssertEqual(Presentation.ordered(rows).map(\.id), [3, 2, 1])
    }

    func testMatchingIsCaseAndDiacriticInsensitiveOnNameOnly() {
        let rows = [summary(1, "Café plans", at: 1), summary(2, "Other", at: 2)]
        XCTAssertEqual(Presentation.matching(rows, query: "CAFE").map(\.id), [1])
        XCTAssertEqual(Presentation.matching(rows, query: "  ").map(\.id), [1, 2])
        XCTAssertTrue(Presentation.matching(rows, query: "zzz").isEmpty)
    }

    func testSegmentsPluralsAndTones() {
        XCTAssertEqual(Presentation.segments(summary: summary(1, "a", at: 0, unread: 1), now: now),
                       [SwitcherSegment(text: "1 new answer", tone: .badge)])
        let all = Presentation.segments(summary: summary(1, "a", at: 0, unread: 2, waiting: 3, answering: 1), now: now)
        XCTAssertEqual(all, [
            SwitcherSegment(text: "2 new answers", tone: .badge),
            SwitcherSegment(text: "3 waiting for approval", tone: .warning),
            SwitcherSegment(text: "1 answering", tone: .secondary)
        ])
    }

    func testSegmentsFallBackToAge() {
        let old = now.timeIntervalSince1970 - 8 * 86400
        XCTAssertEqual(Presentation.segments(summary: summary(1, "a", at: old), now: now),
                       [SwitcherSegment(text: "8d", tone: .secondary)])
    }

    func testRowsCountAnsweringChatsPerProjectAndOrder() {
        let summaries = [summary(1, "old", at: 10, answering: 5), summary(2, "new", at: 20)]
        let chats: [(id: Int64, projectID: Int64?)] = [(10, 1), (11, 1), (12, 2), (13, nil), (14, 1)]
        let answering: Set<Int64> = [10, 11, 13]
        let rows = Presentation.rows(summaries, chats: chats) { answering.contains($0) }
        XCTAssertEqual(rows.map(\.id), [2, 1])
        // A stale count is replaced, a chat outside any project counts nowhere.
        XCTAssertEqual(rows.map(\.answeringCount), [0, 2])
    }

    func testSwitcherSummaries() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            try d.execute(sql: "INSERT INTO chat_projects (id, name, created_at, updated_at) VALUES (1,'A',0,100),(2,'Empty',0,70)")
            try d.execute(sql: "INSERT INTO chat_projects (id, name, created_at, updated_at, archived_at) VALUES (3,'Gone',0,0,5)")
            // c1: unread answer; c2: read; c3: no answer; c4 archived; c5 no project
            for id in 1...5 {
                try d.execute(sql: """
                    INSERT INTO chat_conversations (id, title, created_at, updated_at, project_id, read_at, archived_at)
                    VALUES (?, 't', 0, ?, ?, ?, ?)
                    """, arguments: [id, Double(200 + id), id == 5 ? nil : 1, id == 2 ? 500.0 : nil, id == 4 ? 1.0 : nil])
            }
            try d.execute(sql: "INSERT INTO chat_conversations (id, title, created_at, updated_at, project_id) VALUES (6,'t',0,1,3)")
            for (conv, at) in [(1, 300.0), (2, 300.0), (4, 300.0), (5, 300.0), (6, 300.0)] {
                try d.execute(sql: """
                    INSERT INTO chat_messages (conversation_id, role, text, status, created_at)
                    VALUES (?, 'assistant', 'hi', 'complete', ?)
                    """, arguments: [conv, at])
            }
            for conv in [1, 1, 5] {
                try d.execute(sql: """
                    INSERT INTO agent_actions (conversation_id, status, tool, args_json, created_at)
                    VALUES (?, 'pending', 't', '{}', 0)
                    """, arguments: [conv])
            }
        }
        let rows = try db.read { try ChatProjectQueries.switcherSummaries($0) }.sorted { $0.id < $1.id }
        XCTAssertEqual(rows.map(\.id), [1, 2], "archived project excluded")
        XCTAssertEqual(rows[0].unreadCount, 1)
        XCTAssertEqual(rows[0].waitingCount, 2)
        XCTAssertEqual(rows[0].lastActivity, Date(timeIntervalSince1970: 203), "archived chat 4 and project-less 5 ignored")
        XCTAssertEqual(rows[1].lastActivity, Date(timeIntervalSince1970: 70), "falls back to the project")
        XCTAssertEqual(rows[1].unreadCount, 0)

        // A chat waiting in the panel's Undo window counts for nothing (spec §5.3).
        let hidingFirst = try db.read { try ChatProjectQueries.switcherSummaries($0, hiding: [1]) }.sorted { $0.id < $1.id }
        XCTAssertEqual(hidingFirst[0].unreadCount, 0)
        XCTAssertEqual(hidingFirst[0].waitingCount, 0)
        let hidingNewest = try db.read { try ChatProjectQueries.switcherSummaries($0, hiding: [3, 2]) }.sorted { $0.id < $1.id }
        XCTAssertEqual(hidingNewest[0].lastActivity, Date(timeIntervalSince1970: 201))
        XCTAssertEqual(hidingNewest[0].unreadCount, 1)
    }
}
