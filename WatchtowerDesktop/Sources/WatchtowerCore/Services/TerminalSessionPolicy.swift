import Foundation

/// Pure selection rules over `TerminalSession` rows.
package enum TerminalSessionPolicy {
    package static let maxTitleAttempts = 5

    /// Send-comments destination: the most recently focused live claude
    /// session (`lastFocused` is ordered oldest → newest), else the most
    /// recently active live claude session.
    package static func activeSession(
        _ sessions: [TerminalSession], live: Set<Int64>, lastFocused: [Int64]
    ) -> TerminalSession? {
        let candidates = sessions.filter { $0.kind == .claude && live.contains($0.id) }
        for id in lastFocused.reversed() {
            if let hit = candidates.first(where: { $0.id == id }) { return hit }
        }
        return candidates.max(by: isLessRecent)
    }

    /// "Work on it": the most recently active session for the target (running
    /// or not), or nil — the caller creates one.
    package static func sessionForTarget(_ targetID: Int64, in sessions: [TerminalSession]) -> TerminalSession? {
        sessions.filter { $0.targetID == targetID }.max(by: isLessRecent)
    }

    /// Sessions that still need an AI title attempt. Target-bound sessions are
    /// named after the target, and the setup session keeps its name: both start
    /// with a Watchtower prompt that the transcript records as a user message,
    /// so titling them would name them after that prompt, not the owner.
    package static func needsTitle(_ s: TerminalSession, attempts: Int) -> Bool {
        s.kind == .claude && s.titleSource == .auto && s.targetID == nil
            && !TerminalSessionNaming.isSetupTitle(s.title) && attempts < maxTitleAttempts
    }

    /// `lastActiveAt` is fixed-format ISO, so a string compare orders it; ties go to the higher id.
    private static func isLessRecent(_ a: TerminalSession, _ b: TerminalSession) -> Bool {
        (a.lastActiveAt, a.id) < (b.lastActiveAt, b.id)
    }
}
