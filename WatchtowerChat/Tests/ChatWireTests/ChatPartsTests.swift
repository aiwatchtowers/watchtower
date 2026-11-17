import ChatWire
import XCTest

/// The message parts (unified chat spec §5.3) against Go's `internal/chatengine/testdata/parts.json`, and the
/// flat-fields → parts adapter for a Mac one version behind (D22).
final class ChatPartsTests: XCTestCase {
    private struct Sample: Decodable {
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

        enum CodingKeys: String, CodingKey {
            case kind, clientDerived, message, part
        }
    }

    private struct TextPayload: Decodable, Equatable {
        let text: String
        let textCut: Bool
    }

    private func samples() throws -> [Sample] {
        let data = try Data(contentsOf: ChatWireFixtures.goFixture("chatengine/testdata/parts.json"))
        return try ChatWireCoder.makeDecoder().decode([Sample].self, from: data)
    }

    func testPartsFixtureDecodesEveryKind() throws {
        let samples = try samples()
        XCTAssertEqual(samples.map(\.kind), ChatPartKind.all)
        for sample in samples {
            // The client-derived kinds travel inside the text part, whose fallback stands in for them.
            let wireKind = sample.clientDerived ? ChatPartKind.text : sample.kind
            XCTAssertEqual(sample.part.kind, wireKind, sample.kind)
            XCTAssertNotNil(sample.part.payload, sample.kind)
            XCTAssertFalse(sample.part.fallback.text.isEmpty, sample.kind)
        }
        let text = try XCTUnwrap(samples.first { $0.kind == ChatPartKind.text })
        XCTAssertEqual(try text.part.decodePayload(TextPayload.self), TextPayload(text: "Here is the **plan**.", textCut: false))
        let error = try XCTUnwrap(samples.first { $0.kind == ChatPartKind.error })
        XCTAssertEqual(error.part.fallback.actions, [.init(label: "Try again", action: "chat_turn", text: "Please try again.")])
        let link = try XCTUnwrap(samples.first { $0.kind == ChatPartKind.publishedLink })
        XCTAssertEqual(link.part.fallback.actions.first?.action, "open_url")
        XCTAssertNotNil(link.part.fallback.actions.first?.url)
    }

    func testAPartWithoutPayloadKeepsItsFallback() throws {
        let json = #"{"kind":"approval","fallback":{"text":"Send a Slack message — waiting","actions":[]}}"#
        let part = try ChatWireCoder.makeDecoder().decode(ChatPart.self, from: Data(json.utf8))
        XCTAssertNil(part.payload)
        XCTAssertNil(try part.decodePayload(TextPayload.self))
        XCTAssertEqual(part.fallback.text, "Send a Slack message — waiting")
    }

    func testFeedPartsArePreferred() throws {
        let feed = try feedFixture(strippingParts: false)
        let owner = feed.messages[0]
        XCTAssertNotNil(owner.parts)
        XCTAssertEqual(owner.resolvedParts, owner.parts)
    }

    func testFeedWithoutPartsBuildsPartsFromFlatFields() throws {
        let feed = try feedFixture(strippingParts: true)
        XCTAssertTrue(feed.messages.allSatisfy { $0.parts == nil })

        let owner = feed.messages[0]
        XCTAssertEqual(owner.resolvedParts.map(\.kind), [ChatPartKind.text, ChatPartKind.attachment])
        XCTAssertEqual(
            try owner.resolvedParts[0].decodePayload(TextPayload.self),
            TextPayload(text: owner.text, textCut: owner.textCut)
        )
        XCTAssertEqual(owner.resolvedParts[0].fallback.text, owner.text)
        XCTAssertEqual(try owner.resolvedParts[1].decodePayload(ChatFeed.Attachment.self), owner.attachments[0])
        XCTAssertEqual(owner.resolvedParts[1].fallback.text, "Attachment: plan.pdf (application/pdf, 2 KB)")

        let answer = feed.messages[1]
        XCTAssertEqual(answer.resolvedParts.map(\.kind), [ChatPartKind.text, ChatPartKind.steps, ChatPartKind.sources])
        let steps = answer.resolvedParts[1]
        XCTAssertEqual(steps.fallback.text, "Steps:\n- 2 results (done)\n- list_messages")
        XCTAssertEqual(
            steps.payload,
            .object(["steps": .array([
                .object(["name": .string("search_knowledge"), "ok": .bool(true), "summary": .string("2 results")]),
                .object(["name": .string("list_messages"), "summary": .string("")])
            ])])
        )
        XCTAssertEqual(answer.resolvedParts[2].fallback.text, "Sources:\n- #payments (https://example.com/p1)")

        let cut = feed.messages[3]
        XCTAssertEqual(cut.resolvedParts.map(\.kind), [ChatPartKind.text, ChatPartKind.error])
        XCTAssertEqual(try cut.resolvedParts[0].decodePayload(TextPayload.self)?.textCut, true)
        XCTAssertEqual(cut.resolvedParts[1].fallback.text, "Something went wrong while answering.\nThe session ended.")
    }

