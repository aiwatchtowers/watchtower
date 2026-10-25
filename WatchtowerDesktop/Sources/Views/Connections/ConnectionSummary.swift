import Foundation
import WatchtowerCore

/// One account of a connected service, as the Connections tab reads it.
/// `enabled` is true on services without a per-account switch (Google,
/// Email, Calendar), so `ConnectionStatusLogic.enabledFilteredStatus` gives
/// those the same answer as its `status(okFlags:)`.
struct ConnectionAccountState: Equatable {
    let name: String
    let isOK: Bool
    let enabled: Bool
    /// Why it is not OK: the account's error, else its status.
    let problem: String

    init(name: String, isOK: Bool, enabled: Bool = true, status: String, error: String) {
        self.name = name
        self.isOK = isOK
        self.enabled = enabled
        problem = Self.problemText(status: status, error: error)
    }

    private static func problemText(status: String, error: String) -> String {
        if !error.isEmpty { return error }
        switch status {
        case "revoked": return "access revoked"
        case "purged": return "data deleted, sign in again to resync"
        default: return status
        }
    }
}

/// A service's card on the Connections overview and its row in the list:
/// status (`ConnectionStatusLogic`, the one rule), account count and the
/// accounts that need the owner.
struct ConnectionSummary: Identifiable, Equatable {
    let service: ConnectionService
    let status: ConnectionStatus
    let accountCount: Int
    /// Enabled accounts that are not OK, the ones the status counts as problems.
    let problems: [ConnectionAccountState]
    /// The organization's policy forbids the source (#608): it shows a lock
    /// and asks nothing of the owner, who cannot reconnect it.
    let blocked: Bool

    var id: ConnectionService { service }

    /// The banner and the sidebar badge's rule: a service whose status is
    /// an error, unless the policy blocks it.
    var needsAttention: Bool { status == .error && !blocked }

    /// `accounts` nil = its view model is not loaded yet: not configured.
    init(service: ConnectionService, accounts: [ConnectionAccountState]?, blocked: Bool) {
        self.service = service
        self.blocked = blocked
        let accounts = accounts ?? []
        accountCount = accounts.count
        status = ConnectionStatusLogic.enabledFilteredStatus(accounts.map { ($0.isOK, $0.enabled) })
        problems = accounts.filter { $0.enabled && !$0.isOK }
    }

    /// "2 workspaces", "1 site", "Not connected".
    var countLine: String {
        guard accountCount > 0 else { return "Not connected" }
        let noun = service.accountNoun
        return accountCount == 1 ? "1 \(noun)" : "\(accountCount) \(noun)s"
    }

    /// The card's one status line.
    var statusLine: String {
        if blocked { return SourceBlockedNotice.title }
        if let first = problems.first {
            let more = problems.count > 1 ? " (and \(problems.count - 1) more)" : ""
            return "\(first.name): \(first.problem)\(more)"
        }
        switch status {
        case .connected: return "Connected"
        case .error: return "Needs attention"
        case .notConfigured: return accountCount > 0 ? "Turned off" : service.pitch
        }
    }

    /// The services that need the owner: the sidebar badge's number.
    static func attentionCount(_ summaries: [Self]) -> Int {
        summaries.filter(\.needsAttention).count
    }
}

extension ConnectionService {
    /// The overview's two groups: sources Watchtower reads, tools the assistant uses.
    static var sources: [Self] { [.slack, .google, .email, .calendar, .jira, .linear] }
    static var aiTools: [Self] { [.quickConnections] }

    /// The service a "Connect …" button names (Choose Jira boards: Jira);
    /// nil, the overview, for one that names several or none.
    init?(readinessSource source: ReadinessSource) {
        switch source {
        case .slack: self = .slack
        case .calendar: self = .calendar
        case .jira, .jiraBoards: self = .jira
        case .linear: self = .linear
        case .none, .anySource, .jiraOrMail, .ownerIdentity, .ownerIdentityPending: return nil
        }
    }

    var accountNoun: String {
        switch self {
        case .slack, .linear: "workspace"
        case .jira: "site"
        case .quickConnections: "server"
        case .google, .email, .calendar: "account"
        }
    }

    /// What connecting it brings, on a card with nothing connected.
    var pitch: String {
        switch self {
        case .slack: "Messages for Inbox, Digests, People and Tracks."
        case .google: "Gmail and Google Calendar."
        case .email: "Any IMAP mailbox: mail lands in Inbox and Catch-Up."
        case .calendar: "A CalDAV calendar or an ICS feed."
        case .jira: "Issues, boards and Confluence spaces."
        case .linear: "Issues, cycles and projects next to your Jira work."
        case .quickConnections: "MCP servers the assistant can use."
        }
    }
}
