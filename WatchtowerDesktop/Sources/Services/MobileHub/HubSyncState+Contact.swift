import Foundation
import GRDB

/// When a linked phone was last in touch (keep-awake, ask #614): the latest
/// admitted action or `device` record, kept in `hub_meta`.
extension HubSyncState {
    static let lastPhoneContactKey = "last_phone_contact"

    /// nil before any contact, and when the value is unreadable.
    func lastPhoneContact() -> Date? {
        guard let raw = try? metaValue(forKey: Self.lastPhoneContactKey), let seconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Raises the stored contact time to `date`; an older one changes nothing
    /// (a replayed old record is not contact now). One write transaction.
    func notePhoneContact(at date: Date) throws {
        try queue.write { db in
            let stored = try Self.metaValue(Self.lastPhoneContactKey, db).flatMap(TimeInterval.init)
            guard stored.map({ date.timeIntervalSince1970 > $0 }) ?? true else { return }
            try Self.setMetaValue(String(date.timeIntervalSince1970), Self.lastPhoneContactKey, db)
        }
    }
}
