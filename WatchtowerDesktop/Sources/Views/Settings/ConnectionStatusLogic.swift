import SwiftUI

enum ConnectionStatus: Equatable {
    case connected, error, notConfigured

    var color: Color {
        switch self {
        case .connected: .green
        case .error: .red
        case .notConfigured: .gray
        }
    }
}

enum ConnectionStatusLogic {
    /// problemCount = accounts whose status is not OK (error/revoked/removed-pending).
    static func derive(okCount: Int, problemCount: Int) -> ConnectionStatus {
        if problemCount > 0 { return .error }
        return okCount > 0 ? .connected : .notConfigured
    }

    /// Every account counts toward ok/problem (Google/Email/Calendar rows —
    /// these services have no per-account enable/disable toggle).
    static func status(okFlags: [Bool]) -> ConnectionStatus {
        derive(okCount: okFlags.filter { $0 }.count, problemCount: okFlags.filter { !$0 }.count)
    }

    /// A disabled account counts toward NEITHER ok nor problem (Slack/Jira
    /// rows — a soft-disabled account shouldn't paint the service red or
    /// green off a status it isn't actively syncing).
    static func enabledFilteredStatus(_ accounts: [(isOK: Bool, enabled: Bool)]) -> ConnectionStatus {
        status(okFlags: accounts.filter(\.enabled).map(\.isOK))
    }
}

enum ConnectionService: String, CaseIterable, Identifiable {
    case slack, google, email, calendar, jira
    var id: String { rawValue }

    var label: String {
        switch self {
        case .slack: "Slack"
        case .google: "Google"
        case .email: "Email"
        case .calendar: "Calendar"
        case .jira: "Jira"
        }
    }

    var icon: String {
        switch self {
        case .slack: "number"
        case .google: "g.circle"
        case .email: "envelope"
        case .calendar: "calendar"
        case .jira: "checklist"
        }
    }
}
