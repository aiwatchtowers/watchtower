import Foundation

/// One bucket of the sources panel: a Slack channel, a Jira project, a
/// Confluence space, "Mail", "Meetings", or "Other".
package struct ChatSourceGroup: Identifiable, Equatable, Sendable {
    package let name: String
    /// The kind most of its items share — drives the header icon.
    package let kind: String
    package let sources: [ChatSource]

    package var id: String { name }
}

/// What the one-line row under a finished answer shows.
package struct ChatSourcesSummary: Equatable, Sendable {
    package let count: Int
    /// Up to `ChatSourceGrouping.maxIcons` distinct kinds, most frequent first.
    package let kinds: [String]
    /// "#payments ×6, #general, PAY" — the most frequent named groups.
    package let topGroups: String

    package var countLabel: String { ChatSourceGrouping.countLabel(count) }
}

/// Pure grouping/dedupe/formatting behind the collapsed sources row and the
/// sources panel. Go (`internal/chat/sources.go`) fills `group`/`snippet`/
/// `date` for new rows; for a row persisted before those fields existed the
/// group is derived here from the kind, the ref, or a leading "#channel" in
/// the title. The "Mail"/"Meetings" names match Go's `mailGroup`/`meetingGroup`.
package enum ChatSourceGrouping {
    package static let otherGroup = "Other"
    package static let mailGroup = "Mail"
    package static let meetingGroup = "Meetings"
    package static let maxIcons = 4
    package static let maxTopGroups = 3

    private static let titleSeparators = [" — ", " · "]

    package static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 source" : "\(count) sources"
    }

    /// The bucket a source belongs to; never empty.
    package static func groupName(_ source: ChatSource) -> String {
        if let group = source.group, !group.isEmpty { return group }
        switch source.kind {
        case "slack": return legacySlackGroup(source.title) ?? otherGroup
        case "jira": return jiraProject(source.ref.split(separator: ":").last.map(String.init) ?? "") ?? otherGroup
        case "email": return mailGroup
        case "meeting": return meetingGroup
        default: return otherGroup
        }
    }

    /// The title without its group prefix ("#payments — refund is live" under
    /// "#payments" reads "refund is live"); the ref when there is no title.
    package static func displayTitle(_ source: ChatSource) -> String {
        let base = source.title.isEmpty ? source.ref : source.title
        let group = groupName(source)
        guard group != otherGroup, base.hasPrefix(group) else { return base }
        let rest = base.dropFirst(group.count)
        for separator in titleSeparators where rest.hasPrefix(separator) {
            let trimmed = rest.dropFirst(separator.count).trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? base : trimmed
        }
        return base
    }

    /// Deduplicated sources grouped by `groupName`, the biggest group first
    /// (ties keep first appearance), "Other" always last.
    package static func groups(_ sources: [ChatSource]) -> [ChatSourceGroup] {
        var order: [String] = []
        var buckets: [String: [ChatSource]] = [:]
        for source in ChatSource.dedupe(sources) {
            let name = groupName(source)
            if buckets[name] == nil { order.append(name) }
            buckets[name, default: []].append(source)
        }
        let ranked = order.enumerated().sorted { lhs, rhs in
            let lhsOther = lhs.element == otherGroup, rhsOther = rhs.element == otherGroup
            if lhsOther != rhsOther { return rhsOther }
            let lhsCount = buckets[lhs.element]?.count ?? 0, rhsCount = buckets[rhs.element]?.count ?? 0
            return lhsCount != rhsCount ? lhsCount > rhsCount : lhs.offset < rhs.offset
        }
        return ranked.map { _, name in
            let items = buckets[name] ?? []
            return ChatSourceGroup(name: name, kind: mostFrequent(items.map(\.kind)).first ?? "", sources: items)
        }
    }

    package static func summary(_ sources: [ChatSource]) -> ChatSourcesSummary {
        let unique = ChatSource.dedupe(sources)
        let named = groups(unique).filter { $0.name != otherGroup }.prefix(maxTopGroups)
        let top = named.map { $0.sources.count > 1 ? "\($0.name) ×\($0.sources.count)" : $0.name }
        return ChatSourcesSummary(count: unique.count,
                                  kinds: Array(mostFrequent(unique.map(\.kind)).prefix(maxIcons)),
                                  topGroups: top.joined(separator: ", "))
    }

    /// "May 13, 2026" for a `YYYY-MM-DD` day (rendered in UTC, so the day
    /// never shifts with the viewer's zone); nil for anything else.
    package static func displayDate(_ day: String?) -> String? {
        guard let day, day.count == 10,
              let date = try? Date(day, strategy: Date.ISO8601FormatStyle().year().month().day())
        else { return nil }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = TimeZone(identifier: "UTC") ?? .current
        return date.formatted(style)
    }

    /// One key per Slack thread: a reply permalink (`…/archives/C1/p200?thread_ts=100.1`)
    /// and its root's (`…/archives/C1/p1001`) collapse together. nil for a
    /// non-Slack-archive URL.
    package static func threadKey(_ url: String) -> String? {
        guard let parts = URLComponents(string: url), let host = parts.host,
              let range = parts.path.range(of: "/archives/") else { return nil }
        let pathTail = parts.path[range.upperBound...].split(separator: "/")
        guard let channel = pathTail.first else { return nil }
        let threadTS = parts.queryItems?.first { $0.name == "thread_ts" }?.value
        let root: String
        if let threadTS, !threadTS.isEmpty {
            root = threadTS.replacingOccurrences(of: ".", with: "")
        } else if pathTail.count > 1, pathTail[1].hasPrefix("p") {
            root = String(pathTail[1].dropFirst())
        } else {
            return nil
        }
        return "slack-thread:\(host)/\(channel)/\(root)"
    }

    // MARK: - Helpers

    private static func legacySlackGroup(_ title: String) -> String? {
        for separator in titleSeparators {
            if let range = title.range(of: separator) { return String(title[..<range.lowerBound]) }
        }
        guard title.hasPrefix("#") else { return nil }
        return title.split(separator: " ").first.map(String.init)
    }

    private static func jiraProject(_ key: String) -> String? {
        let parts = key.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return String(parts[0])
    }

    /// Distinct values, most frequent first; ties keep first appearance.
    private static func mostFrequent(_ values: [String]) -> [String] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for value in values {
            if counts[value] == nil { order.append(value) }
            counts[value, default: 0] += 1
        }
        return order.enumerated()
            .sorted { (counts[$0.element] ?? 0, -$0.offset) > (counts[$1.element] ?? 0, -$1.offset) }
            .map(\.element)
    }
}
