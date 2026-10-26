import Foundation

package enum ChatHistorySectionKind: Int, CaseIterable, Sendable {
    case pinned, recent, older

    package var title: String {
        switch self {
        case .pinned: "Pinned"
        case .recent: "Recent"
        case .older: "Older"
        }
    }
}

/// What the history groups: a conversation, or a Chats panel row.
package protocol ChatHistoryListed: Equatable, Sendable {
    var conversation: ChatConversation { get }
}

extension ChatConversation: ChatHistoryListed {
    package var conversation: ChatConversation { self }
}

extension ChatPanelRow: ChatHistoryListed {}

package struct ChatHistorySection<Item: ChatHistoryListed>: Identifiable, Equatable, Sendable {
    package let kind: ChatHistorySectionKind
    package let items: [Item]
    package var id: ChatHistorySectionKind { kind }
}

/// The Chats panel's groups (spec 2026-10-26 §6): PINNED, RECENT (updated
/// within `recentDays` calendar days of today) and the folded older rest.
/// Pure: `now` and `calendar` are injected. Archived rows are skipped
/// defensively; empty sections omitted; newest first inside each.
package enum ChatHistoryGrouping {
    /// A chat updated this many calendar days ago (or fewer) is recent.
    package static let recentDays = 7

    package static func group<Item: ChatHistoryListed>(
        _ items: [Item], now: Date, calendar: Calendar
    ) -> [ChatHistorySection<Item>] {
        var buckets: [ChatHistorySectionKind: [Item]] = [:]
        for item in items where item.conversation.archivedAt == nil {
            buckets[kind(of: item.conversation, now: now, calendar: calendar), default: []].append(item)
        }
        return ChatHistorySectionKind.allCases.compactMap { kind in
            guard let list = buckets[kind], !list.isEmpty else { return nil }
            let sorted = list.sorted { $0.conversation.updatedAt > $1.conversation.updatedAt }
            return ChatHistorySection(kind: kind, items: sorted)
        }
    }

    package static func kind(of conv: ChatConversation, now: Date, calendar: Calendar) -> ChatHistorySectionKind {
        if conv.pinned { return .pinned }
        let from = calendar.startOfDay(for: conv.updatedDate)
        let to = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        return days <= recentDays ? .recent : .older
    }
}
