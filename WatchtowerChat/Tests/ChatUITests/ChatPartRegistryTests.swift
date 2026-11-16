import ChatWire
import XCTest
@testable import ChatUI

/// CHAT-06 (Swift half), D14 and the fallback view.
final class ChatPartRegistryTests: XCTestCase {
    private struct FixtureEntry: Decodable {
        let kind: String
        let clientDerived: Bool
        let message: ChatFeed.Message
        let part: ChatPart

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            clientDerived = try c.decodeIfPresent(Bool.self, forKey: .clientDerived) ?? false
            message = try c.decode(ChatFeed.Message.self, forKey: .message)
            part = try c.decode(ChatPart.self, forKey: .part)
        }

        enum CodingKeys: String, CodingKey { case kind, clientDerived, message, part }
    }

    private func fixture() throws -> [FixtureEntry] {
        let data = try Data(contentsOf: ChatUIFixtures.goFixture("chatengine/testdata/parts.json"))
        return try ChatWireCoder.makeDecoder().decode([FixtureEntry].self, from: data)
    }

    private func context(_ message: ChatFeed.Message) -> ChatPartContext {
        ChatPartContext(message: message)
    }

    /// BEHAVIOR CHAT-06 — see docs/inventory/chat.md
    /// Every kind the engine emits, and every client-derived kind, has a registered ChatUI view; an emitted kind's
    /// sample renders that view (not its fallback) and carries a non-empty fallback FallbackPartView can draw.
    func testChat06EveryFixtureKindIsRegistered() throws {
        let entries = try fixture()
        let kinds = Set(entries.map(\.kind))
        XCTAssertFalse(kinds.isEmpty)
        XCTAssertTrue(kinds.isSubset(of: ChatPartRegistry.registered),
                      "kinds without a ChatUI view: \(kinds.subtracting(ChatPartRegistry.registered).sorted())")
        XCTAssertEqual(Set(ChatPartKind.all), kinds, "parts.json and ChatWire's kind list drifted")
        for entry in entries {
            if entry.clientDerived {
                // The sample's text part, as the engine sends it on the message.
                let message = ChatUIFixtures.message(entry.message.id, text: entry.message.text, parts: [entry.part])
                let derived = ChatMessageParts.parts(for: message).filter { $0.kind == entry.kind }
                XCTAssertEqual(derived.count, 1, "\(entry.kind) is split out of the text once")
                for part in derived {
                    XCTAssertFalse(part.fallback.text.isEmpty, "\(entry.kind): the text is its fallback")
                    XCTAssertFalse(ChatPartRegistry.viewType(for: part, context: context(entry.message)) == FallbackPartView.self,
                                   "\(entry.kind) renders its own view")
                }
            } else {
                XCTAssertEqual(entry.part.kind, entry.kind)
                XCTAssertFalse(entry.part.fallback.text.isEmpty, "\(entry.kind) has a fallback text")
                XCTAssertEqual(FallbackPartView.buttons(entry.part.fallback).count, entry.part.fallback.actions.count)
                XCTAssertFalse(ChatPartRegistry.viewType(for: entry.part, context: context(entry.message)) == FallbackPartView.self,
                               "\(entry.kind)'s sample payload renders its registered view")
            }
        }
    }

    func testUnknownPartRendersFallback() throws {
        let part = ChatPart(
            kind: "future_kind",
            payload: .object(["anything": .string("x")]),
            fallback: ChatPartFallback(text: "Send a Slack message to #general — waiting for your approval", actions: [
                .init(label: "Open on the Mac", action: "none"),
                .init(label: "Try again", action: "chat_turn", text: "Please try again."),
                .init(label: "Open", action: "open_url", url: "https://example.com/page")
            ])
        )
        let message = ChatUIFixtures.message(2, parts: [part])
        XCTAssertTrue(ChatPartRegistry.viewType(for: part, context: context(message)) == FallbackPartView.self)
        let buttons = FallbackPartView.buttons(part.fallback)
        XCTAssertEqual(buttons.map(\.label), ["Open on the Mac", "Try again", "Open"], "one button per action")
        XCTAssertEqual(buttons.map(\.effect), [
            .none, .turn("Please try again."), .open(try XCTUnwrap(URL(string: "https://example.com/page")))
        ])
    }

    func testKnownKindWithUnreadablePayloadRendersFallback() {
        let part = ChatPart(kind: ChatPartKind.approval, payload: .string("no"), fallback: ChatPartFallback(text: "x"))
        XCTAssertTrue(ChatPartRegistry.viewType(for: part, context: context(ChatUIFixtures.message(1))) == FallbackPartView.self)
        let bare = ChatPart(kind: ChatPartKind.steps, payload: nil, fallback: ChatPartFallback(text: "Steps"))
        XCTAssertTrue(ChatPartRegistry.viewType(for: bare, context: context(ChatUIFixtures.message(1))) == FallbackPartView.self,
                      "a kind the engine sent without its payload (D15) draws the fallback")
    }

    /// D14: artifact and question come out of the text on the client only; a server-sent one is never drawn beside it.
    func testServerArtifactOrQuestionPartIsNotDrawnTwice() {
        let text = "Here:\n:::artifact key=\"q3\" kind=\"document\" title=\"Q3 plan\"\n# Q3\n:::\nDone."
        let textPart = ChatPart(kind: ChatPartKind.text, payload: .object(["text": .string(text)]),
                                fallback: ChatPartFallback(text: text))
        let serverArtifact = ChatPart(kind: ChatPartKind.artifact, payload: .object(["key": .string("q3")]),
                                      fallback: ChatPartFallback(text: "Q3 plan"))
        let parts = ChatMessageParts.parts(for: ChatUIFixtures.message(2, text: text, parts: [textPart, serverArtifact]))
        XCTAssertEqual(parts.map(\.kind), ["text", "artifact", "text"])
        XCTAssertEqual(parts.filter { $0.kind == ChatPartKind.artifact }.count, 1)
        XCTAssertEqual(ChatMessageParts.draft(parts[1])?.title, "Q3 plan")
    }

    func testStreamingArtifactIsHeldAsWriting() throws {
        let text = "Here:\n:::artifact key=\"q3\" kind=\"document\" title=\"Q3 plan\"\n# Q3"
        let parts = ChatMessageParts.parts(for: ChatUIFixtures.message(2, text: text, status: "pending"))
        let draft = try XCTUnwrap(parts.first { $0.kind == ChatPartKind.artifact }.flatMap(ChatMessageParts.draft))
        XCTAssertFalse(draft.isComplete)
    }

    /// Carry (older Mac on a new phone): a feed whose messages carry no parts still shows its flat actions.
    func testFeedActionsWithoutPartsRenderAsApprovals() {
        let action = ChatFeed.Action(id: 9, tool: "send_slack_message", title: "Send slack message",
                                     argsDisplay: "{}", argsSHA256: "abc", status: "pending")
        let rows = ChatFeedLayout.rows(messages: [ChatUIFixtures.message(2, text: "Sending.")], actions: [action])
        XCTAssertEqual(rows.last, .approvals([action]))

        let shown = ChatPart(kind: ChatPartKind.approval, payload: .object([
            "id": .integer(9), "tool": .string("send_slack_message"), "status": .string("pending")
        ]), fallback: ChatPartFallback(text: "Send"))
        let withPart = ChatFeedLayout.rows(messages: [ChatUIFixtures.message(2, parts: [shown])], actions: [action])
        XCTAssertEqual(withPart.count, 1, "an action a part already shows is not drawn again")
    }

    func testSlackApprovalReadsRecipientAndText() throws {
        let payload = ChatApprovalPayload(
            id: 9, tool: "send_slack_message", title: "Send",
            argsDisplay: ##"{"target": {"label": "#general", "workspace": "acme"}, "text": "hi"}"##,
            argsSHA256: "abc", status: "pending"
        )
        let slack = try XCTUnwrap(SlackApproval(payload))
        XCTAssertEqual(slack.recipient, "To: #general · acme")
        XCTAssertEqual(slack.text, "hi")
        XCTAssertNil(ConnectorApproval(payload))
    }
}
