import Foundation
import WatchtowerKit
import WatchtowerSync

/// What the Chats tab's gate reads (iPhone chat spec §6.1): the hub's heartbeat and this phone's grant, the route
/// the phone reaches the hub by, the newest chat refusal, the held `chat_list`, and whether the hub answers now.
struct ChatsGateInputs: Equatable {
    var heartbeat: HeartbeatPayload?
    var route: HubRoute?
    var grant: DeviceGrant?
    /// The message of the newest chat action refused with `device_not_allowed` (`ChatsSnapshot.refusal`).
    var refusal: String?
    var list: ChatList?
    var mac: MacReachability
    /// On Relay, the relay stopped answering this session's fetches.
    var relayUnreachable = false

    var host: TowerHost { TowerHost(heartbeat, device: grant?.deviceID) }
}

/// The Chats tab's state and its copy (iPhone chat spec §6.1), checked in this order: needs update, turned off by
/// the organization's policy, needs Relay, not allowed, unavailable (chat off for another reason), loading, error
/// with Retry, empty, offline (read only), ready.
struct ChatsGateModel: Equatable {
    enum State: Equatable {
        case needsUpdate
        case turnedOff
        case needsRelay
        case notAllowed
        case unavailable
        case loading
        case error
        case empty
        case offline
        case ready
    }

    enum Action: Equatable {
        /// Opens Settings → Towers → this hub (mockup 1e).
        case switchToRelay
        /// Asks the hub to publish `chat_list` again (mockup 1h).
        case retry
        /// Starts a new chat (mockup 1b).
        case newChat
    }

    static let policyTitle = "Chat is turned off by your organization"
    static let policyLine = "Your organization's policy keeps chat off this phone."
    static let relayTitle = "Chat works over Relay"
    static let switchToRelay = "Switch to Relay…"
    static let notAllowedTitle = "Chat is off for this phone"
    static let unavailableTitle = "Chat isn't available right now"
    static let errorTitle = "Couldn't load chats"
    static let retry = "Retry"
    static let emptyTitle = "No chats yet"
    static let relayUnreachableLine = "Relay isn't answering. You can read chats; sending works when it is back."

    let state: State
    /// The centred message's title and line (every state but loading, offline and ready).
    let title: String?
    let line: String?
    let action: Action?
    /// The line over the list or the loading bars: the loading line, the offline line, or a read error over rows
    /// still held.
    let banner: String?
    /// Whether a new chat can start now (✎ and the empty state's button): only while the hub answers.
    let canCreate: Bool
    /// The hub answers now: the Mac is online and, on Relay, the relay answers. Search asks the hub only then.
    let online: Bool

    var actionTitle: String? {
        switch action {
        case .switchToRelay: Self.switchToRelay
        case .retry: Self.retry
        case .newChat: ChatListModel.newChatLabel
        case nil: nil
        }
    }

    /// ✎ is on the bar (mockups 1a–1d): with the list, its loading bars or the empty state; a state that keeps chat
    /// off has none.
    var showsNewChat: Bool { showsList || state == .loading || state == .empty }

    /// The list (or its loading bars) shows; every other state is a centred message.
    var showsList: Bool { state == .ready || state == .offline }

    init(_ inputs: ChatsGateInputs) {
        let host = inputs.host
        let online = inputs.mac.isOnline && !inputs.relayUnreachable
        var banner: String?
        if inputs.relayUnreachable, inputs.mac.isOnline {
            banner = Self.relayUnreachableLine
        } else if case .asleep = inputs.mac {
            banner = ChatText.asleep(host)
        } else if !inputs.mac.isOnline {
            banner = ChatText.offline(host)
        }
        let capabilities = inputs.heartbeat?.capabilities
        let state: State
        var title: String?
        var line: String?
        var action: Action?
        if inputs.heartbeat == nil {
            // Nothing heard from the hub yet: its capability is unknown, not absent.
            state = .loading
            banner = ChatText.loading(host)
        } else if capabilities?.chat == nil || capabilities?.chatOffReason == .desktopTooOld {
            (state, title, line) = (.needsUpdate, ChatText.updateTitle(host), ChatText.updateLine(host))
        } else if inputs.heartbeat?.chatOffered != true, capabilities?.chatOffReason == .policy {
            (state, title, line) = (.turnedOff, Self.policyTitle, Self.policyLine)
        } else if inputs.route?.cloudKitScope != nil {
            (state, title, line, action) = (.needsRelay, Self.relayTitle, ChatText.relayLine, .switchToRelay)
        } else if !(inputs.grant?.chatAllowed ?? true) || inputs.refusal != nil {
            (state, title, line) = (.notAllowed, Self.notAllowedTitle, Self.notAllowedLine(host, refusal: inputs.refusal))
        } else if inputs.heartbeat?.chatOffered != true {
            (state, title, line) = (.unavailable, Self.unavailableTitle, ChatText.unavailableLine(host))
        } else if let list = inputs.list {
            if list.error != nil, list.conversations.isEmpty {
                (state, title, line, action) = (.error, Self.errorTitle, ChatText.readFailed(host), .retry)
            } else if list.conversations.isEmpty {
                (state, title, line, action) = (.empty, Self.emptyTitle, ChatText.emptyLine(host), .newChat)
            } else {
                state = online ? .ready : .offline
                if list.error != nil, banner == nil { banner = ChatText.readFailed(host) }
            }
        } else {
            state = .loading
            banner = ChatText.loading(host)
        }
        self.state = state
        self.title = title
        self.line = line
        self.action = action
        self.banner = Self.showsBanner(state) ? banner : nil
        self.online = online
        canCreate = online && (state == .ready || state == .empty)
    }

    private static func showsBanner(_ state: State) -> Bool {
        state == .loading || state == .ready || state == .offline
    }

    /// The step that allows chat: the Mac app's Settings on a Mac hub; on a server the refusal's
    /// `watchtower hub allow … chat` line, else one built from this phone's id.
    static func notAllowedLine(_ host: TowerHost, refusal: String?) -> String {
        switch host {
        case .mac:
            return ChatText.macAllowLine
        case let .server(device):
            let lines = (refusal ?? "").split(separator: "\n").map(String.init).filter { $0.hasPrefix("watchtower hub allow ") }
            let command = lines.first ?? TowerHost.allowCommand("chat", device: device)
            return "On your tower, run:\n\(command)"
        }
    }
}
