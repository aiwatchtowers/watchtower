import ChatWire
import Foundation

/// The chat list as sectioned (iPhone chat spec §6.2, mockup 1a; pure): Pinned, then Recent (the last 7 days), then
/// the older chats folded under "N older". A query keeps only the chats whose title has it, under "Titles", with
/// nothing folded (mockup 1i) — the title search that works with no engine to ask (the messages' search goes to it).
public struct ChatListSections: Equatable {
    public static let recentWindow: TimeInterval = 7 * 86_400
    public static let pinnedTitle = "Pinned"
    public static let recentTitle = "Recent"
    public static let titlesTitle = "Titles"
    public static let messagesTitle = "In messages"

    public struct Section: Identifiable, Equatable {
        public let title: String
        public let conversations: [ChatList.Conversation]

        public var id: String { title }
    }

    public let sections: [Section]
    /// The chats older than the window, shown only once unfolded.
    public let older: [ChatList.Conversation]

    /// "23 older"; nil without older chats.
    public var olderLabel: String? { older.isEmpty ? nil : "\(older.count) older" }

    public var count: Int { sections.reduce(0) { $0 + $1.conversations.count } + older.count }

    public init(_ conversations: [ChatList.Conversation], now: Date, query: String = "") {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.isEmpty else {
            let matches = conversations.filter { $0.title.localizedStandardContains(needle) }
            sections = matches.isEmpty ? [] : [Section(title: Self.titlesTitle, conversations: matches)]
            older = []
            return
        }
        let cutoff = now.addingTimeInterval(-Self.recentWindow)
        let pinned = conversations.filter(\.pinned)
        let recent = conversations.filter { !$0.pinned && $0.updatedAt >= cutoff }
        older = conversations.filter { !$0.pinned && $0.updatedAt < cutoff }
        sections = [Section(title: Self.pinnedTitle, conversations: pinned), Section(title: Self.recentTitle, conversations: recent)]
            .filter { !$0.conversations.isEmpty }
    }
}
