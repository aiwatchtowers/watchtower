import Foundation

/// One agent a launch menu offers (board #399, D1): its title, and whether
/// its CLI is there. A missing one stays listed, disabled, with a hint.
package struct AgentChoice: Identifiable, Equatable, Sendable {
    package let agent: AgentKind
    package let title: String
    package let isAvailable: Bool
    /// Why the entry is disabled; nil when it is available.
    package let hint: String?

    package var id: AgentKind { agent }
}

/// The per-launch agent choice of the Workbench tab: the New session menus
/// (header, pane, sessions panel, ⌘T switcher, the hand-off sheet) list every
/// agent; Work on It runs the default agent and its menu offers the others.
/// Standalone terminals are not covered: Codex needs a workbench.
package enum AgentChoicePresentation {
    /// "New Claude Code session", "New Codex session", in a fixed order.
    package static func newSessionAgentChoices(available: (AgentKind) -> Bool) -> [AgentChoice] {
        AgentKind.allCases.map { choice($0, title: "New \($0.displayName) session", available: available($0)) }
    }

    /// Work on It's menu: "Work on It with …" for every agent but the
    /// default, which the button itself runs.
    package static func workOnOthers(defaultAgent: AgentKind, available: (AgentKind) -> Bool) -> [AgentChoice] {
        AgentKind.allCases.filter { $0 != defaultAgent }.map {
            choice($0, title: "Work on It with \($0.displayName)", available: available($0))
        }
    }

    /// Work on It's help: the agent of the session it opens, else the one it
    /// starts.
    package static func workOnHelp(existing: AgentKind?, defaultAgent: AgentKind) -> String {
        if let existing { return "Open the \(existing.displayName) session for this target" }
        return "Start a \(defaultAgent.displayName) session for this target"
    }

    /// Why an agent's entry is disabled.
    package static func notInstalledHint(_ agent: AgentKind) -> String {
        switch agent {
        case .claude: "Claude Code was not found. Install it, or set claude_path in Watchtower's config."
        case .codex: "Codex was not found. Install it, or set codex_path in Watchtower's config."
        }
    }

    /// Delete Session's confirmation: the agent's own record stays. A
    /// Claude Code row (and a shell) keeps the wording it always had.
    package static func deleteSessionMessage(_ kind: TerminalSession.Kind) -> String {
        switch kind {
        case .codex: "Its process stops and it leaves the list. Codex's own session file is kept."
        case .claude, .shell: "Its process stops and it leaves the list. Claude Code's own transcript is kept."
        }
    }

    private static func choice(_ agent: AgentKind, title: String, available: Bool) -> AgentChoice {
        AgentChoice(
            agent: agent,
            title: available ? title : "\(title) (not installed)",
            isAvailable: available,
            hint: available ? nil : notInstalledHint(agent)
        )
    }
}
