import Foundation

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
    /// decode.
    static func parseOrEpoch(_ value: String) -> Date {
        parse(value) ?? Date(timeIntervalSince1970: 0)
    }

    private static let whole: ISO8601DateFormatter = formatter([.withInternetDateTime])
    private static let fractional: ISO8601DateFormatter = formatter([.withInternetDateTime, .withFractionalSeconds])

    private static func formatter(_ options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = options
        return formatter
    }
}
