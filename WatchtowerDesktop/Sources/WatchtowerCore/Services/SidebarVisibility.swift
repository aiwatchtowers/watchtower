import GRDB

/// A kind of data a sidebar tab needs before it has anything to show.
package enum SidebarSource: Sendable {
    /// Slack or mail (Gmail, IMAP/Outlook) — what Inbox, Catch-Up and
    /// Statistics are built from.
    case messages
    /// A Google account with Calendar, or a CalDAV/ICS calendar.
    case calendar
    case jira
}

/// Which sources are connected, read from the account tables.
package struct ConnectedSources: Equatable, Sendable {
    package var slack: Bool
    package var mail: Bool
    package var calendar: Bool
    package var jira: Bool

    package init(slack: Bool = false, mail: Bool = false, calendar: Bool = false, jira: Bool = false) {
        self.slack = slack
        self.mail = mail
        self.calendar = calendar
        self.jira = jira
    }

    package static let none = Self()
    /// Fail-open default until the first read: every tab visible.
    package static let all = Self(slack: true, mail: true, calendar: true, jira: true)

    package func provides(_ source: SidebarSource) -> Bool {
        switch source {
        case .messages: slack || mail
        case .calendar: calendar
        case .jira: jira
        }
    }

    /// Reads the account tables. Removed Slack/Jira accounts don't count;
    /// Google, IMAP and calendar accounts are deleted on removal. A paused
    /// account (`enabled = 0`, not removed) counts as connected on purpose:
    /// its synced data is still there to show — unlike
    /// `SlackAccountQueries.hasConnectedAccount`, which counts only enabled
    /// accounts.
    package static func fetch(_ db: Database) throws -> Self {
        func any(_ sql: String) throws -> Bool {
            try Bool.fetchOne(db, sql: "SELECT EXISTS(\(sql))") ?? false
        }
        return Self(
            slack: try any("SELECT 1 FROM slack_accounts WHERE status != 'removed'"),
            mail: try any("SELECT 1 FROM google_accounts WHERE gmail_enabled = 1")
                || any("SELECT 1 FROM email_accounts"),
            calendar: try any("SELECT 1 FROM google_accounts WHERE calendar_enabled = 1")
                || any("SELECT 1 FROM calendar_accounts"),
            jira: try any("SELECT 1 FROM jira_accounts WHERE status != 'removed'")
        )
    }
}

/// The sidebar's visibility rule, pure: a tab shows when its feature rule
/// AND its source rule both hold.
package enum SidebarVisibility {
    /// `requiredFeatures`: visible iff ANY is enabled (nil = no feature
    /// gate). `requiredSources`: visible iff ANY is connected (nil = no
    /// source gate).
    package static func isVisible(
        requiredFeatures: [String]?,
        requiredSources: [SidebarSource]?,
        disabledFeatures: Set<String>,
        connected: ConnectedSources
    ) -> Bool {
        let featuresHold = requiredFeatures.map { $0.contains { !disabledFeatures.contains($0) } } ?? true
        let sourcesHold = requiredSources.map { $0.contains { connected.provides($0) } } ?? true
        return featuresHold && sourcesHold
    }
}
