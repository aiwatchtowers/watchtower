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
    }

    /// A line may go into the session while its agent works: mid-turn input,
    /// and every dialog it can open mid-turn raises a hook state first. Go's
    /// `Caps.TakesLineWhileWorking`.
    public var takesLineWhileWorking: Bool { midturnInput && elicitation }

    /// The phone's one Esc may go to the session. Go's `Caps.TakesInterrupt`.
    public var takesInterrupt: Bool { permissionWait && elicitation }

    /// A failed or interrupted turn is read from the transcript, not a hook.
    public var rolloutWatch: Bool { failureSignal == "pull" }

    /// The fixture's rows by agent kind (`terminal_sessions.kind`).
    public struct Table: Decodable, Sendable {
        public let agents: [String: AgentSessionCapabilities]
    }

    /// Decodes a fixture's bytes.
    public static func decode(_ data: Data) throws -> Table {
        try JSONDecoder().decode(Table.self, from: data)
    }

    /// The bundled rows; empty — every agent reads as offering nothing — when
    /// the resource is missing or does not decode, which a debug build stops
    /// on (the Kit test fails on either).
    public static let bundled: [String: Self] = {
        do {
            guard let url = Bundle.module.url(forResource: "agent_capabilities", withExtension: "json") else {
                assertionFailure("agent_capabilities.json is not bundled")
                return [:]
            }
            return try decode(Data(contentsOf: url)).agents
        } catch {
            assertionFailure("agent_capabilities.json does not decode: \(error)")
            return [:]
        }
    }()

    /// `kind`'s row (a stored `terminal_sessions.kind`); nil for a kind that
    /// is not an agent.
    public static func of(_ kind: String) -> Self? { bundled[kind] }
}
