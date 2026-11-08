import Foundation

/// Pure selection rules over `TerminalSession` rows.
package enum TerminalSessionPolicy {
    package static let maxTitleAttempts = 5

    /// A workbench's active session: the most recently focused live agent
    /// session (`claude` or `codex`; `lastFocused` is ordered oldest → newest),
    /// else the most recently active live agent session.
    package static func activeSession(
        _ sessions: [TerminalSession], live: Set<Int64>, lastFocused: [Int64]
    ) -> TerminalSession? {
        let candidates = sessions.filter { $0.kind.isAgent && live.contains($0.id) }
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
        s.kind.isAgent && s.titleSource == .auto && s.targetID == nil
            && !TerminalSessionNaming.isSetupTitle(s.title) && attempts < maxTitleAttempts
    }

    /// The button over a session that is not running: "Resume" when it has
    /// an agent session to resume (an agent whose id the app chooses always
    /// has one, `AgentSessionCaps.appSessionID`; one that mints its own only
    /// once its first SessionStart stored it), else "Start"; nil for a kind
    /// this build does not know, which offers no button (A7b).
    package static func reopenLabel(_ s: TerminalSession) -> String? {
        if s.kind.isUnsupported { return nil }
        guard let agent = s.kind.agent else { return "Start" }
        return agent.session.caps.appSessionID || s.claudeSessionID != nil ? "Resume" : "Start"
    }

    /// `lastActiveAt` is fixed-format ISO, so a string compare orders it; ties go to the higher id.
    private static func isLessRecent(_ a: TerminalSession, _ b: TerminalSession) -> Bool {
        (a.lastActiveAt, a.id) < (b.lastActiveAt, b.id)
    }
}
