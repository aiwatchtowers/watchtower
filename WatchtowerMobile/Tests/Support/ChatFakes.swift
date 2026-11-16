import ChatWire
import Foundation
import WatchtowerKit
import WatchtowerSync
@testable import WatchtowerMobile

/// A chat sender that records every action instead of queuing it, or refuses them all (`fails`).
@MainActor
final class RecordingChatSender {
    struct Sent: Equatable {
        let kind: ActionKind
        let params: [String: JSONValue]
    }

    private(set) var sent: [Sent] = []
    var fails = false

    struct Refused: Error {}

    var sender: ChatSender {
        ChatSender { [weak self] kind, params in
            guard let self else { return "" }
            if self.fails { throw Refused() }
            self.sent.append(Sent(kind: kind, params: params))
            return "action-\(self.sent.count)"
        }
    }

    /// The params of every action of `P`'s kind sent so far.
    func params<P: ActionParams>(_ type: P.Type) throws -> [P] {
        try sent.filter { $0.kind == P.actionKind }.map { try P(wireParams: $0.params) }
    }

    /// The action id the `index`th send got (1-based, in send order).
    static func actionID(_ index: Int) -> String { "action-\(index)" }
}

/// The chat tests' fixtures.
enum ChatFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func heartbeat(chat: String? = "on", reason: ChatOffReason? = nil, kind: HubKind? = nil) -> HeartbeatPayload {
        HeartbeatPayload(
            updatedAt: now, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
            lastPublishAt: nil, lastRelayAt: nil, relayBacklog: 0, accounts: [],
            enabledAt: now, ownerUser: "", sharing: .none, hubKind: kind,
            capabilities: chat == nil && reason == nil ? nil : HeartbeatCapabilities(chat: chat, chatReason: reason?.rawValue)
        )
    }

    static func grant(chat: Bool?, device: String = "phone-1") -> DeviceGrant { // swiftlint:disable:this discouraged_optional_boolean
        DeviceGrant(
            deviceID: device, hubID: "hub", name: "iPhone", scope: .private, linked: true, typingAllowed: false,
            startSessionsAllowed: false, chatAllowed: chat
        )
    }

    static func conversation(
        _ id: Int64,
        _ title: String = "Chat",
        ago: TimeInterval = 60,
        state: ChatList.State = .read,
        pinned: Bool = false,
        project: String? = nil,
        lastLine: String = ""
    ) -> ChatList.Conversation {
        ChatList.Conversation(
            id: id, title: title, pinned: pinned, updatedAt: now.addingTimeInterval(-ago),
            project: project.map { ChatList.Project(id: 1, name: $0) }, state: state, lastLine: lastLine
        )
    }

    static let list = ChatList(conversations: [conversation(1, "Release checklist")])

    static func inputs(
        heartbeat: HeartbeatPayload? = heartbeat(),
        route: HubRoute? = .hostedRelay(macDeviceID: "mac"),
        grant: DeviceGrant? = grant(chat: true),
        refusal: String? = nil,
        list: ChatList? = list,
        mac: MacReachability = .online,
        relayUnreachable: Bool = false
    ) -> ChatsGateInputs {
        ChatsGateInputs(
            heartbeat: heartbeat, route: route, grant: grant, refusal: refusal, list: list, mac: mac,
            relayUnreachable: relayUnreachable
        )
    }
}

extension ChatFixture {
    static func message(
        _ id: Int64,
        _ role: String = "assistant",
        _ text: String = "Text",
        status: String = "complete",
        errorCode: String? = nil,
        errorMessage: String? = nil,
        siblings: ChatFeed.Siblings = .init(),
        steps: [ChatFeed.Step] = []
    ) -> ChatFeed.Message {
        ChatFeed.Message(
            id: id, role: role, text: text, status: status, errorCode: errorCode, errorMessage: errorMessage,
            createdAt: now.addingTimeInterval(Double(id)), siblings: siblings, steps: steps
        )
    }

    static func feed(
        _ id: Int64 = 7,
        messages: [ChatFeed.Message],
        lease: ChatFeed.Lease? = nil,
        hasMore: Bool = false,
        artifacts: [ChatFeed.Artifact] = [],
        actions: [ChatFeed.Action] = []
    ) -> ChatFeed {
        ChatFeed(
            conversation: .init(id: id, title: "Q3 roadmap summary", actualProvider: "claude", lease: lease),
            messages: messages, hasMore: hasMore, artifacts: artifacts, actions: actions
        )
    }

    static func entry(_ feed: ChatFeed) -> ChatFeedEntry {
        ChatFeedEntry(feed: feed, payload: Data("\(feed.conversation.id)-\(feed.messages.map(\.id))-\(feed.messages.map(\.text))".utf8))
    }

    static func page(_ messages: [ChatFeed.Message], hasMore: Bool = false) -> ChatPageEntry {
        ChatPageEntry(page: ChatPage(messages: messages, hasMore: hasMore), payload: Data("\(messages.map(\.id))".utf8))
    }

    /// A center whose sends go to `recorder`, its sleeps to `sleeper`.
    @MainActor
    static func center(_ recorder: RecordingChatSender, sleeper: TickSleeper, uploads: ChatUploads = .none) -> ChatsCenter {
        ChatsCenter(sender: recorder.sender, uploads: uploads, now: { now }, sleep: { try await sleeper.sleep($0) })
    }
}

/// Repeats the conversation's feed request only when the test yields.
@MainActor
final class ChatTicks {
    private var continuation: AsyncStream<Void>.Continuation?

    func stream() -> AsyncStream<Void> {
        AsyncStream { continuation = $0 }
    }

    func tick() { continuation?.yield() }
}
