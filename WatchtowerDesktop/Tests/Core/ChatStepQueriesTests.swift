import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatStepQueriesTests: XCTestCase {
    private func withMessage(_ body: (Database, Int64) throws -> Void) throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let msg = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "")
            try body(d, msg)
        }
    }

    func testStartThenFinishIsOneStepWithResult() throws {
        try withMessage { d, msg in
            try ChatStepQueries.upsertStart(d, messageID: msg, seq: 0, toolID: "a", name: "get_jira_issue", argsJSON: "{}", startedAt: 1)
            try ChatStepQueries.upsertStart(d, messageID: msg, seq: 0, toolID: "a", name: "get_jira_issue", argsJSON: #"{"key":"P-1"}"#, startedAt: 1)
            let sources = ChatSource.encodeList([ChatSource(kind: "jira", title: "P-1", url: "https://x/P-1", ref: "P-1")])
            try ChatStepQueries.finish(d, messageID: msg, toolID: "a", ok: true, summary: "found", sourcesJSON: sources, endedAt: 2)

            let steps = try XCTUnwrap(ChatStepQueries.fetch(d, messageIDs: [msg])[msg])
            XCTAssertEqual(steps.count, 1, "a repeated tool_start updates, never duplicates")
            XCTAssertEqual(steps[0].argsJSON, #"{"key":"P-1"}"#)
            XCTAssertEqual(steps[0].state, .succeeded)
            XCTAssertEqual(steps[0].summary, "found")
            XCTAssertEqual(steps[0].sources.map(\.ref), ["P-1"])
        }
    }

    /// CHAT-02: a tool_end whose tool_start was lost still becomes a step.
    func testFinishWithoutStartStillRecordsAStep() throws {
        try withMessage { d, msg in
            try ChatStepQueries.finish(d, messageID: msg, toolID: "orphan", ok: false, summary: "boom", sourcesJSON: "[]", endedAt: 5)
            let steps = try XCTUnwrap(ChatStepQueries.fetch(d, messageIDs: [msg])[msg])
            XCTAssertEqual(steps.map(\.state), [.failed])
        }
    }

    func testUnfinishedStepIsRunningAndFetchOrdersBySeq() throws {
        try withMessage { d, msg in
            try ChatStepQueries.upsertStart(d, messageID: msg, seq: 1, toolID: "b", name: "second", argsJSON: "{}", startedAt: 2)
            try ChatStepQueries.upsertStart(d, messageID: msg, seq: 0, toolID: "a", name: "first", argsJSON: "{}", startedAt: 1)
            let steps = try XCTUnwrap(ChatStepQueries.fetch(d, messageIDs: [msg])[msg])
            XCTAssertEqual(steps.map(\.name), ["first", "second"])
            XCTAssertEqual(steps.map(\.state), [.running, .running])
        }
    }

    func testFetchWithNoIDsIsEmpty() throws {
        try withMessage { d, _ in
            XCTAssertTrue(try ChatStepQueries.fetch(d, messageIDs: []).isEmpty)
        }
    }
}
