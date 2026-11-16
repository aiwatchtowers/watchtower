import ChatWire
import Foundation
import WatchtowerChatText
@testable import WatchtowerCore
import XCTest

/// An embedded chat's rows reach ChatUI's feed field by field, with no parts of the adapter's own (D14, D22).
@MainActor
final class EmbeddedChatFeedAdapterTests: XCTestCase {
    private func record(
        _ id: Int64, role: String, text: String, status: String = "complete",
        errorCode: String? = nil, errorMessage: String? = nil
    ) -> ChatMessageRecord {
        ChatMessageRecord(id: id, conversationID: 7, role: role, text: text, createdAt: 1_700_000_000 + Double(id),
                          turnID: "t\(id)", status: status, model: "opus", errorCode: errorCode, errorMessage: errorMessage)
    }

    private func step(_ messageID: Int64, ok: Int?, sources: String = "[]") throws -> ChatTurnStep {
        var row: [String: Any] = [
            "id": 1, "message_id": messageID, "seq": 0, "tool_id": "tool-1", "name": "search_messages",
            "args_json": "{}", "summary": "Found 3 messages", "sources_json": sources,
            "started_at": 1_700_000_000, "ended_at": 1_700_000_001
        ]
        if let ok { row["ok"] = ok }
        return try JSONDecoder().decode(ChatTurnStep.self, from: JSONSerialization.data(withJSONObject: row))
    }

    func testEmbeddedAdapterMapsRowsFieldByField() throws {
        let sources = ##"[{"kind":"slack","title":"#payments","url":"https://example.com/p1","ref":"C1"}]"##
        let attachment = ChatAttachment(id: 9, conversationID: 7, projectID: nil, messageID: 1, name: "plan.pdf",
                                        mime: "application/pdf", size: 2048, path: "p", sha256: "s", createdAt: 0)
        let rows = [
            ChatThreadItem(message: record(1, role: "user", text: "What changed?"), steps: [], siblingIndex: 1,
                           siblingCount: 1, attachments: [attachment]),
            ChatThreadItem(message: record(2, role: "assistant", text: "Three things."),
                           steps: [try step(2, ok: 1, sources: sources)], siblingIndex: 2, siblingCount: 3),
            ChatThreadItem(message: record(3, role: "assistant", text: "", status: "error", errorCode: "auth",
                                           errorMessage: "Sign in again"),
                           steps: [try step(3, ok: nil)], siblingIndex: 1, siblingCount: 1)
        ]

        let messages = EmbeddedChatFeedAdapter.messages(rows: rows, live: nil)

        XCTAssertEqual(messages.map(\.id), [1, 2, 3])
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "assistant"])
        XCTAssertEqual(messages.map(\.text), ["What changed?", "Three things.", ""])
        XCTAssertEqual(messages.map(\.status), ["complete", "complete", "error"])
        XCTAssertEqual(messages[0].createdAt, Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertEqual(messages[0].attachments, [ChatFeed.Attachment(id: 9, name: "plan.pdf", mime: "application/pdf", size: 2048)])
        XCTAssertEqual(messages[1].siblings.index, 2)
        XCTAssertEqual(messages[1].siblings.count, 3)
        XCTAssertEqual(messages[1].steps, [ChatFeed.Step(
            name: "search_messages", outcome: .succeeded, summary: "Found 3 messages",
            sources: [ChatFeed.Source(kind: "slack", title: "#payments", url: "https://example.com/p1", ref: "C1")]
        )])
        XCTAssertEqual(messages[2].steps.map(\.outcome), [.running], "a step the turn left open stays running")
        XCTAssertEqual(messages[2].errorCode, "auth")
        XCTAssertEqual(messages[2].errorMessage, "Sign in again")
        XCTAssertTrue(messages.allSatisfy { $0.parts == nil }, "the adapter builds no parts (D14)")
        // The parts come from the flat fields (D22): the answer's steps and sources, the failed one's error.
        XCTAssertEqual(messages[1].resolvedParts.map(\.kind), [ChatPartKind.text, ChatPartKind.steps, ChatPartKind.sources])
        XCTAssertEqual(messages[2].resolvedParts.map(\.kind), [ChatPartKind.steps, ChatPartKind.error])
    }

    func testTheLiveRowShowsTheStreamPendingWhileItRuns() {
        let rows = [
            ChatThreadItem(message: record(1, role: "user", text: "Hi"), steps: [], siblingIndex: 1, siblingCount: 1),
            ChatThreadItem(message: record(2, role: "assistant", text: "", status: "partial"), steps: [], siblingIndex: 1,
                           siblingCount: 1)
        ]
        let live = LiveTurn(messageID: 2, turnID: "t2", startedAt: .now, publishInterval: 0)
        live.appendDelta("Hello the", now: .now)
        live.startStep(ChatToolStart(turnID: "t2", id: "a", name: "list_messages", argsJSON: "{}"), at: .now)

        let running = EmbeddedChatFeedAdapter.messages(rows: rows, live: live)
        XCTAssertEqual(running[1].text, "Hello the")
        XCTAssertEqual(running[1].status, EmbeddedChatFeedAdapter.pendingStatus)
        XCTAssertEqual(running[1].steps.map(\.name), ["list_messages"])
        XCTAssertEqual(running[0].text, "Hi", "other rows are untouched")

        live.finish(.complete, at: .now)
        XCTAssertEqual(EmbeddedChatFeedAdapter.messages(rows: rows, live: live)[1].status, "partial",
                       "an ended stream keeps its row's own status")
    }

    /// The artifact fence and the question block stay in the text; the shared parsers (ChatUI's `ChatMessageParts`)
    /// turn them into an artifact card and a question card, so the adapter builds neither.
    func testEmbeddedArtifactsAndQuestionsComeFromSharedParser() {
        let text = """
        Here is the plan.

        :::artifact key="plan" kind="document" title="Plan"
        # Plan
        :::

        ```watchtower-question
        {"questions":[{"id":"q","question":"Ship it?","options":[{"label":"Yes"},{"label":"No"}]}]}
        ```
        """
        let row = ChatThreadItem(message: record(1, role: "assistant", text: text), steps: [], siblingIndex: 1,
                                 siblingCount: 1)

        let message = EmbeddedChatFeedAdapter.messages(rows: [row], live: nil)[0]

        XCTAssertNil(message.parts)
        XCTAssertEqual(message.text, text, "the text reaches the feed whole")
        let split = ChatQuestionParser.parse(message.text, final: true)
        XCTAssertEqual(split.card?.questions.map(\.question), ["Ship it?"])
        let artifacts = ArtifactParser.parse(split.text, final: true).segments.compactMap { segment -> String? in
            if case .artifact(let draft) = segment { return draft.key }
            return nil
        }
        XCTAssertEqual(artifacts, ["plan"])
    }
}
