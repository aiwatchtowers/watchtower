import Foundation
import WatchtowerKit

/// A chat row's age (mockups 1a, 1i): "now", "14m", "3h", then the weekday within the week ("Mon"), the date
/// within the year ("Oct 2"), else the date with its year.
enum ChatAge {
    static func label(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds) / 60)m" }
        if seconds < 86_400 { return "\(Int(seconds) / 3_600)h" }
        var format = Date.FormatStyle(calendar: calendar).locale(Locale(identifier: "en_US_POSIX"))
        format.timeZone = calendar.timeZone
        if seconds < 6 * 86_400 { return date.formatted(format.weekday(.abbreviated)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(format.month(.abbreviated).day())
        }
        return date.formatted(format.month(.abbreviated).day().year())
    }
}

/// The Chats list as drawn (iPhone chat spec §6.2, mockup 1a): Pinned, then Recent (the last 7 days), then the
/// older chats folded under "▸ N older". Each row has its state dot in the Mac's precedence (waiting orange >
/// answering blue > unread filled > read ring), the title, a second line and the age. A query keeps only the
/// chats whose title has it, under "Titles", with nothing folded (mockup 1i).
struct ChatListModel: Equatable {
    static let recentWindow: TimeInterval = 7 * 86_400

    static let pinnedTitle = "Pinned"
    static let recentTitle = "Recent"
    static let titlesTitle = "Titles"
    static let messagesTitle = "In messages"
    static let searchPrompt = "Search chats"
    static let navigationTitle = "Chats"
    static let newChatLabel = "New chat"

    static let waitingLine = "Waiting for your approval"
    static let answeringLine = "Answering…"
    static let unreadLine = "New answer"

    struct Row: Identifiable, Equatable {
        let id: Int64
        let title: String
        let tone: PhoneTone
        let isRing: Bool
        /// The project's name, drawn with a folder before it; nil outside a project.
        let project: String?
        /// The state, or the last answer's first line ("" when there is none).
        let detail: String
        let age: String
        let isWaiting: Bool
        let conversation: ChatList.Conversation

        var toneUse: ToneUse {
            ToneUse(element: "chat \(id) dot", tone: tone, role: isWaiting ? .waiting : .status)
        }

        /// What VoiceOver reads for the row.
        var spokenLabel: String {
            [title, project.map { "project \($0)" }, detail, age].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    struct Section: Identifiable, Equatable {
        let title: String
        let rows: [Row]

        var id: String { title }
    }

    let sections: [Section]
    /// The chats older than the window, shown only once unfolded.
    let older: [Row]

    /// "23 older"; nil without older chats.
    var olderLabel: String? { older.isEmpty ? nil : "\(older.count) older" }

    var rowCount: Int { sections.reduce(0) { $0 + $1.rows.count } + older.count }

    init(list: ChatList, now: Date, calendar: Calendar = .current, query: String = "", hidden: Set<Int64> = []) {
        let shown = list.conversations.filter { !hidden.contains($0.id) }
        let rows = shown.map { Self.row($0, now: now, calendar: calendar) }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.isEmpty else {
            let matches = rows.filter { $0.title.localizedStandardContains(needle) }
            sections = matches.isEmpty ? [] : [Section(title: Self.titlesTitle, rows: matches)]
            older = []
            return
        }
        let cutoff = now.addingTimeInterval(-Self.recentWindow)
        let pinned = rows.filter(\.conversation.pinned)
        let recent = rows.filter { !$0.conversation.pinned && $0.conversation.updatedAt >= cutoff }
        older = rows.filter { !$0.conversation.pinned && $0.conversation.updatedAt < cutoff }
        sections = [Section(title: Self.pinnedTitle, rows: pinned), Section(title: Self.recentTitle, rows: recent)]
            .filter { !$0.rows.isEmpty }
    }

    static func row(_ conversation: ChatList.Conversation, now: Date, calendar: Calendar) -> Row {
        let state = conversation.state
        let (tone, isRing): (PhoneTone, Bool) = switch state {
        case .waiting: (.waitingForYou, false)
        case .answering: (.blue, false)
        case .unread: (.primary, false)
        default: (.secondary, true)
        }
        let detail: String = switch state {
        case .waiting: waitingLine
        case .answering: answeringLine
        case .unread: unreadLine
        default: conversation.lastLine
        }
        // A waiting or answering line is the state alone, as on the Mac; otherwise the project leads.
        let showsProject = state != .waiting && state != .answering
        return Row(
            id: conversation.id,
            title: conversation.title,
            tone: tone,
            isRing: isRing,
            project: showsProject ? conversation.project?.name : nil,
            detail: detail,
            age: ChatAge.label(conversation.updatedAt, now: now, calendar: calendar),
            isWaiting: state == .waiting,
            conversation: conversation
        )
    }

    /// Every tone the list draws (`OrangeToneTests`).
    var toneUses: [ToneUse] {
        (sections.flatMap(\.rows) + older).map(\.toneUse)
    }
}
