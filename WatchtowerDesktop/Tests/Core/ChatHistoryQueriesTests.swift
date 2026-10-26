import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatHistoryQueriesTests: XCTestCase {
    private func setLeaf(_ d: Database, _ conv: Int64, _ leaf: Int64) throws {
        try d.execute(sql: "UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?", arguments: [leaf, conv])
    }

    private func project(_ d: Database, _ name: String) throws -> Int64 {
        try d.execute(sql: "INSERT INTO chat_projects (name, created_at, updated_at) VALUES (?, 1, 1)", arguments: [name])
        return d.lastInsertedRowID
    }

    func testLastAnswerFollowsTheActiveBranch() throws {
        let db = try TestDatabase.create()
        let rows = try db.write { d -> [ChatPanelRow] in
            let conv = try TestDatabase.insertChatConversation(d, title: "branched")
            let user = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "user", text: "q", createdAt: 10)
            let shown = try TestDatabase.insertChatMessage(
                d, conversationID: conv, role: "assistant", text: "**Shown** answer\nsecond", parentID: user, createdAt: 20)
            // A newer answer on another branch, and a newer partial on the shown one.
            try TestDatabase.insertChatMessage(
                d, conversationID: conv, role: "assistant", text: "other branch", parentID: user, createdAt: 30)
            let user2 = try TestDatabase.insertChatMessage(
                d, conversationID: conv, role: "user", text: "q2", parentID: shown, createdAt: 40)
            let partial = try TestDatabase.insertChatMessage(
                d, conversationID: conv, role: "assistant", text: "half", parentID: user2, status: "partial", createdAt: 50)
            try setLeaf(d, conv, partial)
            return try ChatHistoryQueries.panelRows(d, projectID: nil)
        }
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.lastAnswerAt, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(row.lastAnswerPreview, "Shown answer")
    }

    func testWithoutALeafEveryMessageCounts() throws {
        let db = try TestDatabase.create()
        let row = try db.write { d -> ChatPanelRow? in
            let conv = try TestDatabase.insertChatConversation(d, title: "linear")
            try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "first", createdAt: 10)
            try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "last", createdAt: 20)
            try TestDatabase.insertChatMessage(
                d, conversationID: conv, role: "assistant", text: "failed", status: "error", createdAt: 30)
            return try ChatHistoryQueries.panelRows(d, projectID: nil).first
        }
        XCTAssertEqual(row?.lastAnswerPreview, "last")
        XCTAssertEqual(row?.lastAnswerAt, Date(timeIntervalSince1970: 20))
    }

    func testUnreadAgainstReadAtAndMarkRead() throws {
        let db = try TestDatabase.create()
        let (conv, before) = try db.write { d -> (Int64, ChatPanelRow?) in
            let conv = try TestDatabase.insertChatConversation(d, title: "c", updatedAt: 5)
            let msg = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "a", createdAt: 20)
            try setLeaf(d, conv, msg)
            try d.execute(sql: "UPDATE chat_conversations SET read_at = 10 WHERE id = ?", arguments: [conv])
            return (conv, try ChatHistoryQueries.panelRows(d, projectID: nil).first)
        }
        XCTAssertEqual(before?.isUnread, true)
        let after = try db.write { d -> ChatPanelRow? in
            try ChatConversationQueries.markRead(d, id: conv, at: Date(timeIntervalSince1970: 25))
            return try ChatHistoryQueries.panelRows(d, projectID: nil).first
        }
        XCTAssertEqual(after?.isUnread, false)
        XCTAssertEqual(after?.conversation.readAt, 25)
        XCTAssertEqual(after?.conversation.updatedAt, 5, "reading is not activity")
        // An older mark never moves it back.
        let stale = try db.write { d -> Double? in
            try ChatConversationQueries.markRead(d, id: conv, at: Date(timeIntervalSince1970: 15))
            return try ChatConversationQueries.fetchByID(d, id: conv)?.readAt
        }
        XCTAssertEqual(stale, 25)
    }

    func testPendingCountAndOldestTool() throws {
        let db = try TestDatabase.create()
        let rows = try db.write { d -> [ChatPanelRow] in
            let conv = try TestDatabase.insertChatConversation(d, title: "with", updatedAt: 2)
            let other = try TestDatabase.insertChatConversation(d, title: "without", updatedAt: 1)
            try TestDatabase.insertAgentAction(d, tool: "remind_me", conversationID: conv, createdAt: "2026-09-04T10:00:00Z")
            try TestDatabase.insertAgentAction(d, tool: "create_target", conversationID: conv, createdAt: "2026-09-04T11:00:00Z")
            try TestDatabase.insertAgentAction(d, conversationID: conv, status: "applied")
            try TestDatabase.insertAgentAction(d, conversationID: other, status: "rejected")
            return try ChatHistoryQueries.panelRows(d, projectID: nil)
        }
        XCTAssertEqual(rows.map(\.conversation.title), ["with", "without"])
        XCTAssertEqual(rows.map(\.pendingApprovals), [2, 0])
        XCTAssertEqual(rows.map(\.pendingTool), ["remind_me", nil])
    }

    func testProjectFilterNameAndListedChats() throws {
        let db = try TestDatabase.create()
        let (projectA, all, onlyA) = try db.write { d -> (Int64, [ChatPanelRow], [ChatPanelRow]) in
            let projectA = try project(d, "Project A")
            let projectB = try project(d, "Project B")
            let inA = try TestDatabase.insertChatConversation(d, title: "in A", updatedAt: 3)
            let inB = try TestDatabase.insertChatConversation(d, title: "in B", updatedAt: 2)
            try TestDatabase.insertChatConversation(d, title: "loose", updatedAt: 1)
            try TestDatabase.insertChatConversation(d, title: "discuss", contextType: "track", updatedAt: 4)
            let archived = try TestDatabase.insertChatConversation(d, title: "archived", updatedAt: 5)
            try d.execute(sql: "UPDATE chat_conversations SET archived_at = 9 WHERE id = ?", arguments: [archived])
            try d.execute(sql: "UPDATE chat_conversations SET project_id = ? WHERE id = ?", arguments: [projectA, inA])
            try d.execute(sql: "UPDATE chat_conversations SET project_id = ? WHERE id = ?", arguments: [projectB, inB])
            return (projectA, try ChatHistoryQueries.panelRows(d, projectID: nil),
                    try ChatHistoryQueries.panelRows(d, projectID: projectA))
        }
        XCTAssertEqual(all.map(\.conversation.title), ["in A", "in B", "loose"])
        XCTAssertEqual(all.map(\.projectName), ["Project A", "Project B", nil])
        XCTAssertEqual(onlyA.map(\.conversation.title), ["in A"])
        XCTAssertEqual(onlyA.first?.conversation.projectID, projectA)
    }

    func testPreviewIsCappedAndAttachmentsFlagged() throws {
        let db = try TestDatabase.create()
        let row = try db.write { d -> ChatPanelRow? in
            let conv = try TestDatabase.insertChatConversation(d, title: "long")
            try TestDatabase.insertChatMessage(
                d, conversationID: conv, role: "assistant", text: String(repeating: "a", count: 500), createdAt: 1)
            return try ChatHistoryQueries.panelRows(d, projectID: nil).first
        }
        XCTAssertLessThanOrEqual(row?.lastAnswerPreview.count ?? 0, 200)
        XCTAssertEqual(row?.conversation.hasAttachments, false)
    }
}
