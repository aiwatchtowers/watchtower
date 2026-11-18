import XCTest
@testable import WatchtowerSync

/// What the notification extension puts on a notification for each work event (A13).
final class WorkAlertContentTests: XCTestCase {
    private let hubID = "11111111-2222-3333-4444-555555555555"

    private func payload(
        _ event: WorkAlertPayload.Event, key: String, session: Int64? = nil, ask: Int64? = nil, request: Int64? = nil
    ) -> WorkAlertPayload {
        WorkAlertPayload(
            event: event, key: key, workbenchID: 7, workbenchName: "Acme", sessionID: session, askID: ask,
            requestID: request, title: "Acme · Fix login", body: "Needs you", quick: false)
    }

    func testAnAskCarriesTitleBodyThreadAndIds() {
        let content = WorkAlertContent(payload: payload(.ask, key: "ask-5", session: 12, ask: 5), hubID: hubID)
        XCTAssertEqual(content.title, "Acme · Fix login")
        XCTAssertEqual(content.body, "Needs you")
        XCTAssertEqual(content.threadID, "session-12")
        XCTAssertEqual(content.userInfo, [
            "wt_hub": hubID, "wt_event": "ask", "wt_key": "ask-5", "wt_session": "12", "wt_ask": "5"
        ])
    }

    func testAPermissionKeepsItsSessionThread() {
        let content = WorkAlertContent(payload: payload(.permission, key: "perm-9", session: 3, request: 9), hubID: hubID)
        XCTAssertEqual(content.threadID, "session-3")
        XCTAssertEqual(content.userInfo["wt_event"], "permission")
        XCTAssertNil(content.userInfo["wt_ask"])
    }

    func testAStoppedSessionGroupsBySession() {
        let content = WorkAlertContent(payload: payload(.sessionStopped, key: "stop-4-1000", session: 4), hubID: hubID)
        XCTAssertEqual(content.threadID, "session-4")
        XCTAssertEqual(content.userInfo["wt_event"], "session_stopped")
        XCTAssertEqual(content.userInfo["wt_session"], "4")
    }

    func testAFailedSessionGroupsBySession() {
        let content = WorkAlertContent(payload: payload(.sessionFailed, key: "stop-4-2000", session: 4), hubID: hubID)
        XCTAssertEqual(content.threadID, "session-4")
        XCTAssertEqual(content.userInfo["wt_event"], "session_failed")
    }

    func testWithoutASessionTheThreadIsTheWorkbench() {
        let content = WorkAlertContent(payload: payload(.ask, key: "ask-5", ask: 5), hubID: hubID)
        XCTAssertEqual(content.threadID, "workbench-7")
        XCTAssertNil(content.userInfo["wt_session"])
    }
}

/// The `chat_answer` event (iPhone chat spec §4.7).
final class WorkAlertChatAnswerTests: XCTestCase {
    private let hubID = "11111111-2222-3333-4444-555555555555"

    func testAChatAnswerDecodesWithoutAWorkbenchAndGroupsByConversation() throws {
        let json = #"{"event":"chat_answer","key":"chat:T:answer","conversation_id":42,"title":"Rollout","body":"Answer ready","quick":false}"#
        let payload = try JSONDecoder().decode(WorkAlertPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.event, .chatAnswer)
        XCTAssertEqual(payload.conversationID, 42)
        let content = WorkAlertContent(payload: payload, hubID: hubID)
        XCTAssertEqual(content.threadID, "chat-42")
        XCTAssertEqual(content.userInfo["wt_event"], "chat_answer")
        XCTAssertEqual(content.userInfo["wt_conversation"], "42")
        XCTAssertNil(content.userInfo["wt_session"])
    }

    func testOtherEventsCarryNoConversationKey() throws {
        let json = #"{"event":"ask","key":"ask-5","workbench_id":7,"workbench_name":"Acme","ask_id":5,"title":"t","body":"b","quick":false}"#
        let payload = try JSONDecoder().decode(WorkAlertPayload.self, from: Data(json.utf8))
        XCTAssertNil(payload.conversationID)
        XCTAssertNil(WorkAlertContent(payload: payload, hubID: hubID).userInfo["wt_conversation"])
        let again = try JSONEncoder().encode(payload)
        XCTAssertFalse(try XCTUnwrap(String(bytes: again, encoding: .utf8)).contains("conversation_id"))
    }
}
