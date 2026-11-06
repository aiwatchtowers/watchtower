import Foundation

/// The Workbench session adapter on the Desktop, the Swift twin of Go's
/// `internal/sessionagent` (spec 2026-11-05-llm-transport-independence
/// §3.5): one adapter per agent kind owns how that agent starts (its login
/// shell command), how lines are typed into it, where its transcripts are
/// found, its wire name on the phone and its capability row. Consumers ask
/// `AgentKind.session` or its `caps`, never the kind (LLMTRANSPORT-01); the
/// rows are pinned to Go's `agent_capabilities.json` (`AgentSessionCapsTests`)
/// and the start commands to `internal/sessionstart/testdata/launch_cases.json`
/// (`TerminalLaunchFixtureTests`). WatchtowerCore stays Kit-free, so it does
/// not read the Kit's `AgentSessionCapabilities`.
package protocol SessionAgent: Sendable {
    /// The agent kind the adapter serves.
    var kind: AgentKind { get }
    /// The agent's capability row.
    var caps: AgentSessionCaps { get }
    /// The agent's raw value on the phone's wire (the Kit's
    /// `TerminalSessionState.Agent`; Go `Adapter.WireAgent`).
    var wireAgent: String { get }
    /// How lines are typed into the agent's prompt (spec 2026-10-12 §8).
    var inputProfile: AgentInputProfile { get }
    /// The terminal pane's line when the start exited 127: the shell found no
    /// binary to run.
    var notFoundMessage: String { get }
    /// The login shell's command for one start (Go `Adapter.LaunchCommand`).
    func launchCommand(_ start: AgentStart) -> AgentLaunchCommand
    /// Whether the agent has a transcript for session `id`, through its own
    /// lookup in `lookups` (only the adapter's own is called): `storedPath`
    /// is the path its SessionStart stored, `home` its transcript home (nil:
    /// the stored path alone, for an agent that needs a home). Throws when
    /// the agent's transcript folder could not be listed, so "could not look"
    /// is never read as "none".
    func transcriptExists(id: String, storedPath: String?, home: URL?, in lookups: AgentTranscriptLookups) throws -> Bool
    /// The agent's transcript home in `environment` (the login shell's, which
    /// the launched agent reads); nil when its lookup needs none.
    func transcriptHome(environment: [String: String]) -> URL?
}

extension AgentKind {
    /// The kind's session adapter.
    package var session: any SessionAgent {
        switch self {
        case .claude: ClaudeSessionAgent()
        case .codex: CodexSessionAgent()
        }
    }
}

/// One agent start a workbench terminal launch runs (Go `sessionagent.Start`).
package struct AgentStart: Equatable, Sendable {
    /// The id the app chose for a new session (`AgentSessionCaps.appSessionID`),
    /// or the stored id a resume reopens; nil for a new session of an agent
    /// that mints its own. The caller checked `TerminalLaunch.isValidSessionID`.
    package var sessionID: String?
    /// A new session's first prompt.
    package var prompt: String?
    package var resume: Bool
    /// `workbench launch-args`' resolution for an agent whose hooks arrive
    /// with its launch flags (`AgentSessionCaps.launchHooks`); nil when none.
    package var launchArgs: CodexLaunchArgs?

    /// The first prompt a new session gets; a resume takes none.
    var newPrompt: String? { resume ? nil : prompt }

    package init(sessionID: String?, prompt: String?, resume: Bool, launchArgs: CodexLaunchArgs?) {
        self.sessionID = sessionID
        self.prompt = prompt
        self.resume = resume
        self.launchArgs = launchArgs
    }
}

/// What an agent adds to the owner's login shell for one start (Go
/// `sessionagent.LaunchCommand`).
package struct AgentLaunchCommand: Equatable, Sendable {
    /// The login shell's `-c` command.
    package var command: String
    /// `NAME=value` entries the start needs ahead of its prompt.
    package var environment: [String] = []
    /// The `TerminalLaunch.firstPromptEnv` value; nil for a start without one.
    package var prompt: String?
    /// False when the agent has no binary to run: the command exits 127 and
    /// no worktree setup command runs before it.
    package var runs: Bool
}

/// Each agent's transcript lookup, through the caller's test seams (Go's
/// `sessionagent.Homes`): an adapter calls only its own.
package struct AgentTranscriptLookups {
    /// Claude Code: a transcript for a session id under `~/.claude/projects`.
    package var claude: (String) -> Bool
    /// Codex: a rollout for a session id, given the stored path and the home
    /// (nil: the stored path alone); throws when the sessions folder could not
    /// be listed.
    package var codex: (_ sessionID: String, _ storedPath: String?, _ home: URL?) throws -> Bool

    package init(
        claude: @escaping (String) -> Bool,
        codex: @escaping (_ sessionID: String, _ storedPath: String?, _ home: URL?) throws -> Bool
    ) {
        self.claude = claude
        self.codex = codex
    }
}
