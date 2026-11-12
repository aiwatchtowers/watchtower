import os

/// The Inbox's one log category, shared by its models, reads and panes.
package enum InboxLog {
    package static let logger = Logger(subsystem: "com.watchtower.desktop", category: "inbox")
}
