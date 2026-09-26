import Foundation

/// The `OwnerQueries.resolve` rung that produced `Owner.id` (Go: `db.OwnerSource`).
package enum OwnerSource: String, Sendable {
    case none = ""
    case slack
    case google
    case jira
}

/// The one person this install belongs to — the Swift mirror of Go's
/// `db.Owner` (internal/db/owner.go). `id` is the stable key owner-scoped rows
/// (`user_profile`, day plans, …) are stored under; its shape depends on the
/// rung that produced it: the namespaced Slack user id (`"1:U123"`),
/// `"google:<lower-cased email>"`, or `"jira:<atlassian account id>"`. The
/// other fields are enriched from every connected source.
package struct Owner: Equatable, Sendable {
    package let id: String
    package let source: OwnerSource
    package let slackUserID: String
    package let email: String
    package let jiraAccountID: String
    package let displayName: String

    package init(
        id: String,
        source: OwnerSource,
        slackUserID: String,
        email: String,
        jiraAccountID: String,
        displayName: String
    ) {
        self.id = id
        self.source = source
        self.slackUserID = slackUserID
        self.email = email
        self.jiraAccountID = jiraAccountID
        self.displayName = displayName
    }

    /// Whether any rung produced an owner identity.
    package var isKnown: Bool { !id.isEmpty }

    /// No connected account yields an owner identity.
    package static let unknown = Self(
        id: "", source: .none, slackUserID: "", email: "", jiraAccountID: "", displayName: ""
    )
}

/// Owner-scoped writes refuse an unknown owner (Go: `db.ErrNoOwner`, same text).
package enum OwnerError: LocalizedError, Equatable {
    case noOwner

    package var errorDescription: String? {
        switch self {
        case .noOwner: "no owner identity: connect Slack, Google or Jira first"
        }
    }
}
