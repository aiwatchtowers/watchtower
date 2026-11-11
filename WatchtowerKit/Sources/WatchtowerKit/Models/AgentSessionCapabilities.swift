import Foundation

/// What a Workbench session's agent offers (spec
/// 2026-11-05-llm-transport-independence §3.5 "Session capabilities"),
/// decoded from the bundled `agent_capabilities.json`, a copy of the Go
/// session adapters' fixture (`internal/sessionagent/agent_capabilities.json`,
/// pinned to the adapters by `TestSessionAgent_CapsFixtureMatchesAdapters`;
/// the copy is pinned by `AgentSessionCapabilitiesTests`). Consumers ask it
/// instead of the agent kind.
public struct AgentSessionCapabilities: Decodable, Equatable, Sendable {
    /// The hook events that move the session's state.
    public let stateEvents: [String]
    /// How a failed turn is reported: "hook", "pull" or "none".
    public let failureSignal: String
    /// How the owner's Esc is reported: "hook" or "pull".
    public let interruptSignal: String
    public let idleSignal: Bool
    public let permissionWait: Bool
    public let midturnInput: Bool
    public let phoneInput: Bool
    public let elicitation: Bool
    public let registryProbe: Bool
    public let compressedTranscript: Bool
    public let subagentFeed: Bool
    public let analytics: Bool
    public let launchHooks: Bool
    public let backgroundTasks: Bool
    /// The app chooses the agent's session id when it starts a new session
    /// (Claude Code's `--session-id`); otherwise the agent mints its own.
    public let appSessionID: Bool
    /// The transcript records the context parts and the skill listing that
    /// agent analytics' Context and Skills blocks read.
    public let analyticsContext: Bool
    /// The agent may create git worktrees under its own per-session
    /// scratchpad, which the session's cleanup adopts (Claude Code's).
    public let scratchpadLanes: Bool

    enum CodingKeys: String, CodingKey {
        case stateEvents = "state_events"
        case failureSignal = "failure_signal"
        case interruptSignal = "interrupt_signal"
        case idleSignal = "idle_signal"
        case permissionWait = "permission_wait"
        case midturnInput = "midturn_input"
        case phoneInput = "phone_input"
        case elicitation
        case registryProbe = "registry_probe"
        case compressedTranscript = "compressed_transcript"
        case subagentFeed = "subagent_feed"
        case analytics
        case launchHooks = "launch_hooks"
        case backgroundTasks = "background_tasks"
        case appSessionID = "app_session_id"
        case analyticsContext = "analytics_context"
        case scratchpadLanes = "scratchpad_lanes"
    }

    /// A line may go into the session while its agent works: mid-turn input,
    /// and every dialog it can open mid-turn raises a hook state first. Go's
    /// `Caps.TakesLineWhileWorking`.
    public var takesLineWhileWorking: Bool { midturnInput && elicitation }

    /// The phone's one Esc may go to the session. Go's `Caps.TakesInterrupt`.
    public var takesInterrupt: Bool { permissionWait && elicitation }

    /// A failed or interrupted turn is read from the transcript, not a hook.
    public var rolloutWatch: Bool { failureSignal == "pull" }

    /// One entry of Go's agent kind registry (`agentkind`, the fixture's
    /// `kinds`, in its order): every key is required, so a row Go grows
    /// without the Kit fails the decode and the Kit test.
    public struct Kind: Decodable, Equatable, Sendable {
        /// `terminal_sessions.kind`.
        public let kind: String
        /// The workbench comments' `agent_label`.
        public let label: String
        /// The agent's product name.
        public let displayName: String
        /// The `terminal_session` record's `agent` (`TerminalSessionState.Agent`).
        public let wireAgent: String

        enum CodingKeys: String, CodingKey {
            case kind, label
            case displayName = "display_name"
            case wireAgent = "wire_agent"
        }
    }

    /// The fixture: the registry list and the rows by agent kind (`terminal_sessions.kind`).
    public struct Table: Decodable, Sendable {
        public let kinds: [Kind]
        public let agents: [String: AgentSessionCapabilities]
    }

    /// Decodes a fixture's bytes.
    public static func decode(_ data: Data) throws -> Table {
        try JSONDecoder().decode(Table.self, from: data)
    }

    /// The bundled fixture; empty — every agent reads as unknown and offering
    /// nothing — when the resource is missing or does not decode, which a
    /// debug build stops on (the Kit test fails on either).
    private static let bundledTable: Table = {
        do {
            guard let url = Bundle.module.url(forResource: "agent_capabilities", withExtension: "json") else {
                assertionFailure("agent_capabilities.json is not bundled")
                return Table(kinds: [], agents: [:])
            }
            return try decode(Data(contentsOf: url))
        } catch {
            assertionFailure("agent_capabilities.json does not decode: \(error)")
            return Table(kinds: [], agents: [:])
        }
    }()

    /// The bundled rows by agent kind.
    public static var bundled: [String: Self] { bundledTable.agents }

    /// The bundled registry list, in Go's order.
    public static var bundledKinds: [Kind] { bundledTable.kinds }

    /// `kind`'s row (a stored `terminal_sessions.kind`); nil for a kind that
    /// is not an agent.
    public static func of(_ kind: String) -> Self? { bundled[kind] }

    /// The registry entry of a record's wire agent; nil for an agent this
    /// build does not know (a newer Mac's).
    public static func kind(wireAgent: String) -> Kind? { bundledKinds.first { $0.wireAgent == wireAgent } }
}
