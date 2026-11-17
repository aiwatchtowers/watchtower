import ChatWire
import Foundation

/// The Chats project switcher's order, search and row state text (spec
/// 2026-10-26 §4), kept out of the views so it is testable. Mirrors
/// `WorkbenchSwitcherPresentation`.
package enum ChatProjectSwitcherPresentation {
    /// One project's row inputs, counted from the engine's list (`summaries`).
    package struct Summary: Equatable, Identifiable, Sendable {
        package let id: Int64
        package let name: String
        /// Latest chat `updated_at` in the project, else the project's own.
        package let lastActivity: Date
        package let unreadCount: Int
        package let waitingCount: Int
        package var answeringCount: Int

        package init(
            id: Int64,
            name: String,
            lastActivity: Date,
            unreadCount: Int = 0,
            waitingCount: Int = 0,
            answeringCount: Int = 0
        ) {
            self.id = id
            self.name = name
            self.lastActivity = lastActivity
            self.unreadCount = unreadCount
            self.waitingCount = waitingCount
            self.answeringCount = answeringCount
        }
    }

    /// Latest activity first; ties by name, then id.
    package static func ordered(_ rows: [Summary]) -> [Summary] {
        rows.sorted { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    /// One row per listed project from the engine's list: its chats' latest
    /// update (none: `.distantPast`, shown without an age), and how many of
    /// them have a new answer, wait for an approval or answer now. A chat in
    /// `hidden` (waiting in the Undo window) counts for nothing. Latest
    /// activity first.
    package static func summaries(_ list: ChatList?, hiding hidden: Set<Int64> = []) -> [Summary] {
        guard let list else { return [] }
        let chats = list.conversations.filter { !hidden.contains($0.id) }
        return ordered(list.projects.map { project in
            let mine = chats.filter { $0.project?.id == project.id }
            return Summary(
                id: project.id,
                name: project.name,
                lastActivity: mine.map(\.updatedAt).max() ?? .distantPast,
                unreadCount: mine.filter { $0.state == .unread }.count,
                waitingCount: mine.filter { $0.state == .waiting }.count,
                answeringCount: mine.filter { $0.state == .answering }.count
            )
        })
    }

    /// Case- and diacritic-insensitive substring match on the project name
    /// only; the order is kept.
    package static func matching(_ rows: [Summary], query: String) -> [Summary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter {
            $0.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// The row's state, each only when non-zero: new answers (badge),
    /// approvals waiting (warning), chats answering now; with none of
    /// those, the age of the last activity.
    package static func segments(summary: Summary, now: Date) -> [SwitcherSegment] {
        var out: [SwitcherSegment] = []
        if summary.unreadCount > 0 {
            let n = summary.unreadCount
            out.append(SwitcherSegment(text: "\(n) new \(n == 1 ? "answer" : "answers")", tone: .badge))
        }
        if summary.waitingCount > 0 {
            out.append(SwitcherSegment(text: "\(summary.waitingCount) waiting for approval", tone: .warning))
        }
        if summary.answeringCount > 0 {
            out.append(SwitcherSegment(text: "\(summary.answeringCount) answering", tone: .secondary))
        }
        if out.isEmpty, summary.lastActivity != .distantPast {
            out.append(SwitcherSegment(text: TimeFormatting.shortAge(from: summary.lastActivity, now: now), tone: .secondary))
        }
        return out
    }
}
