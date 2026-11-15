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
            guard let self else { return }
            if self.fails { throw Refused() }
            self.sent.append(Sent(kind: kind, params: params))
        }
    }
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
