import Foundation

/// The collapsed header's session popover (board #251, variant H), kept out
/// of the views so it is testable. A running session also shows what its
/// workbench hooks reported (`SessionAgentStatus`, board #312).
package enum SessionSwitcherPresentation {
    package enum State: Equatable, Sendable {
        case notStarted
        /// Live, with no state reported during this run.
        case running
        case working
        case waitingForOwner
        case needsApproval

        package var isLive: Bool { self != .notStarted }

        /// The caption a live state carries; nil for plain running and for
        /// not started (whose caption carries the age).
        package var agentCaption: String? {
            switch self {
            case .working: "working"
            case .waitingForOwner: "waiting for you"
            case .needsApproval: "needs approval"
            case .running, .notStarted: nil
            }
        }
    }

    package struct Row: Identifiable, Equatable, Sendable {
        package let session: TerminalSession
        package let state: State
        /// "not started · 5m", "waiting for you", …; nil for plain running.
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
    /// Liveness decides first: a status of a session that is no longer live
    /// is ignored.
    package static func rows(
        _ sessions: [TerminalSession],
        liveIDs: Set<Int64>,
        statuses: [Int64: SessionAgentStatus],
        now: Date
    ) -> [Row] {
        sessions.enumerated().map { index, session in
            let state = state(of: session.id, liveIDs: liveIDs, statuses: statuses)
            return Row(
                session: session,
                state: state,
                caption: state.isLive ? state.agentCaption : notStartedCaption(session, now: now),
                badge: session.targetID.map { "#\($0)" },
                shortcut: index < maxShortcut ? index + 1 : nil
            )
        }
    }

    /// A session's state: not started unless live, then its reported status.
    package static func state(
        of sessionID: Int64,
        liveIDs: Set<Int64>,
        statuses: [Int64: SessionAgentStatus]
    ) -> State {
        guard liveIDs.contains(sessionID) else { return .notStarted }
        return statuses[sessionID]?.state ?? .running
    }

    private static func notStartedCaption(_ session: TerminalSession, now: Date) -> String {
        TimeFormatting.shortAge(from: session.lastActiveAt, now: now).map { "not started · \($0)" } ?? "not started"
    }

    /// Case- and diacritic-insensitive substring match on the title, or the
    /// target id: a bare number exactly (`233`), a `#` and digits as a prefix
    /// (`#2`, `#23`, `#233` → #233); the order and the shortcuts are kept.
    package static func matching(_ rows: [Row], query: String) -> [Row] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        let hashDigits = needle.hasPrefix("#") ? String(needle.dropFirst()) : nil
        return rows.filter { row in
            if let target = row.session.targetID.map(String.init) {
                if let digits = hashDigits {
                    if !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                       target.hasPrefix(digits) { return true }
                } else if target == needle {
                    return true
                }
            }
            return row.session.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
