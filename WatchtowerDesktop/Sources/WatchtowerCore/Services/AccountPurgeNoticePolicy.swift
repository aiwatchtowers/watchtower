import Foundation

/// One macOS notification about an account purge.
package struct AccountPurgeNotice: Equatable, Sendable {
    package let identifier: String
    package let title: String
    package let body: String
}

/// The owner-facing text of the purge ledger (board #601): the red line on an
/// account and on Home, the done line, and which notifications are due — one
/// per row when it is scheduled and one when it is done. Pure; the caller
/// persists `sent` and delivers the notices.
package enum AccountPurgeNoticePolicy {
    /// `[String]` of `"<id>:scheduled"` / `"<id>:done"`.
    package static let sentKey = "accountPurges.noticesSent"

    /// The line for an open row: what happens, when, and how to stop it.
    package static func line(_ p: AccountPurge, zone: TimeZone = .current) -> String {
        let label = p.displayLabel
        if p.state == "running" { return "Watchtower is deleting \(label)'s data." }
        let due = p.dueAt.map { date($0, zone: zone) } ?? "soon"
        if p.reason == "lease" {
            if p.isRemovedAccount {
                let since = p.accessOkAt.map { " and has not been reached since \(date($0, zone: zone))" } ?? ""
                return "\(label) was removed\(since). Its data will be deleted on \(due) unless you add it again."
            }
            let since = p.accessOkAt.map { "since \(date($0, zone: zone))" } ?? "in a long time"
            return "Watchtower has not reached \(label) \(since). Its data will be deleted on \(due) unless you reconnect."
        }
        return "Access to \(label) was revoked. Its data will be deleted on \(due) unless you reconnect."
    }

    /// "<account>'s data was deleted on <date>."
    package static func doneLine(_ p: AccountPurge, zone: TimeZone = .current) -> String {
        let when = p.finishedAt.map { " on \(date($0, zone: zone))" } ?? ""
        return "\(p.displayLabel)'s data was deleted\(when)."
    }

    /// The line of a `purged` account in Settings → Connections: the done line
    /// when its row is at hand, and the way back, which is Re-login (adding the
    /// same workspace again says it is already connected).
    package static func purgedLine(_ done: AccountPurge?, zone: TimeZone = .current) -> String {
        let deleted = done.map { doneLine($0, zone: zone) } ?? "This account's synced data was deleted."
        return deleted + " Re-login to sync it again."
    }

    /// The notices due for `rows` (open and recently done ones) and the new
    /// `sent` set. Keys of rows no longer listed are dropped: a cancelled or
    /// old row never comes back, a new schedule is a new row.
    package static func notices(
        rows: [AccountPurge], sent: Set<String>, zone: TimeZone = .current
    ) -> (notices: [AccountPurgeNotice], sent: Set<String>) {
        let ids = Set(rows.map { String($0.id) })
        var kept = sent.filter { ids.contains(String($0.split(separator: ":").first ?? "")) }
        var notices: [AccountPurgeNotice] = []
        for row in rows {
            let key: String
            let notice: AccountPurgeNotice
            switch row.state {
            case "scheduled":
                key = "\(row.id):scheduled"
                notice = AccountPurgeNotice(
                    identifier: "accountPurge.\(key)", title: "\(row.sourceName) account data will be deleted",
                    body: line(row, zone: zone))
            case "done":
                key = "\(row.id):done"
                notice = AccountPurgeNotice(
                    identifier: "accountPurge.\(key)", title: "\(row.sourceName) account data deleted",
                    body: doneLine(row, zone: zone))
            default:
                continue
            }
            guard !kept.contains(key) else { continue }
            notices.append(notice)
            kept.insert(key)
        }
        return (notices: notices, sent: kept)
    }

    /// "October 24 at 14:00" in `zone`. UI text is English only.
    package static func date(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "MMMM d 'at' HH:mm"
        return formatter.string(from: date)
    }
}
