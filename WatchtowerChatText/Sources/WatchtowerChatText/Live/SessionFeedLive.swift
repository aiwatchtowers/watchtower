import Foundation

/// Additive live hint (Go `sessionfeed.Live`): the Mac reads it from the CLI,
/// the phone from the hub's `activity_live`. Existing `activity` remains an
/// open tool call.
public struct SessionFeedLive: Decodable, Hashable, Sendable {
    public var observedAt: Date?
    public var conversation: String
    public var turnAt: Date?
    public var turnActive: Bool
    public var current: SessionLiveAction?
    public var latest: SessionLiveAction?
    public var agents: [SessionLiveAgent]
    public var agentsState: String
    public var agentsMore: Int
    /// The current turn's tool steps in start order (#2065 spec §3): the last
    /// 40, plus any older one still open; `stepsMore` counts the completed
    /// steps cut ahead of them.
    public var steps: [SessionLiveAction]
    public var stepsMore: Int

    public init(
        observedAt: Date?,
        conversation: String = "",
        turnAt: Date? = nil,
        turnActive: Bool = true,
        current: SessionLiveAction? = nil,
        latest: SessionLiveAction? = nil,
        agents: [SessionLiveAgent] = [],
        agentsState: String = "known",
        agentsMore: Int = 0,
        steps: [SessionLiveAction] = [],
        stepsMore: Int = 0
    ) {
        self.observedAt = observedAt; self.conversation = conversation; self.turnAt = turnAt; self.turnActive = turnActive
        self.current = current; self.latest = latest; self.agents = agents; self.agentsState = agentsState; self.agentsMore = agentsMore
        self.steps = steps; self.stepsMore = stepsMore
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FeedWireKey.self)
        observedAt = try c.wireDate("observed_at")
        conversation = try c.wire(String.self, "conversation") ?? ""
        turnAt = try c.wireDate("turn_at")
        turnActive = try c.wire(Bool.self, "turn_active") ?? false
        current = try c.wire(SessionLiveAction.self, "current")
        latest = try c.wire(SessionLiveAction.self, "latest")
        agents = try c.wire([SessionLiveAgent].self, "agents") ?? []
        agentsState = try c.wire(String.self, "agents_state") ?? "unknown"
        agentsMore = try c.wire(Int.self, "agents_more") ?? 0
        steps = try c.wire([SessionLiveAction].self, "steps") ?? []
        stepsMore = try c.wire(Int.self, "steps_more") ?? 0
    }
}

public struct SessionLiveAction: Decodable, Hashable, Sendable {
    public var id: String
    public var tool: String
    public var summary: String
    public var startedAt: Date?
    public var completedAt: Date?
    public var more: Int

    public init(id: String = "", tool: String, summary: String, startedAt: Date? = nil, completedAt: Date? = nil, more: Int = 0) {
        self.id = id; self.tool = tool; self.summary = summary; self.startedAt = startedAt; self.completedAt = completedAt; self.more = more
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FeedWireKey.self)
        id = try c.wire(String.self, "id") ?? ""
        tool = try c.wire(String.self, "tool") ?? ""
        summary = try c.wire(String.self, "summary") ?? ""
        startedAt = try c.wireDate("started_at")
        completedAt = try c.wireDate("completed_at")
        more = try c.wire(Int.self, "more") ?? 0
    }
}

public struct SessionLiveAgent: Decodable, Hashable, Sendable, Identifiable {
    public var ref: SessionFeedSubagent
    public var startedAt: Date?
    public var action: SessionLiveAction?
    public var canOpen: Bool
    public var id: String { ref.toolUseID }
    public init(ref: SessionFeedSubagent, startedAt: Date? = nil, action: SessionLiveAction? = nil, canOpen: Bool = false) {
        self.ref = ref; self.startedAt = startedAt; self.action = action; self.canOpen = canOpen
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FeedWireKey.self)
        ref = try c.decode(SessionFeedSubagent.self, forKey: FeedWireKey("ref"))
        startedAt = try c.wireDate("started_at")
        action = try c.wire(SessionLiveAction.self, "action")
        canOpen = try c.wire(Bool.self, "can_open") ?? false
    }
}
