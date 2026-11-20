import Foundation

/// Additive, Desktop-only hint. Existing `activity` remains an open tool call.
public struct SessionFeedLive: Decodable, Equatable, Sendable {
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
    private enum CodingKeys: String, CodingKey {
        case observedAt = "observed_at", conversation, turnAt = "turn_at", turnActive = "turn_active"
        case current, latest, agents, agentsState = "agents_state", agentsMore = "agents_more"
        case steps, stepsMore = "steps_more"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        observedAt = SessionFeedDate.parse(try c.decodeIfPresent(String.self, forKey: .observedAt))
        conversation = try c.decodeIfPresent(String.self, forKey: .conversation) ?? ""
        turnAt = SessionFeedDate.parse(try c.decodeIfPresent(String.self, forKey: .turnAt))
        turnActive = try c.decodeIfPresent(Bool.self, forKey: .turnActive) ?? false
        current = try c.decodeIfPresent(SessionLiveAction.self, forKey: .current)
        latest = try c.decodeIfPresent(SessionLiveAction.self, forKey: .latest)
        agents = try c.decodeIfPresent([SessionLiveAgent].self, forKey: .agents) ?? []
        agentsState = try c.decodeIfPresent(String.self, forKey: .agentsState) ?? "unknown"
        agentsMore = try c.decodeIfPresent(Int.self, forKey: .agentsMore) ?? 0
        steps = try c.decodeIfPresent([SessionLiveAction].self, forKey: .steps) ?? []
        stepsMore = try c.decodeIfPresent(Int.self, forKey: .stepsMore) ?? 0
    }
}

public struct SessionLiveAction: Decodable, Equatable, Sendable {
    public var id: String
    public var tool: String
    public var summary: String
    public var startedAt: Date?
    public var completedAt: Date?
    public var more: Int

    public init(id: String = "", tool: String, summary: String, startedAt: Date? = nil, completedAt: Date? = nil, more: Int = 0) {
        self.id = id; self.tool = tool; self.summary = summary; self.startedAt = startedAt; self.completedAt = completedAt; self.more = more
    }
    private enum CodingKeys: String, CodingKey { case id, tool, summary, startedAt = "started_at", completedAt = "completed_at", more }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        startedAt = SessionFeedDate.parse(try c.decodeIfPresent(String.self, forKey: .startedAt))
        completedAt = SessionFeedDate.parse(try c.decodeIfPresent(String.self, forKey: .completedAt))
        more = try c.decodeIfPresent(Int.self, forKey: .more) ?? 0
    }
}

public struct SessionLiveAgent: Decodable, Equatable, Sendable, Identifiable {
    public var ref: SessionFeedSubagent
    public var startedAt: Date?
    public var action: SessionLiveAction?
    public var canOpen: Bool
    public var id: String { ref.toolUseID }
    public init(ref: SessionFeedSubagent, startedAt: Date? = nil, action: SessionLiveAction? = nil, canOpen: Bool = false) {
        self.ref = ref; self.startedAt = startedAt; self.action = action; self.canOpen = canOpen
    }
    private enum CodingKeys: String, CodingKey { case ref, startedAt = "started_at", action, canOpen = "can_open" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decode(SessionFeedSubagent.self, forKey: .ref)
        startedAt = SessionFeedDate.parse(try c.decodeIfPresent(String.self, forKey: .startedAt))
        action = try c.decodeIfPresent(SessionLiveAction.self, forKey: .action)
        canOpen = try c.decodeIfPresent(Bool.self, forKey: .canOpen) ?? false
    }
}
