import Foundation

/// Additive, Desktop-only hint. Existing `activity` remains an open tool call.
package struct SessionFeedLive: Decodable, Equatable, Sendable {
    package var observedAt: Date?
    package var conversation: String
    package var turnAt: Date?
    package var turnActive: Bool
    package var current: SessionLiveAction?
    package var latest: SessionLiveAction?
    package var agents: [SessionLiveAgent]
    package var agentsState: String
    package var agentsMore: Int

    package init(
        observedAt: Date?,
        conversation: String = "",
        turnAt: Date? = nil,
        turnActive: Bool = true,
        current: SessionLiveAction? = nil,
        latest: SessionLiveAction? = nil,
        agents: [SessionLiveAgent] = [],
        agentsState: String = "known",
        agentsMore: Int = 0
    ) {
        self.observedAt = observedAt; self.conversation = conversation; self.turnAt = turnAt; self.turnActive = turnActive
        self.current = current; self.latest = latest; self.agents = agents; self.agentsState = agentsState; self.agentsMore = agentsMore
    }
    private enum CodingKeys: String, CodingKey {
        case observedAt = "observed_at", conversation, turnAt = "turn_at", turnActive = "turn_active"
        case current, latest, agents, agentsState = "agents_state", agentsMore = "agents_more"
    }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        observedAt = SessionFeedEntry.parseDate(try c.decodeIfPresent(String.self, forKey: .observedAt))
        conversation = try c.decodeIfPresent(String.self, forKey: .conversation) ?? ""
        turnAt = SessionFeedEntry.parseDate(try c.decodeIfPresent(String.self, forKey: .turnAt))
        turnActive = try c.decodeIfPresent(Bool.self, forKey: .turnActive) ?? false
        current = try c.decodeIfPresent(SessionLiveAction.self, forKey: .current)
        latest = try c.decodeIfPresent(SessionLiveAction.self, forKey: .latest)
        agents = try c.decodeIfPresent([SessionLiveAgent].self, forKey: .agents) ?? []
        agentsState = try c.decodeIfPresent(String.self, forKey: .agentsState) ?? "unknown"
        agentsMore = try c.decodeIfPresent(Int.self, forKey: .agentsMore) ?? 0
    }
}

package struct SessionLiveAction: Decodable, Equatable, Sendable {
    package var id: String
    package var tool: String
    package var summary: String
    package var startedAt: Date?
    package var completedAt: Date?
    package var more: Int

    package init(id: String = "", tool: String, summary: String, startedAt: Date? = nil, completedAt: Date? = nil, more: Int = 0) {
        self.id = id; self.tool = tool; self.summary = summary; self.startedAt = startedAt; self.completedAt = completedAt; self.more = more
    }
    private enum CodingKeys: String, CodingKey { case id, tool, summary, startedAt = "started_at", completedAt = "completed_at", more }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        startedAt = SessionFeedEntry.parseDate(try c.decodeIfPresent(String.self, forKey: .startedAt))
        completedAt = SessionFeedEntry.parseDate(try c.decodeIfPresent(String.self, forKey: .completedAt))
        more = try c.decodeIfPresent(Int.self, forKey: .more) ?? 0
    }
}

package struct SessionLiveAgent: Decodable, Equatable, Sendable, Identifiable {
    package var ref: SessionFeedSubagent
    package var startedAt: Date?
    package var action: SessionLiveAction?
    package var canOpen: Bool
    package var id: String { ref.toolUseID }
    package init(ref: SessionFeedSubagent, startedAt: Date? = nil, action: SessionLiveAction? = nil, canOpen: Bool = false) {
        self.ref = ref; self.startedAt = startedAt; self.action = action; self.canOpen = canOpen
    }
    private enum CodingKeys: String, CodingKey { case ref, startedAt = "started_at", action, canOpen = "can_open" }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decode(SessionFeedSubagent.self, forKey: .ref)
        startedAt = SessionFeedEntry.parseDate(try c.decodeIfPresent(String.self, forKey: .startedAt))
        action = try c.decodeIfPresent(SessionLiveAction.self, forKey: .action)
        canOpen = try c.decodeIfPresent(Bool.self, forKey: .canOpen) ?? false
    }
}
