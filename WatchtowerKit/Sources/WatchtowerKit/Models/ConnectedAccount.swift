import Foundation
import GRDB

// MARK: - ConnectedAccount

/// One connected external account from the desktop's `slack_accounts` /
/// `google_accounts` / `jira_accounts` tables — the mobile mirror of the
/// desktop Connections tab's rows, published as the `slack_account` /
/// `google_account` / `jira_account` slice kinds.
///
/// READ-ONLY BY OWNER DECISION (2026-08-17): OAuth flows cannot run on the
/// phone, so the phone only shows what is connected and its health. There are
/// no account relay actions.
///
/// One model decodes all three kinds: the identity columns are disjoint
/// (`team_name` for Slack, `email` for Google, `site_name`/`site_url` for
/// Jira) and everything else — `label`, `status`, `error`, enablement — is
/// shared. Columns absent from a kind's payload read their defaults, exactly
/// like the desktop models tolerate missing columns.
///
/// The slice is a PROJECTION: tokens, sync watermarks, and the OAuth client
/// id never reach the wire (frozen by SlicePublisher's projection tests).
public struct ConnectedAccount: FetchableRecord, Identifiable, Equatable {
    public let id: Int
    /// Slack workspace name; empty for other services.  column: team_name
    public let teamName: String
    /// Slack workspace domain ("acme" → acme.slack.com); empty for other
    /// services.                                          column: team_domain
    public let teamDomain: String
    /// Google account email; empty for other services.    column: email
    public let email: String
    /// Jira site name; empty for other services.          column: site_name
    public let siteName: String
    /// Jira site URL; empty for other services.           column: site_url
    public let siteURL: String
    /// User-facing label set on the desktop; empty = none.
    public let label: String
    /// `ok | error | revoked` (removed rows never reach the slice window).
    public let status: String
    /// Human-readable failure detail for a non-ok status; may be empty.
    public let error: String
    /// Slack/Jira per-account toggle. Google payloads carry no `enabled`
    /// column (that service has no per-account toggle), so the default
    /// `true` applies — mirroring the desktop, where every Google row
    /// participates.
    public let enabled: Bool
    /// Google service grants; always false for Slack/Jira payloads.
    public let calendarEnabled: Bool    // column: calendar_enabled
    public let gmailEnabled: Bool       // column: gmail_enabled

    public init(row: Row) {
        id = row["id"]
        teamName = row["team_name"] ?? ""
        teamDomain = row["team_domain"] ?? ""
        email = row["email"] ?? ""
        siteName = row["site_name"] ?? ""
        siteURL = row["site_url"] ?? ""
        label = row["label"] ?? ""
        status = row["status"] ?? "ok"
        error = row["error"] ?? ""
        enabled = row["enabled"] ?? true
        calendarEnabled = row["calendar_enabled"] ?? false
        gmailEnabled = row["gmail_enabled"] ?? false
    }

    // MARK: - Status predicates (desktop model parity)

    public var isOK: Bool { status == "ok" }
    public var isRevoked: Bool { status == "revoked" }

    // MARK: - Presentation

    /// Display text for a row, mirroring the desktop models' rule: the
    /// user-facing label if set, else the service identity, else a positional
    /// fallback for a not-yet-consented row (identity is only populated once
    /// the OAuth flow completes on the desktop).
    public var displayName: String {
        if !label.isEmpty { return label }
        for identity in [teamName, email, siteName, siteURL] where !identity.isEmpty {
            return identity
        }
        return "Account #\(id)"
    }

    /// Secondary identity line — shown under `displayName` only when it adds
    /// information the primary line does not already carry (the desktop's
    /// detail rows show the same: workspace domain / email / site URL).
    public var detail: String? {
        let candidate: String
        if !teamDomain.isEmpty {
            candidate = "\(teamDomain).slack.com"
        } else if !siteURL.isEmpty {
            candidate = siteURL
        } else {
            candidate = email
        }
        guard !candidate.isEmpty, candidate != displayName else { return nil }
        return candidate
    }
}
