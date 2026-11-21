import Foundation

/// The session feed's timestamps (`watchtower workbench session-feed --json`):
/// RFC 3339 with or without fractional seconds; Go's zero time and anything
/// unparsable mean "no time". The formatters are made once: a formatter per
/// date cost most of a large feed's decode (#2065).
public enum SessionFeedDate {
    public static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty, !s.hasPrefix("0001-01-01") else { return nil }
        return fractionalDate.date(from: s) ?? plainDate.date(from: s)
    }

    private static let plainDate = ISO8601DateFormatter()
    private static let fractionalDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