    /// A published claude.ai page is a `published_link` card (Go `publishedLinkParts`), never a source: each permitted
    /// URL once, before the error; any other URL is no card.
    func testFlatFieldsBuildPublishedLinksAsGoDoes() throws {
        func page(_ url: String, _ title: String = "Plan") -> ChatFeed.Source {
            ChatFeed.Source(kind: "claude_ai_published", title: title, url: url)
        }
        let steps = [
            ChatFeed.Step(name: "Artifact", outcome: .succeeded, summary: "Published", sources: [
                page("https://claude.ai/public/artifacts/abc"), page("https://claude.ai/public/artifacts/abc", "Again"),
                page("https://example.com/x"), page("http://claude.ai/artifact/abc"), page("https://claude.ai/"),
                page("https://user@claude.ai/p"), page("https://claude.ai:8443/p"), page("https://claude.ai/p2", "  ") // leak-check:allow (a URL with credentials, refused)
            ]),
            ChatFeed.Step(name: "search_messages", outcome: .succeeded, summary: "1 result", sources: [
                ChatFeed.Source(kind: "slack", title: "#payments", url: "https://example.com/p1", ref: "C1")
            ])
        ]
        let message = ChatFeed.Message(id: 1, role: "assistant", text: "Done", status: "error", errorCode: "auth",
                                       createdAt: .distantPast, steps: steps)

        XCTAssertEqual(message.resolvedParts.map(\.kind), [
            ChatPartKind.text, ChatPartKind.steps, ChatPartKind.sources, ChatPartKind.publishedLink,
            ChatPartKind.publishedLink, ChatPartKind.error
        ])
        let links = message.resolvedParts.filter { $0.kind == ChatPartKind.publishedLink }
        XCTAssertEqual(links.map(\.payload), [
            .object(["title": .string("Plan"), "url": .string("https://claude.ai/public/artifacts/abc")]),
            .object(["title": .string("https://claude.ai/p2"), "url": .string("https://claude.ai/p2")])
        ])
        XCTAssertEqual(links[0].fallback.text, "Published on claude.ai: Plan")
        XCTAssertEqual(links[0].fallback.actions,
                       [ChatPartFallback.Action(label: "Open", action: "open_url", url: "https://claude.ai/public/artifacts/abc")])
        XCTAssertEqual(message.resolvedParts[2].fallback.text, "Sources:\n- #payments (https://example.com/p1)",
                       "a published page is not a source")
    }

    /// The Kit's `chat_feed.json`, its `parts` removed when asked (a Mac one version behind).
    private func feedFixture(strippingParts: Bool) throws -> ChatFeed {
        var data = try Data(contentsOf: ChatWireFixtures.kitFixture("workbench/chat_feed.json"))
        if strippingParts {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
            object["messages"] = messages.map { message in
                var message = message
                message["parts"] = nil
                return message
            }
            data = try JSONSerialization.data(withJSONObject: object)
        }
        return try ChatWireCoder.makeDecoder().decode(ChatFeed.self, from: data)
    }
}
