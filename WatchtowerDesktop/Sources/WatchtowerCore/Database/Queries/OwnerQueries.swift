import GRDB

/// Swift twin of internal/db/owner.go (ResolveOwner) — a deliberate dual path; change both together. Ladder: Slack #1 → Google #1 → Jira #1.
///
/// Every owner-identity read in the Desktop goes through `resolve` (OWNER-01,
/// pinned by `OwnerQueriesTests.testOwner01NoRawOwnerQueriesOutsideResolver`).
/// Each rung's SQL, the enrichment order and the display-name rule are copied
/// from the Go helpers of the same name.
package enum OwnerQueries {
    /// The Jira rung's row: the connecting person's own Atlassian identity on
    /// the first enabled, non-removed account that recorded one.
    private struct OwnerJira {
        var accountID = ""
        var email = ""
        var displayName = ""
    }

    /// The Slack user row enrichment reads.
    private struct OwnerSlackUser {
        let displayName: String
        let realName: String
        let email: String
    }

    /// The one owner identity of this install: Slack account #1 → Google
    /// account #1 → Jira account #1. Every field is enriched from every
    /// source, independent of which rung produced `id`. No connected identity
    /// → `Owner.unknown`, never an error.
    package static func resolve(_ db: Database) throws -> Owner {
        let slackID = try ownerSlackID(db)
        let google = try ownerGoogleEmail(db)
        let jira = try ownerJiraAccount(db)

        let id: String
        let source: OwnerSource
        if !slackID.isEmpty {
            (id, source) = (slackID, .slack)
        } else if !google.isEmpty {
            (id, source) = ("google:" + google.lowercased(), .google)
        } else if !jira.accountID.isEmpty {
            (id, source) = ("jira:" + jira.accountID, .jira)
        } else {
            return .unknown
        }
        return try enrich(db, id: id, source: source, slackID: slackID, googleEmail: google, jira: jira)
    }

    // MARK: - Rungs

    /// Account #1's namespaced current_user_id, unless that account was
    /// removed. "" when there is no such account.
    private static func ownerSlackID(_ db: Database) throws -> String {
        try String.fetchOne(db, sql: """
            SELECT current_user_id FROM slack_accounts WHERE id = 1 AND status != 'removed'
            """) ?? ""
    }

    /// The first connected Google account's email, as stored (lower-cased
    /// for the id only).
    private static func ownerGoogleEmail(_ db: Database) throws -> String {
        try String.fetchOne(db, sql: """
            SELECT email FROM google_accounts WHERE email != '' ORDER BY id LIMIT 1
            """) ?? ""
    }

    /// The first enabled, non-removed Jira account that recorded its
    /// connecting person's identity (migration 00071).
    private static func ownerJiraAccount(_ db: Database) throws -> OwnerJira {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT owner_account_id, owner_email, owner_display_name FROM jira_accounts
            WHERE enabled = 1 AND status != 'removed' AND owner_account_id != '' ORDER BY id LIMIT 1
            """) else { return OwnerJira() }
        return OwnerJira(
            accountID: row["owner_account_id"],
            email: row["owner_email"],
            displayName: row["owner_display_name"]
        )
    }

    // MARK: - Enrichment

    private static func enrich(
        _ db: Database,
        id: String,
        source: OwnerSource,
        slackID: String,
        googleEmail: String,
        jira: OwnerJira
    ) throws -> Owner {
        let slackUser = slackID.isEmpty ? nil : try fetchSlackUser(db, id: slackID)
        let email = ownerEmail(slackUser, googleEmail: googleEmail, jira: jira)
        let jiraID = jira.accountID.isEmpty ? try ownerJiraFromUserMap(db, slackUserID: slackID) : jira.accountID
        return Owner(
            id: id, source: source, slackUserID: slackID, email: email,
            jiraAccountID: jiraID,
            displayName: ownerDisplayName(slackUser, jira: jira, email: email)
        )
    }

    private static func fetchSlackUser(_ db: Database, id: String) throws -> OwnerSlackUser? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT display_name, real_name, email FROM users WHERE id = ?
            """, arguments: [id]) else { return nil }
        return OwnerSlackUser(
            displayName: row["display_name"], realName: row["real_name"], email: row["email"]
        )
    }

    /// The Slack user's email, else the Google email, else the Jira owner email.
    private static func ownerEmail(_ slackUser: OwnerSlackUser?, googleEmail: String, jira: OwnerJira) -> String {
        if let email = slackUser?.email, !email.isEmpty { return email }
        if !googleEmail.isEmpty { return googleEmail }
        return jira.email
    }

    /// The Slack user's display name (else real name), else the Jira owner
    /// display name, else the email's local part with its case kept.
    private static func ownerDisplayName(_ slackUser: OwnerSlackUser?, jira: OwnerJira, email: String) -> String {
        if let user = slackUser {
            if !user.displayName.isEmpty { return user.displayName }
            if !user.realName.isEmpty { return user.realName }
        }
        if !jira.displayName.isEmpty { return jira.displayName }
        guard let at = email.firstIndex(of: "@") else { return email }
        return String(email[..<at])
    }

    /// The first Atlassian account id jira_user_map maps to slackUserID,
    /// matching both the namespaced and the bare form (older rows may carry
    /// the bare id). "" when unmapped.
    private static func ownerJiraFromUserMap(_ db: Database, slackUserID: String) throws -> String {
        guard !slackUserID.isEmpty else { return "" }
        let alt = slackUserID.hasPrefix("1:") ? String(slackUserID.dropFirst(2)) : "1:" + slackUserID
        return try String.fetchOne(db, sql: """
            SELECT jira_account_id FROM jira_user_map WHERE slack_user_id IN (?, ?)
            ORDER BY slack_user_id = ? DESC, jira_account_id LIMIT 1
            """, arguments: [slackUserID, alt, slackUserID]) ?? ""
    }
}
