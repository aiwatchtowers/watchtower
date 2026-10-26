import Foundation
import GRDB
import os

/// When a linked phone was last in touch (keep-awake, ask #614): the latest
/// admitted action or `device` record, kept in `hub_meta`.
extension HubSyncState {
    static let lastPhoneContactKey = "last_phone_contact"

    /// nil before any contact, and when the value is unreadable (a failed read is logged).
    func lastPhoneContact() -> Date? {
        let raw: String?
        do {
            raw = try metaValue(forKey: Self.lastPhoneContactKey)
        } catch {
            keepAwakeLogger.error("last phone contact unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let raw, let seconds = TimeInterval(raw) else { return nil }
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
