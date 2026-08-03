/// Account-namespaced Slack ids (`"<accountID>:<rawID>"`), the form channel and
/// user ids take once a workspace has more than one Slack account connected.
///
/// Mirrors `internal/slack/namespace.go` — the two must stay behaviourally
/// identical, including the leading-colon and non-numeric-prefix cases, which
/// are NOT namespaces and pass through unchanged.
public enum SlackID {
    public static func namespaced(accountID: Int, rawID: String) -> String {
        rawID.isEmpty ? "" : "\(accountID):\(rawID)"
    }

    public static func split(_ id: String) -> (accountID: Int, rawID: String, isNamespaced: Bool) {
        guard let colon = id.firstIndex(of: ":"),
              colon != id.startIndex,
              let accountID = Int(id[..<colon]) else {
            return (0, id, false)
        }
        return (accountID, String(id[id.index(after: colon)...]), true)
    }

    public static func raw(_ id: String) -> String {
        split(id).rawID
    }
}
