import Foundation

/// The collapsed header's session popover (board #251, variant H), kept out
/// of the views so it is testable. A running session also shows what its
/// workbench hooks reported (`SessionAgentStatus`, board #312).
package enum SessionSwitcherPresentation {
    /// A session's state (spec 2026-10-03-workbench-session-report §4b),
    /// decided by `SessionAgentStatus.effective`; `SessionStatePresentation`
    /// maps it to the dot's colour, glyph, fill and caption.
    package struct State: Equatable, Sendable {
        package enum Kind: Equatable, Sendable {
            case notStarted
            /// Live, with no state reported during this run.
            case running
            case working
            case needsApproval
            /// The turn ended on a StopFailure.
            case failed
            /// An open ask of the session waits for the owner, live or not.
            case waitingOnAsk
            /// The turn is over and nothing waits for the owner.
            case stopped
            /// The agent called `finish_session`, live or not.
            case finished
        }

        package let kind: Kind
        /// The process runs: the dot is filled, else a ring.
        package let live: Bool
        /// The session's open asks.
        package let openAsks: Int
        /// `agent_error` of a failed turn ('' when unknown); '' for any
        /// other kind.
        package let error: String
        /// The oldest open ask, the one a waiting caption names ("ask #12");
        /// nil without open asks.
        package let oldestAskID: Int64?

        package init(kind: Kind, live: Bool, openAsks: Int = 0, error: String = "", oldestAskID: Int64? = nil) {
            self.kind = kind
            self.live = live
            self.openAsks = openAsks
            self.error = error
            self.oldestAskID = oldestAskID
        }

        /// Not running, no asks, not finished.
        package static let notStarted = Self(kind: .notStarted, live: false)

        /// A live session's state.
        package static func live(_ kind: Kind, openAsks: Int = 0, error: String = "", oldestAskID: Int64? = nil) -> Self {
            Self(kind: kind, live: true, openAsks: openAsks, error: error, oldestAskID: oldestAskID)
        }
    }

    package struct Row: Identifiable, Equatable, Sendable {
        package let session: TerminalSession
        package let state: State
        /// A workbench session's state caption (§4b) — what its state label
        /// shows and every site reads out: "Stopped", "Waiting for you · ask
        /// #12"; not started adds the age ("Not running · 5m"). A standalone
        /// terminal keeps its plain caption: nil while running, "not started
        /// · 5m" otherwise.
        package let caption: String?
        /// `#233` for a session working on a target.
        package let badge: String?
        /// ⌘1…⌘9 for the first nine rows of the panel order.
        package let shortcut: Int?

        package var id: Int64 { session.id }

        /// Whether the row draws the state label (glyph and caption): a
        /// workbench session; a standalone terminal shows its plain caption.
        package var showsStateLabel: Bool { session.projectID != nil }
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
                caption: caption(state, session: session, now: now),
                badge: session.targetID.map { "#\($0)" },
                shortcut: index < maxShortcut ? index + 1 : nil
            )
        }
    }

    /// A session's state. Liveness decides first: a status read while the
    /// session was live is ignored once it no longer is, and a live session
    /// without a status is plain running.
    package static func state(
        of sessionID: Int64,
        liveIDs: Set<Int64>,
        statuses: [Int64: SessionAgentStatus]
    ) -> State {
        let live = liveIDs.contains(sessionID)
        if let state = statuses[sessionID]?.state, state.live == live { return state }
        return live ? .live(.running) : .notStarted
    }

    /// A workbench session's §4b caption, with the age when not started; a
    /// standalone terminal's plain caption (nil while running).
    private static func caption(_ state: State, session: TerminalSession, now: Date) -> String? {
        guard session.projectID != nil else {
            return state.live ? nil : notStartedCaption(session, now: now)
        }
        let caption = SessionStatePresentation.caption(for: state)
        guard state.kind == .notStarted,
              let age = TimeFormatting.shortAge(from: session.lastActiveAt, now: now) else { return caption }
        return "\(caption) · \(age)"
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
