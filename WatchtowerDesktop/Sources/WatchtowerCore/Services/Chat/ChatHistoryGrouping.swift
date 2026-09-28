import Foundation

package enum ChatHistorySectionKind: Int, CaseIterable, Sendable {
    case pinned, today, yesterday, previous7Days, previous30Days, older

    package var title: String {
        switch self {
        case .pinned: "Pinned"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .previous7Days: "Previous 7 Days"
        case .previous30Days: "Previous 30 Days"
        case .older: "Older"
        }
    }
}

package struct ChatHistorySection: Identifiable, Equatable, Sendable {
    package let kind: ChatHistorySectionKind
    package let conversations: [ChatConversation]
    package var id: ChatHistorySectionKind { kind }
}

/// The left history's grouping (spec §3.1). Pure: `now` and `calendar` are
/// injected. Archived rows are skipped defensively; empty sections omitted.
package enum ChatHistoryGrouping {
    package static func group(_ conversations: [ChatConversation], now: Date, calendar: Calendar) -> [ChatHistorySection] {
        var buckets: [ChatHistorySectionKind: [ChatConversation]] = [:]
        for conv in conversations where conv.archivedAt == nil {
            buckets[kind(of: conv, now: now, calendar: calendar), default: []].append(conv)
        }
        return ChatHistorySectionKind.allCases.compactMap { kind in
            guard let items = buckets[kind], !items.isEmpty else { return nil }
            return ChatHistorySection(kind: kind, conversations: items.sorted { $0.updatedAt > $1.updatedAt })
        }
    }

    package static func kind(of conv: ChatConversation, now: Date, calendar: Calendar) -> ChatHistorySectionKind {
        if conv.pinned { return .pinned }
        let from = calendar.startOfDay(for: conv.updatedDate)
        let to = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        switch days {
        case ..<1: return .today
        case 1: return .yesterday
        case 2...7: return .previous7Days
        case 8...30: return .previous30Days
        default: return .older
        }
    }
}
