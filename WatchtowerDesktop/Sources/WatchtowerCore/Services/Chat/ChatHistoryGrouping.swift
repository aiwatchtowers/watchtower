import ChatWire
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

package struct ChatHistorySection: Identifiable, Equatable, Sendable {
    package let kind: ChatHistorySectionKind
    package let items: [ChatList.Conversation]
    package var id: ChatHistorySectionKind { kind }
}

/// The Chats panel's groups (spec 2026-10-26 §6) over the engine's list: PINNED, RECENT (updated within
/// `recentDays` calendar days of today) and the folded older rest. Pure: `now` and `calendar` are injected. Empty
/// sections are omitted; newest first inside each.
package enum ChatHistoryGrouping {
    /// A chat updated this many calendar days ago (or fewer) is recent.
    package static let recentDays = 7

    package static func group(
        _ items: [ChatList.Conversation], now: Date, calendar: Calendar
    ) -> [ChatHistorySection] {
        var buckets: [ChatHistorySectionKind: [ChatList.Conversation]] = [:]
        for item in items {
            buckets[kind(of: item, now: now, calendar: calendar), default: []].append(item)
        }
        return ChatHistorySectionKind.allCases.compactMap { kind in
            guard let list = buckets[kind], !list.isEmpty else { return nil }
            return ChatHistorySection(kind: kind, items: list.sorted { $0.updatedAt > $1.updatedAt })
        }
    }

    package static func kind(of conv: ChatList.Conversation, now: Date, calendar: Calendar) -> ChatHistorySectionKind {
        if conv.pinned { return .pinned }
        let from = calendar.startOfDay(for: conv.updatedAt)
        let to = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        return days <= recentDays ? .recent : .older
    }
}
