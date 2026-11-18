import Foundation

/// Why a connect flow failed — `slack connect serve`'s `failed` reasons
/// (plan B Task 7). A reason this build does not know reads as `.other`.
package enum SlackConnectFailure: String, Codable, Equatable, Sendable {
    case teamMismatch = "team_mismatch"
    case otherUser = "other_user"
    case denied
    case cancelled
    case exchange
    case policy
    case purgeRunning = "purge_running"
    case other

    package init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .other
    }
}

/// One stdout line of `watchtower slack connect serve` (plan B Task 7): the
/// Swift twin of the Go events, one case per `event` value.
package enum SlackConnectEvent: Codable, Equatable, Sendable {
    /// The child holds 127.0.0.1:`port`.
    case listening(port: Int)
    /// Something else holds `port`; the child exits 3 next.
    case portBusy(port: Int)
    /// A colleague opened the connect link: needs the owner's confirm.
    case link(flow: String, teamID: String, clientID: String)
    /// The authorize URL was opened in the browser.
    case browser(flow: String)
    /// The account is written; `reboundFrom` is the old client id, or "".
    case connected(flow: String, accountID: Int64, teamID: String, teamName: String, reboundFrom: String)
    case failed(flow: String, reason: SlackConnectFailure, message: String)
    /// A second start was refused; `flow` is the running one.
    case busy(flow: String)

    private enum Kind: String, Codable {
        case listening, link, browser, connected, failed, busy
        case portBusy = "port_busy"
    }

    private enum Keys: String, CodingKey {
        case event, port, flow, reason, message
        case teamID = "team_id"
        case clientID = "client_id"
        case accountID = "account_id"
        case teamName = "team_name"
        case reboundFrom = "rebound_from"
    }

    package init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: Keys.self)
        switch try box.decode(Kind.self, forKey: .event) {
        case .listening: self = .listening(port: try box.decode(Int.self, forKey: .port))
        case .portBusy: self = .portBusy(port: try box.decode(Int.self, forKey: .port))
        case .link:
            self = .link(
                flow: try box.decode(String.self, forKey: .flow),
                teamID: try box.decode(String.self, forKey: .teamID),
                clientID: try box.decode(String.self, forKey: .clientID)
            )
        case .browser: self = .browser(flow: try box.decode(String.self, forKey: .flow))
        case .connected:
            self = .connected(
                flow: try box.decode(String.self, forKey: .flow),
                accountID: try box.decode(Int64.self, forKey: .accountID),
                teamID: try box.decode(String.self, forKey: .teamID),
                teamName: try box.decode(String.self, forKey: .teamName),
                reboundFrom: try box.decodeIfPresent(String.self, forKey: .reboundFrom) ?? ""
            )
        case .failed:
            self = .failed(
                flow: try box.decode(String.self, forKey: .flow),
                reason: try box.decode(SlackConnectFailure.self, forKey: .reason),
                message: try box.decodeIfPresent(String.self, forKey: .message) ?? ""
            )
        case .busy: self = .busy(flow: try box.decode(String.self, forKey: .flow))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .listening(port):
            try box.encode(Kind.listening, forKey: .event)
            try box.encode(port, forKey: .port)
        case let .portBusy(port):
            try box.encode(Kind.portBusy, forKey: .event)
            try box.encode(port, forKey: .port)
        case let .link(flow, teamID, clientID):
            try box.encode(Kind.link, forKey: .event)
            try box.encode(flow, forKey: .flow)
            try box.encode(teamID, forKey: .teamID)
            try box.encode(clientID, forKey: .clientID)
        case let .browser(flow):
            try box.encode(Kind.browser, forKey: .event)
            try box.encode(flow, forKey: .flow)
        case let .connected(flow, accountID, teamID, teamName, reboundFrom):
            try box.encode(Kind.connected, forKey: .event)
            try box.encode(flow, forKey: .flow)
            try box.encode(accountID, forKey: .accountID)
            try box.encode(teamID, forKey: .teamID)
            try box.encode(teamName, forKey: .teamName)
            try box.encode(reboundFrom, forKey: .reboundFrom)
        case let .failed(flow, reason, message):
            try box.encode(Kind.failed, forKey: .event)
            try box.encode(flow, forKey: .flow)
            try box.encode(reason, forKey: .reason)
            try box.encode(message, forKey: .message)
        case let .busy(flow):
            try box.encode(Kind.busy, forKey: .event)
            try box.encode(flow, forKey: .flow)
        }
    }
}

/// One stdin line to `watchtower slack connect serve` (plan B Task 7).
package enum SlackConnectCommand: Encodable, Equatable, Sendable {
    /// Starts a flow without the confirm step (paste, MDM, Reconnect, setup).
    /// `accountID` nil: the team's live row, else a new one.
    case start(teamID: String, clientID: String, accountID: Int64?)
    /// The owner confirmed the `link` flow.
    case confirm(flow: String)
    case cancel(flow: String)

    private enum Keys: String, CodingKey {
        case cmd, flow
        case teamID = "team_id"
        case clientID = "client_id"
        case accountID = "account_id"
    }

    package func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .start(teamID, clientID, accountID):
            try box.encode("start", forKey: .cmd)
            try box.encode(teamID, forKey: .teamID)
            try box.encode(clientID, forKey: .clientID)
            try box.encodeIfPresent(accountID, forKey: .accountID)
        case let .confirm(flow):
            try box.encode("confirm", forKey: .cmd)
            try box.encode(flow, forKey: .flow)
        case let .cancel(flow):
            try box.encode("cancel", forKey: .cmd)
            try box.encode(flow, forKey: .flow)
        }
    }

    /// The command as one JSON line (with its `\n`).
    package func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}
