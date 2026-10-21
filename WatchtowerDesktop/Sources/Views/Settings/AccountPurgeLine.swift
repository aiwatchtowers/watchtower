import SwiftUI
import WatchtowerCore

/// The purge line under an account in Settings → Connections (board #601):
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
    /// purged line (with the done date when the row is recent). Pure over the
    /// center's rows, so every connection detail shows the same thing.
    static func make(
        center: AccountPurgeCenter?, source: String, accountID: Int64, isPurged: Bool
    ) -> Self? {
        if let open = center?.openRow(source: source, accountID: accountID) {
            return Self(text: AccountPurgeNoticePolicy.line(open))
        }
        guard isPurged else { return nil }
        let done = center?.doneRow(source: source, accountID: accountID)
        return Self(text: AccountPurgeNoticePolicy.purgedLine(done), deleted: true)
    }
}
