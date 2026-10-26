import SwiftUI
import WatchtowerCore

/// The purge line under an account in the Connections tab (board #601):
/// red while a purge is scheduled or running, secondary once the data was
/// deleted. The text comes from `AccountPurgeNoticePolicy`.
struct AccountPurgeLine: View {
    let text: String
    var deleted = false

    var body: some View {
        Label(text, systemImage: deleted ? "trash" : "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(deleted ? AnyShapeStyle(.secondary) : AnyShapeStyle(Tone.error))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The line for one account, or nil: the open purge's line, else the
    /// purged line (with the done date when the row is recent), else a recent
    /// failed purge's line. Pure over the center's rows, so every connection
    /// detail shows the same thing.
    static func make(
        center: AccountPurgeCenter?, source: String, accountID: Int64, isPurged: Bool
    ) -> Self? {
        make(
            open: center?.openRow(source: source, accountID: accountID),
            recent: center?.recentRows.filter { $0.source == source && $0.accountID == accountID } ?? [],
            isPurged: isPurged)
    }

    /// `recent` is the account's finished rows, newest first.
    static func make(open: AccountPurge?, recent: [AccountPurge], isPurged: Bool) -> Self? {
        if let open { return Self(text: AccountPurgeNoticePolicy.line(open)) }
        if isPurged {
            return Self(text: AccountPurgeNoticePolicy.purgedLine(recent.first { $0.isDone }), deleted: true)
        }
        if let failed = recent.first, failed.isFailed {
            return Self(text: AccountPurgeNoticePolicy.failedLine(failed))
        }
        return nil
    }

    /// Why Re-login is off for an account, or nil: a running purge cannot be
    /// stopped, and a login in the middle of it would sign in to an account
    /// that is being emptied.
    static func reloginBlockedReason(_ open: AccountPurge?) -> String? {
        guard open?.state == "running" else { return nil }
        return "Watchtower is deleting this account's data. Re-login once it finishes."
    }

    /// `reloginBlockedReason` for one account of the center.
    static func reloginBlockedReason(center: AccountPurgeCenter?, source: String, accountID: Int64) -> String? {
        reloginBlockedReason(center?.openRow(source: source, accountID: accountID))
    }
}
