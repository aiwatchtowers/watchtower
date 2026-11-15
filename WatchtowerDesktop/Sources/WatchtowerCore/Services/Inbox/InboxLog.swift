import GRDB
import os

/// The Inbox's one log category, shared by its models, reads and panes.
package enum InboxLog {
    package static let logger = Logger(subsystem: "com.watchtower.desktop", category: "inbox")

    /// What a log line says of `error` (FILES-01: no names or text): its
    /// SQLite code for a database error, else its type.
    package static func errorClass(_ error: any Error) -> String {
        if let error = error as? DatabaseError { return "sqlite \(error.resultCode.rawValue)" }
        return String(describing: type(of: error))
    }
}
