import Foundation

/// The collapsed header's session popover (board #251, variant H), kept out
/// of the views so it is testable. A session is running or not started —
/// v1 has no "waiting for an answer" state.
package enum SessionSwitcherPresentation {
    package enum State: Equatable, Sendable {
        case running
        case notStarted
    }

    package struct Row: Identifiable, Equatable, Sendable {
        package let session: TerminalSession
        package let state: State
        /// "не запущена · 5 мин"; nil for a running session.
        package let caption: String?
        /// `#233` for a session working on a target.
        package let badge: String?
        /// ⌘1…⌘9 for the first nine rows of the panel order.
        package let shortcut: Int?

        package var id: Int64 { session.id }
    }

    /// The highest ⌘N the switchers bind.
    package static let maxShortcut = 9

    /// `sessions` already in the panel's order (`orderedSessions`).
    package static func rows(_ sessions: [TerminalSession], liveIDs: Set<Int64>, now: Date) -> [Row] {
        sessions.enumerated().map { index, session in
            let live = liveIDs.contains(session.id)
            let caption = TimeFormatting.shortAge(from: session.lastActiveAt, now: now).map { "не запущена · \($0)" }
                ?? "не запущена"
            return Row(
                session: session,
                state: live ? .running : .notStarted,
                caption: live ? nil : caption,
                badge: session.targetID.map { "#\($0)" },
                shortcut: index < maxShortcut ? index + 1 : nil
            )
        }
    }

    /// Case- and diacritic-insensitive substring match on the title, or the
    /// target id exactly (`#233` or `233`); the order and the shortcuts are kept.
    package static func matching(_ rows: [Row], query: String) -> [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        let id = needle.hasPrefix("#") ? String(needle.dropFirst()) : needle
        return rows.filter { row in
            if let target = row.session.targetID, String(target) == id { return true }
            return row.session.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
