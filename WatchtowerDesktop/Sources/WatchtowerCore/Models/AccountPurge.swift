import Foundation
import GRDB

/// One row of the daemon's purge ledger `account_purges` (migration 00147,
/// board #601), joined to its account: when an account's access is revoked,
/// or a source was not reached for the lease, and purge on revoked access is
/// on, the account's synced data is deleted after a notice. Read by
/// `AccountPurgeQueries`; the account columns are empty when the account row
/// is gone.
package struct AccountPurge: FetchableRecord, Identifiable, Equatable, Sendable {
    package let id: Int64
    /// "slack" | "google" | "jira" | "linear"
    package let source: String
    package let accountID: Int64
    /// The Go label rule (`listPurgeAccountsSQL`); "" when the row is gone.
    package let accountLabel: String
    /// The account's `status`; "" when the row is gone.
    package let accountStatus: String
    /// The account's last confirmed access; nil when unknown.
    package let accessOkAt: Date?
    /// "revoked" | "lease"
    package let reason: String
    /// "scheduled" | "running" | "done" | "cancelled"
    package let state: String
    package let dueAt: Date?
    package let finishedAt: Date?
    package let rowsDeleted: Int64
    package let error: String

    package init(row: Row) {
        id = row["id"]
        source = row["source"] ?? ""
        accountID = row["account_id"] ?? 0
        accountLabel = row["account_label"] ?? ""
        accountStatus = row["account_status"] ?? ""
        accessOkAt = PlanUsageDates.parse(row["account_access_ok_at"])
        reason = row["reason"] ?? ""
        state = row["state"] ?? ""
        dueAt = PlanUsageDates.parse(row["due_at"])
        finishedAt = PlanUsageDates.parse(row["finished_at"])
        rowsDeleted = row["rows_deleted"] ?? 0
        error = row["error"] ?? ""
    }

    package init(
        id: Int64,
        source: String,
        accountID: Int64,
        accountLabel: String = "",
        accountStatus: String = "revoked",
        accessOkAt: Date? = nil,
        reason: String = "revoked",
        state: String = "scheduled",
        dueAt: Date? = nil,
        finishedAt: Date? = nil,
        rowsDeleted: Int64 = 0,
        error: String = ""
    ) {
        self.id = id
        self.source = source
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.accountStatus = accountStatus
        self.accessOkAt = accessOkAt
        self.reason = reason
        self.state = state
        self.dueAt = dueAt
        self.finishedAt = finishedAt
        self.rowsDeleted = rowsDeleted
        self.error = error
    }

    package var isOpen: Bool { state == "scheduled" || state == "running" }
    package var isDone: Bool { state == "done" }
    /// A lease row of an account that was removed (or whose row is gone):
    /// reconnecting means adding it again.
    package var isRemovedAccount: Bool { accountStatus == "removed" || accountStatus.isEmpty }

    package var sourceName: String {
        switch source {
        case "slack": "Slack"
        case "google": "Google"
        case "jira": "Jira"
        case "linear": "Linear"
        default: source
        }
    }

    package var displayLabel: String {
        accountLabel.isEmpty ? "\(sourceName) account #\(accountID)" : accountLabel
    }
}

/// The purge switch as `watchtower accounts purges --json` reports it
/// (`accountPurgesJSON` in `cmd/accounts.go`). The effective value and its
/// origin come from Go only (`purge.Enabled`): the Desktop keeps no copy of
/// the rule. The ledger rows are read from the database instead.
package struct AccountPurgeStatus: Decodable, Equatable, Sendable {
    package let enabled: Bool
    /// "policy" | "setting" | "build" | "default"
    package let enabledBy: String
    package let graceHours: Int
    package let leaseDays: Int

    enum CodingKeys: String, CodingKey {
        case enabled
        case enabledBy = "enabled_by"
        case graceHours = "grace_hours"
        case leaseDays = "lease_days"
    }

    package init(enabled: Bool, enabledBy: String, graceHours: Int = 72, leaseDays: Int = 30) {
        self.enabled = enabled
        self.enabledBy = enabledBy
        self.graceHours = graceHours
        self.leaseDays = leaseDays
    }

    /// An organisation policy sets it; the owner cannot change it.
    package var isSetByPolicy: Bool { enabledBy == "policy" }

    package static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
