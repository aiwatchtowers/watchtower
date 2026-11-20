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

/// A `connected` event's payload: the account is written.
package struct SlackConnectedAccount: Equatable, Sendable {
    package let flow: String
    package let accountID: Int64
    package let teamID: String
    package let teamName: String
    /// The client id the row was on before (a rebind), or "".
    package let reboundFrom: String

    package init(flow: String, accountID: Int64, teamID: String, teamName: String, reboundFrom: String) {
        self.flow = flow
        self.accountID = accountID
        self.teamID = teamID
        self.teamName = teamName
        self.reboundFrom = reboundFrom
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
    case connected(SlackConnectedAccount)
    case failed(flow: String, reason: SlackConnectFailure, message: String)
    /// A start was refused; `flow` is the running one (a Slack flow, or a
    /// company chain).
    case busy(flow: String)
    /// A link that arrived while `flow` runs was refused; never the answer
    /// to a start (review m5).
    case linkBusy(flow: String)
    /// A company link waits for the person's confirm (#1887 Task 10):
    /// `bundle` is its wire form; nothing is stored before the app confirms.
    case companyLink(flow: String, bundle: String)
    /// One vendor's step of a company chain (Task 11).
    case companyVendor(CompanyVendorStep)
    /// The chain ended: each vendor it was given, by its end state.
    case companyDone(flow: String, states: [CompanyVendor: CompanyChainState])

    private enum Kind: String, Codable {
        case listening, link, browser, connected, failed, busy
        case portBusy = "port_busy"
        case companyLink = "company_link"
        case companyVendor = "company_vendor"
        case companyDone = "company_done"
        case linkBusy = "link_busy"
    }

    private enum Keys: String, CodingKey {
        case event, port, flow, reason, message, bundle, vendor, state, label, states
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
            self = .connected(SlackConnectedAccount(
                flow: try box.decode(String.self, forKey: .flow),
                accountID: try box.decode(Int64.self, forKey: .accountID),
                teamID: try box.decode(String.self, forKey: .teamID),
                teamName: try box.decode(String.self, forKey: .teamName),
                reboundFrom: try box.decodeIfPresent(String.self, forKey: .reboundFrom) ?? ""
            ))
        case .failed:
            self = .failed(
                flow: try box.decode(String.self, forKey: .flow),
                reason: try box.decode(SlackConnectFailure.self, forKey: .reason),
                message: try box.decodeIfPresent(String.self, forKey: .message) ?? ""
            )
        case .busy: self = .busy(flow: try box.decode(String.self, forKey: .flow))
        case .companyLink:
            self = .companyLink(flow: try box.decode(String.self, forKey: .flow),
                                bundle: try box.decode(String.self, forKey: .bundle))
        case .companyVendor:
            self = .companyVendor(CompanyVendorStep(
                flow: try box.decode(String.self, forKey: .flow),
                vendor: try box.decode(CompanyVendor.self, forKey: .vendor),
                state: try box.decode(CompanyChainState.self, forKey: .state),
                label: try box.decodeIfPresent(String.self, forKey: .label) ?? "",
                message: try box.decodeIfPresent(String.self, forKey: .message) ?? ""
            ))
        case .companyDone:
            // A vendor this build does not know is left out.
            let raw = try box.decode([String: CompanyChainState].self, forKey: .states)
            var states: [CompanyVendor: CompanyChainState] = [:]
            for (key, state) in raw {
                if let vendor = CompanyVendor(rawValue: key) { states[vendor] = state }
            }
            self = .companyDone(flow: try box.decode(String.self, forKey: .flow), states: states)
        case .linkBusy: self = .linkBusy(flow: try box.decode(String.self, forKey: .flow))
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
        case let .connected(account):
            try box.encode(Kind.connected, forKey: .event)
            try box.encode(account.flow, forKey: .flow)
            try box.encode(account.accountID, forKey: .accountID)
            try box.encode(account.teamID, forKey: .teamID)
            try box.encode(account.teamName, forKey: .teamName)
            try box.encode(account.reboundFrom, forKey: .reboundFrom)
        case let .failed(flow, reason, message):
            try box.encode(Kind.failed, forKey: .event)
            try box.encode(flow, forKey: .flow)
            try box.encode(reason, forKey: .reason)
            try box.encode(message, forKey: .message)
        case let .busy(flow):
            try box.encode(Kind.busy, forKey: .event)
            try box.encode(flow, forKey: .flow)
        case let .companyLink(flow, bundle):
            try box.encode(Kind.companyLink, forKey: .event)
            try box.encode(flow, forKey: .flow)
            try box.encode(bundle, forKey: .bundle)
        case let .companyVendor(step):
            try box.encode(Kind.companyVendor, forKey: .event)
            try box.encode(step.flow, forKey: .flow)
            try box.encode(step.vendor, forKey: .vendor)
            try box.encode(step.state, forKey: .state)
            try box.encode(step.label, forKey: .label)
            try box.encode(step.message, forKey: .message)
        case let .companyDone(flow, states):
            try box.encode(Kind.companyDone, forKey: .event)
            try box.encode(flow, forKey: .flow)
            try box.encode(Dictionary(uniqueKeysWithValues: states.map { ($0.key.rawValue, $0.value) }), forKey: .states)
        case let .linkBusy(flow):
            try box.encode(Kind.linkBusy, forKey: .event)
            try box.encode(flow, forKey: .flow)
        }
    }
}

