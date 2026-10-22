import Foundation

/// Why a feed action could not run at all (Home's Done / Hide and the Inbox's message buttons).
package enum HomeFeedActionError: LocalizedError, Equatable {
    /// The `watchtower` binary was not found: inbox rows are written by the CLI.
    case cliUnavailable
    /// No database is open yet.
    case databaseUnavailable

    /// How long an inbox CLI call may run; past it the call throws and the
    /// row comes back with the error.
    package static let cliTimeout: TimeInterval = 30

    package var errorDescription: String? {
        switch self {
        case .cliUnavailable: "The command line is not available."
        case .databaseUnavailable: "The database is not open."
        }
    }
}
