import Foundation
import os
import WatchtowerCore

/// The DB's datetime strings (`YYYY-MM-DDTHH:MM:SSZ`, optionally with
/// fractional seconds, always UTC) as wire dates for the hub projections.
enum SliceDate {
    /// nil for "" or an unparsable value.
    static func parse(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        return whole.date(from: value) ?? fractional.date(from: value)
    }

    /// For a required wire date: an unparsable stamp (never written by Go
    /// or the Desktop) becomes 1970 rather than a record the phone cannot
    /// decode, and is logged once per record and field, so a format drift
    /// shows in the log, not only as ancient dates on the phone.
    static func required(_ value: String, field: String, record: String) -> Date {
        if let date = parse(value) { return date }
        if warned.withLock({ $0.insert(record + "." + field).inserted }) {
            logger.warning(
                "unparsable \(field, privacy: .public) '\(value, privacy: .public)' on \(record, privacy: .public); published as 1970"
            )
        }
        return Date(timeIntervalSince1970: 0)
    }

    /// Whether `required` logged this record's field (the test seam).
    static func hasWarned(field: String, record: String) -> Bool {
        warned.withLock { $0.contains(record + "." + field) }
    }

    private static let logger = Logger(subsystem: Constants.bundleID, category: "SliceDate")
    private static let warned = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    private static let whole: ISO8601DateFormatter = formatter([.withInternetDateTime])
    private static let fractional: ISO8601DateFormatter = formatter([.withInternetDateTime, .withFractionalSeconds])

    private static func formatter(_ options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = options
        return formatter
    }
}