/// A `company_vendor` event's payload. `label` names the account only for
/// Slack; `message` says why on cancelled, failed or a policy skip.
package struct CompanyVendorStep: Equatable, Sendable {
    package let flow: String
    package let vendor: CompanyVendor
    package let state: CompanyChainState
    package let label: String
    package let message: String

    package init(flow: String, vendor: CompanyVendor, state: CompanyChainState, label: String = "", message: String = "") {
        self.flow = flow
        self.vendor = vendor
        self.state = state
        self.label = label
        self.message = message
    }
}

/// A vendor's state in a company chain (Go `company_vendor`'s `state`). A
/// state this build does not know reads as `.failed`: as far as this build
/// can tell, the vendor did not connect.
package enum CompanyChainState: String, Codable, Equatable, Sendable {
    case waiting, connected, cancelled, failed, skipped

    package init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .failed
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
    /// Starts the company chain for stored company `slug` over `vendors`
    /// (Go orders them); releases the company link `flow` answers.
    case companyConnect(flow: String, slug: String, vendors: [CompanyVendor])
    /// Ends the waiting vendor's step only: `vendor` names it, so a Skip that
    /// arrives after that vendor ended does not skip the next one.
    case companySkip(flow: String, vendor: CompanyVendor?)
    /// Ends the wait and skips every vendor left.
    case companyStop(flow: String)
    /// The app answered a company link without a chain (Cancel, Keep
    /// current, Replace, a refused second link): the next link may wait.
    case companyDismiss(flow: String)

    private enum Keys: String, CodingKey {
        case cmd, flow, slug, vendors, vendor
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
        case let .companyConnect(flow, slug, vendors):
            try box.encode("company_connect", forKey: .cmd)
            try box.encode(flow, forKey: .flow)
            try box.encode(slug, forKey: .slug)
            try box.encode(vendors, forKey: .vendors)
        case let .companySkip(flow, vendor):
            try box.encode("company_skip", forKey: .cmd)
            try box.encode(flow, forKey: .flow)
            try box.encodeIfPresent(vendor, forKey: .vendor)
        case let .companyStop(flow):
            try box.encode("company_stop", forKey: .cmd)
            try box.encode(flow, forKey: .flow)
        case let .companyDismiss(flow):
            try box.encode("company_dismiss", forKey: .cmd)
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
