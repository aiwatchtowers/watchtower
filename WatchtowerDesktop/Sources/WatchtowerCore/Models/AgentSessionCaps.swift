import Foundation

/// What a Workbench session's agent offers beyond its state hooks (spec
/// 2026-11-05-llm-transport-independence §3.5 "Session capabilities").
/// Consumers ask it instead of the kind. Mirrors Go's
/// `agentkind.SessionCaps` by hand (a Go↔Swift dual path); plan Task A5's
/// shared `agent_capabilities.json` replaces both.
package struct AgentSessionCaps: Equatable, Sendable {
    /// A line pasted with its Return while the agent works is taken at the
    /// agent's next step instead of waiting for the turn's end.
    package var midturnInput: Bool
    /// The hub types a phone line (or the wrap-up line) into the session (PROJ-16).
    package var phoneInput: Bool
    /// A PermissionRequest hook can hold the prompt while the terminal still
    /// shows it, and answer it (PROJ-21: the phone's answer and Interrupt).
    package var permissionWait: Bool
    /// The agent reports an idle prompt (Claude Code's `idle_prompt`).
    package var idleSignal: Bool
    /// The agent reports an MCP elicitation through a hook.
    package var elicitation: Bool

    package init(
        midturnInput: Bool, phoneInput: Bool, permissionWait: Bool, idleSignal: Bool, elicitation: Bool
    ) {
        self.midturnInput = midturnInput
        self.phoneInput = phoneInput
        self.permissionWait = permissionWait
        self.idleSignal = idleSignal
        self.elicitation = elicitation
    }

    /// A kind that is not an agent (a shell) offers nothing.
    package static let none = Self(
        midturnInput: false, phoneInput: false, permissionWait: false, idleSignal: false, elicitation: false
    )

    /// `agent`'s row. Codex's comes from plan Task G7's spikes on codex
    /// 0.159.2: a line pasted mid-turn goes into the running turn; its
    /// PermissionRequest hook hides the terminal prompt while it holds, so
    /// it does not wait for the phone; it has no idle or elicitation event.
    package static func of(_ agent: AgentKind) -> Self {
        switch agent {
        case .claude:
            Self(midturnInput: true, phoneInput: true, permissionWait: true, idleSignal: true, elicitation: true)
        case .codex:
            Self(midturnInput: true, phoneInput: true, permissionWait: false, idleSignal: false, elicitation: false)
        }
    }

    /// The row of a stored session kind; nil (not known yet) and a shell offer nothing.
    package static func of(_ kind: TerminalSession.Kind?) -> Self {
        kind?.agent.map(of) ?? .none
    }

    /// Settings → Notifications' line under Workbench notifications (U7):
    /// the agents whose sessions never give an idle notice, from the
    /// capability rows; nil when every agent reports an idle prompt.
    package static func idleNoticeCaption(caps: (AgentKind) -> Self = of) -> String? {
        let names = AgentKind.allCases.filter { !caps($0).idleSignal }.map(\.displayName)
        guard !names.isEmpty else { return nil }
        return "Idle notices are not available for \(names.joined(separator: " and ")) sessions."
    }
}
