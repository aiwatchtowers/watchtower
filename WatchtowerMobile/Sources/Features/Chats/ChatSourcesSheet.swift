import SwiftUI
import WatchtowerKit

/// An answer's sources grouped as on the Mac (`ChatSourceGrouping`): by the hub's `group` (a Slack channel, a Jira
/// project, a Confluence space, "Mail", "Meetings"), else by kind, the biggest group first and "Other" last; each
/// title without its group prefix. Pure.
struct ChatSourceGroups: Equatable {
    struct Group: Equatable, Identifiable {
        let name: String
        let sources: [ChatFeed.Source]

        var id: String { name }
    }

    static let title = "Sources"
    static let other = "Other"
    static let mail = "Mail"
    static let meetings = "Meetings"
    private static let separators = [" — ", " · "]

    let groups: [Group]

    init(_ sources: [ChatFeed.Source]) {
        var order: [String] = []
        var buckets: [String: [ChatFeed.Source]] = [:]
        for source in sources {
            let name = Self.groupName(source)
            if buckets[name] == nil { order.append(name) }
            buckets[name, default: []].append(source)
        }
        let ranked = order.enumerated().sorted { lhs, rhs in
            let lhsOther = lhs.element == Self.other, rhsOther = rhs.element == Self.other
            if lhsOther != rhsOther { return rhsOther }
            let lhsCount = buckets[lhs.element]?.count ?? 0, rhsCount = buckets[rhs.element]?.count ?? 0
            return lhsCount != rhsCount ? lhsCount > rhsCount : lhs.offset < rhs.offset
        }
        groups = ranked.map { Group(name: $0.element, sources: buckets[$0.element] ?? []) }
    }

    static func groupName(_ source: ChatFeed.Source) -> String {
        if let group = source.group, !group.isEmpty { return group }
        switch source.kind {
        case "email": return mail
        case "meeting": return meetings
        default: return other
        }
    }

    static func displayTitle(_ source: ChatFeed.Source) -> String {
        let base = source.title.isEmpty ? source.ref : source.title
        let group = groupName(source)
        guard group != other, base.hasPrefix(group) else { return base }
        let rest = base.dropFirst(group.count)
        for separator in separators where rest.hasPrefix(separator) {
            let trimmed = rest.dropFirst(separator.count).trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? base : trimmed
        }
        return base
    }

    /// A source's link, only for the schemes the phone hands to an app or Safari.
    static func link(_ source: ChatFeed.Source) -> URL? {
        guard let raw = source.url, let url = URL(string: raw), ["https", "http", "slack"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return url
    }
}

/// The sources sheet (mockup 3c): the groups, each source's title and its snippet or date; a link opens in the
/// matching app or Safari.
struct ChatSourcesSheet: View {
    let sources: [ChatFeed.Source]
    @Environment(\.openURL) private var openURL

    var body: some View {
        let model = ChatSourceGroups(sources)
        NavigationStack {
            List {
                ForEach(model.groups) { group in
                    Section {
                        ForEach(Array(group.sources.enumerated()), id: \.offset) { _, source in row(source) }
                    } header: {
                        SectionHeader(group.name)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(ChatSourceGroups.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ source: ChatFeed.Source) -> some View {
        let link = ChatSourceGroups.link(source)
        return Button {
            if let link { openURL(link) }
        } label: {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(ChatSourceGroups.displayTitle(source)).font(TypeScale.rowTitle).foregroundStyle(link == nil ? .primary : Color.accentColor)
                if let detail = source.snippet.map({ "“\($0)”" }) ?? source.date {
                    Text(detail).font(TypeScale.meta).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: PhoneMetrics.minTouch, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(link == nil)
    }
}
