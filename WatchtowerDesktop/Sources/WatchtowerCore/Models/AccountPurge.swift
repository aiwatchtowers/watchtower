import Foundation
import GRDB

/// One row of the daemon's purge ledger `account_purges` (migration 00148,
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
    /// "scheduled" | "running" | "done" | "cancelled" | "failed"
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
    /// Three chunk failures in a row ended it; the account was not purged.
    package var isFailed: Bool { state == "failed" }
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

    /// Go's last fallback (`purge.Enabled`, origin `default`): off in every
    /// build (owner decision 2026-11-23). The shared fixture
    /// `internal/purge/testdata/default_cases.json` pins both sides.
    package static let buildDefault = false

    /// The Privacy switch's title (spec §8).
    package static let switchTitle = "Delete an account's data when its access ends"
    /// The Slack Remove dialog's destructive button.
    package static let removeButton = "Remove"

    /// The value the Privacy switch shows: an organisation's forced value,
    /// else the owner's (unsaved or saved) setting, else what the CLI
    /// reported, else the build default — so a switch opened before the CLI
    /// answered (or after it failed) shows off, as the daemon acts.
    package static func shownValue(
        policy: Bool?, setting: Bool?, status: Self? // swiftlint:disable:this discouraged_optional_boolean
    ) -> Bool {
        policy ?? setting ?? status?.enabled ?? buildDefault
    }

    /// The origin of the value `shownValue` picks, from the same inputs: a
    /// forced value is `policy`, the owner's saved or pending setting is
    /// `setting`, else the CLI's origin, else `default` (it has not answered).
    package static func shownOrigin(
        policy: Bool?, setting: Bool?, status: Self? // swiftlint:disable:this discouraged_optional_boolean
    ) -> String {
        if policy != nil || status?.isSetByPolicy == true { return "policy" }
        if setting != nil { return "setting" }
        return status?.enabledBy ?? "default"
    }

    /// The notice before a deletion, in hours: an organization's
    /// PurgeGraceHours, else Go's `grace_hours` (72 unless the organization
    /// sets another; 0 deletes after the next sync), else 72 while the CLI has
    /// not answered.
    private static func notice(_ status: Self?, policyGrace: Int? = nil) -> Int {
        policyGrace ?? status?.graceHours ?? 72
    }

    /// The notice in hours as the app states it outside the Privacy footnote
    /// (the Remove dialogs, a dead token's lease note).
    package static func graceHours(_ status: Self?, policy: ManagedPolicy) -> Int {
        notice(status, policyGrace: policy.purgeGraceHours)
    }

    /// The Privacy switch's footnote for the shown value. The switch is on
    /// only by a setting, a policy or the build, so on gives every rule.
    package static func footnote(_ status: Self?, shown: Bool) -> String {
        guard shown else {
            return "Off: synced data stays on this Mac after access ends, until you delete it with "
                + "Reset All Data… in Settings → System. Slack expects a workspace's data to be gone within "
                + "14 business days after its app is removed."
        }
        let grace = notice(status)
        let lease = status?.leaseDays ?? 30
        let later = grace == 0 ? "after the next sync" : "\(grace) hours later"
        let afterRemove = grace == 0 ? "after the first sync after the remove" : "\(grace) hours after the remove"
        return "On: when an account's access is revoked, or Watchtower has not reached its source for "
            + "\(lease) days, its synced data is deleted \(later) unless you reconnect. A removed Slack "
            + "workspace's data goes \(afterRemove), another removed account's \(lease) days after it was last "
            + "reached. Briefings, recaps, ideas, memory, chats and meeting transcripts are kept."
    }

    /// "Off by default" while the switch is off by its default origin; nil
    /// otherwise, and nil while the CLI has not answered and nothing else
    /// decides (a build may turn the purge on, which Swift cannot see).
    /// `origin` (from `shownOrigin`) when given, else the CLI's.
    package static func caption(_ status: Self?, shown: Bool, origin: String? = nil) -> String? {
        guard status != nil else { return nil }
        let isDefault = (origin ?? status?.enabledBy ?? "default") == "default"
        return !shown && isDefault ? "Off by default" : nil
    }

    /// The switch as a Remove dialog states it: `shownValue` of the forced
    /// value, the owner's saved setting and the CLI's status; nil when none of
    /// them is known (the CLI has not answered or failed, so the build's own
    /// default decides, which Swift cannot see).
    private static func dialogEnabled(
        _ status: Self?, policy: ManagedPolicy, setting: Bool? // swiftlint:disable:this discouraged_optional_boolean
    ) -> Bool? { // swiftlint:disable:this discouraged_optional_boolean
        if status == nil, policy.purgeRevokedData == nil, setting == nil { return nil }
        return shownValue(policy: policy.purgeRevokedData, setting: setting, status: status)
    }

    /// The Slack Remove dialog's message (#1769, A2/A3): the remove signs out
    /// at Slack, and with the purge on the workspace's data goes after the
    /// notice. The switch is the organization's forced value, else the
    /// owner's saved `setting`, else the CLI's status; with none of them
    /// known, the message says what happens either way.
    package static func removeDialogMessage(
        slackAccount label: String,
        status: Self?,
        policy: ManagedPolicy,
        setting: Bool? // swiftlint:disable:this discouraged_optional_boolean
    ) -> String {
        let signOut = "Watchtower stops syncing \(label) and signs out of it at Slack, so this sign-in stops "
            + "working on every Mac that uses it."
        let grace = notice(status, policyGrace: policy.purgeGraceHours)
        let when = grace == 0 ? "after the next sync" : "in \(grace) hours"
        guard let enabled = dialogEnabled(status, policy: policy, setting: setting) else {
            return signOut + " If deleting data when access ends is on, its synced data is deleted \(when) unless "
                + "you add the workspace again; otherwise it stays on this Mac until you delete it. Check "
                + "Settings → System → Privacy."
        }
        guard enabled else {
            return signOut + " Its synced data stays on this Mac until you delete it, because "
                + "deleting data when access ends is off."
        }
        return signOut + " Its synced data stays for now and is deleted \(when) unless "
            + "you add the workspace again. Briefings, recaps, ideas, memory, chats and meeting transcripts are kept."
    }

    /// A Jira or Linear Remove dialog's message: `kept` says the
    /// synced data stays; with the purge on, one sentence adds the removed
    /// account's own lease (scheduled once the account was not reached for
    /// the lease, deleted after the notice). The switch is resolved as in the
    /// Slack variant; with none of its inputs known, the sentence is
    /// conditional.
    package static func removeDialogMessage(
        _ kept: String,
        status: Self?,
        policy: ManagedPolicy,
        setting: Bool? // swiftlint:disable:this discouraged_optional_boolean
    ) -> String {
        let grace = notice(status, policyGrace: policy.purgeGraceHours)
        let lease = status?.leaseDays ?? 30
        let notice = grace == 0 ? "" : ", plus \(grace) hours' notice"
        guard let enabled = dialogEnabled(status, policy: policy, setting: setting) else {
            return kept + " If deleting data on revoked access is on, it is deleted about \(lease) days after the "
                + "account was last reached\(notice); check Settings → System → Privacy."
        }
        guard enabled else { return kept }
        return kept + " Because deleting data on revoked access is on, it is deleted about "
            + "\(lease) days after the account was last reached\(notice)."
    }

    package static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
