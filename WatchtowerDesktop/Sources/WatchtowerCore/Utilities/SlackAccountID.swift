/// Namespaced Slack id helpers, mirroring `internal/slack/namespace.go`'s
/// `Namespace`/`SplitAccountID` (migration 00048: `users.id` etc. hold
/// `"<accountID>:<rawSlackID>"`). Pre-migration data (e.g. `user_profiles`
/// reports/peers lists) deliberately keeps frozen bare ids, so display code
/// needs tolerant matching between the two forms.
package enum SlackAccountID {
    /// Splits a namespaced id into its numeric account id and raw Slack id.
    /// Returns nil when `id` has no digit-only prefix before the first colon
    /// (a bare pre-migration id, or a string that merely contains a colon).
    package static func split(_ id: String) -> (accountID: Int, rawID: String)? {
        guard let colonIndex = id.firstIndex(of: ":") else { return nil }
        let prefix = id[id.startIndex..<colonIndex]
        guard !prefix.isEmpty, let accountID = Int(prefix) else { return nil }
        return (accountID, String(id[id.index(after: colonIndex)...]))
    }

    /// The raw Slack id portion of a possibly-namespaced id: strips a valid
    /// `"<accountID>:"` prefix, or returns `id` unchanged when it isn't namespaced.
    package static func raw(_ id: String) -> String {
        split(id)?.rawID ?? id
    }

    /// Tolerant equality between two Slack ids that may or may not be
    /// namespaced — e.g. a profile's frozen bare id ("U01CAHRV7M3") against a
    /// synced namespaced id ("1:U01CAHRV7M3").
    package static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || raw(lhs) == raw(rhs)
    }
}
