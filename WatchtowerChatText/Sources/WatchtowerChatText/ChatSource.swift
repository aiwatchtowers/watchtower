import Foundation

/// One cited source (spec §3.4) — the `tool_end.sources[]` wire item (Go
/// `internal/chat/events.go` `Source`). `group`/`snippet`/`date` are optional
/// presentation hints Go fills per tool; rows persisted before they existed
/// decode with all three nil (`ChatSourceGrouping` derives a legacy group).
public struct ChatSource: Codable, Hashable, Sendable {
    public let kind: String
    public let title: String
    public let url: String?
    public let ref: String
    public let group: String?
    public let snippet: String?
    /// A `YYYY-MM-DD` day.
    public let date: String?

    public init(
        kind: String,
        title: String,
        url: String?,
        ref: String,
        group: String? = nil,
        snippet: String? = nil,
        date: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.url = url
        self.ref = ref
        self.group = group
        self.snippet = snippet
        self.date = date
    }

    /// Two sources with the same key are one item: the same Slack thread (a
    /// permalink's `thread_ts`), otherwise the same URL, otherwise the same ref.
    public var dedupeKey: String {
        guard let url, !url.isEmpty else { return "\(kind):\(ref)" }
        return ChatSourceGrouping.threadKey(url) ?? url
    }

    /// Order-preserving dedupe; a later duplicate only fills the optional
    /// fields the first one lacks.
    public static func dedupe(_ sources: [Self]) -> [Self] {
        var order: [String] = []
        var byKey: [String: Self] = [:]
        for source in sources {
            let key = source.dedupeKey
            if let kept = byKey[key] {
                byKey[key] = kept.filling(from: source)
            } else {
                order.append(key)
                byKey[key] = source
            }
        }
        return order.compactMap { byKey[$0] }
    }

    private func filling(from other: Self) -> Self {
        Self(kind: kind, title: title.isEmpty ? other.title : title, url: url, ref: ref,
             group: group ?? other.group, snippet: snippet ?? other.snippet, date: date ?? other.date)
    }

    /// Display-only column: an undecodable value renders as "no chips",
    /// which is the honest rendering of a column we cannot read.
    public static func decodeList(_ json: String) -> [Self] {
        (try? JSONDecoder().decode([Self].self, from: Data(json.utf8))) ?? []
    }

    public static func encodeList(_ sources: [Self]) -> String {
        guard let data = try? JSONEncoder().encode(sources), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}
