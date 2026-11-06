import Foundation

/// What a Workbench session's agent offers beyond its state hooks (spec
/// 2026-11-05-llm-transport-independence §3.5 "Session capabilities").
/// Consumers ask it instead of the kind. The rows are the session adapters'
/// (`SessionAgent.caps`) and mirror Go's `sessionagent.Caps` (WatchtowerCore
/// stays Kit-free, so it does not read the Kit's `AgentSessionCapabilities`);
/// `AgentSessionCapsTests` pins them to the shared
/// `internal/sessionagent/agent_capabilities.json`.
package struct AgentSessionCaps: Equatable, Sendable {
    /// A line pasted with its Return while the agent works is taken at the
    /// agent's next step instead of waiting for the turn's end.
    package let midturnInput: Bool
    /// The hub types a phone line (or the wrap-up line) into the session (PROJ-16).
    package let phoneInput: Bool
    /// A PermissionRequest hook can hold the prompt while the terminal still
    /// shows it, and answer it (PROJ-21: the phone's answer).
    package let permissionWait: Bool
    /// The agent reports an idle prompt (Claude Code's `idle_prompt`).
    package let idleSignal: Bool
    /// The agent reports an MCP elicitation through a hook.
    package let elicitation: Bool
    /// A failed or interrupted turn is read from the agent's transcript, not
    /// a hook: the session host's rollout watch, or the app's bridge probe
    /// for a session the host does not watch (spec §3.5, G5).
    package let rolloutWatch: Bool
    /// The hook set and the MCP server arrive with the agent's launch flags,
    /// which `watchtower workbench launch-args` resolves before each start;
    /// otherwise they are installed into the folder.
    package let launchHooks: Bool
    /// The app chooses the agent's session id when it starts a new session
    /// (Claude Code's `--session-id`), so the row holds one from its creation
    /// and a relaunch resumes it; otherwise the agent mints its own and its
    /// first SessionStart reports it.
    package let appSessionID: Bool

    package init(
        midturnInput: Bool,
        phoneInput: Bool,
        permissionWait: Bool,
        idleSignal: Bool,
        elicitation: Bool,
        rolloutWatch: Bool = false,
        launchHooks: Bool = false,
        appSessionID: Bool = false
    ) {
        self.midturnInput = midturnInput
        self.phoneInput = phoneInput
        self.permissionWait = permissionWait
        self.idleSignal = idleSignal
        self.elicitation = elicitation
        self.rolloutWatch = rolloutWatch
        self.launchHooks = launchHooks
        self.appSessionID = appSessionID
    }

    /// A kind that is not an agent (a shell) offers nothing.
    package static let none = Self(
        midturnInput: false, phoneInput: false, permissionWait: false, idleSignal: false, elicitation: false
    )

    /// A line may go into the session while its agent works. Mid-turn input
    /// alone is not enough: every dialog that can open mid-turn must raise a
    /// hook state first (an MCP elicitation included), or a line pasted with
    /// its Return would answer a form Watchtower cannot see. Go's
    /// `sessionagent.Caps.TakesLineWhileWorking`.
    package var takesLineWhileWorking: Bool { midturnInput && elicitation }

    /// The phone's one Esc (PROJ-21) may go to the session: a prompt the hooks
    /// report is never at risk, and no unreported form can be open. Go's
    /// `sessionagent.Caps.TakesInterrupt`.
    package var takesInterrupt: Bool { permissionWait && elicitation }

    /// `agent`'s row, from its session adapter.
    package static func of(_ agent: AgentKind) -> Self { agent.session.caps }

    /// Settings → Notifications' line under Workbench notifications (U7):
    /// the agents whose sessions never give an idle notice, from the
    /// capability rows; nil when every agent reports an idle prompt.
    package static func idleNoticeCaption(caps: (AgentKind) -> Self = of) -> String? {
        let names = AgentKind.allCases.filter { !caps($0).idleSignal }.map(\.displayName)
        guard !names.isEmpty else { return nil }
        return "Idle notices are not available for \(names.joined(separator: " and ")) sessions."
    }
}
