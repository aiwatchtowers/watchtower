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
        case "": return "needs attention"
        default: return status
        }
    }
}

/// Each service's accounts as the tab reads them. Slack, Jira, Linear and
/// Quick Connections carry their own Enabled switch; the others have none.
extension ConnectionAccountState {
    init(_ account: SlackAccount) {
        self.init(name: account.displayName, isOK: account.isOK, enabled: account.enabled,
                  status: account.status, error: account.error)
    }

    init(_ account: GoogleAccount) {
        self.init(name: account.displayName, isOK: account.isOK, status: account.status, error: account.error)
    }

    init(_ account: EmailAccount) {
        self.init(name: account.displayName, isOK: account.isOK, status: account.status, error: account.error)
    }

    init(_ account: CalendarAccount) {
        self.init(name: account.displayName, isOK: account.isOK, status: account.status, error: account.error)
    }

    init(_ account: JiraAccount) {
        self.init(name: account.displayName, isOK: account.isOK, enabled: account.enabled,
                  status: account.status, error: account.error)
    }

    init(_ account: LinearAccount) {
        self.init(name: account.displayName, isOK: account.isOK, enabled: account.enabled,
                  status: account.status, error: account.error)
    }

    init(_ connection: ExternalConnection) {
        self.init(name: connection.name, isOK: connection.isOK, enabled: connection.enabled,
                  status: connection.status, error: connection.error)
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
    /// The accounts could not be read (the view model is not loaded, or its
    /// read failed with nothing listed): neither "not connected" nor a
    /// problem the badge counts.
    let unknown: Bool

    var id: ConnectionService { service }

    /// The banner and the sidebar badge's rule: a service whose status is
    /// an error, unless the policy blocks it.
    var needsAttention: Bool { status == .error && !blocked }

    /// `accounts` nil = its view model is not loaded; `readError` is its
    /// last failed account read (never an action's failure), which with no
    /// account listed leaves the accounts unknown.
    init(service: ConnectionService, accounts: [ConnectionAccountState]?, readError: String? = nil, blocked: Bool) {
        self.service = service
        self.blocked = blocked
        unknown = accounts == nil || (accounts?.isEmpty == true && readError != nil)
        let accounts = accounts ?? []
        accountCount = accounts.count
        status = ConnectionStatusLogic.enabledFilteredStatus(accounts.map { ($0.isOK, $0.enabled) })
        problems = accounts.filter { $0.enabled && !$0.isOK }
    }

    /// "2 workspaces", "1 site", "Not connected".
    var countLine: String {
        if unknown { return "Status unknown" }
        guard accountCount > 0 else { return "Not connected" }
        let noun = service.accountNoun
        return accountCount == 1 ? "1 \(noun)" : "\(accountCount) \(noun)s"
    }

    /// The card's one status line.
    var statusLine: String {
        if blocked { return SourceBlockedNotice.title }
        if unknown { return "Couldn't read accounts" }
        if let problemLine { return problemLine }
        switch status {
        case .connected: return "Connected"
        case .error: return "Needs attention"
        case .notConfigured: return accountCount > 0 ? "Turned off" : service.pitch
        }
    }

    /// "acme: token expired (and 1 more)": the first problem account; the
    /// card's status line and, after the service name, the banner's.
    var problemLine: String? {
        guard let first = problems.first else { return nil }
        let more = problems.count > 1 ? " (and \(problems.count - 1) more)" : ""
        return "\(first.name): \(first.problem)\(more)"
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
