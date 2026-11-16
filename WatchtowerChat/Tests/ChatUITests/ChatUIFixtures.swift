import ChatWire
import Foundation

/// Builders of feeds and messages for the tests, and the shared fixtures read where they live.
enum ChatUIFixtures {
    /// The repository root, from …/WatchtowerChat/Tests/ChatUITests/<this file>.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ChatUITests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerChat
        .deletingLastPathComponent()

    static let chatUISources = repoRoot.appendingPathComponent("WatchtowerChat/Sources/ChatUI")

    static func goFixture(_ path: String) -> URL {
        repoRoot.appendingPathComponent("internal/\(path)")
    }

    static let date = Date(timeIntervalSince1970: 1_794_000_000)

    static func message(
        _ id: Int64,
        role: String = "assistant",
        text: String = "",
        status: String = "complete",
        errorCode: String? = nil,
        steps: [ChatFeed.Step] = [],
        parts: [ChatPart]? = nil
    ) -> ChatFeed.Message {
        ChatFeed.Message(id: id, role: role, text: text, status: status, errorCode: errorCode, createdAt: date,
                         steps: steps, parts: parts)
    }

    static func feed(
        id: Int64 = 7, messages: [ChatFeed.Message], lease: ChatFeed.Lease? = nil, actions: [ChatFeed.Action] = []
    ) -> ChatFeed {
        ChatFeed(
            conversation: ChatFeed.Conversation(id: id, title: "Plan", routing: ChatFeed.Routing(mode: "auto"),
                                                actualProvider: "claude", actualModel: "sonnet", lease: lease),
            messages: messages,
            actions: actions
        )
    }
}
