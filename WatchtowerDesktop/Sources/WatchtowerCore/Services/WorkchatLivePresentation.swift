import Foundation

/// All live-row and agent-picker copy. Time passage only changes this pure
/// projection; the one existing poller owns the snapshot and retry.
package enum WorkchatLivePresentation {
    package static let staleAfter: TimeInterval = 10
    package static let retryTitle = "Retry"
    package static let agentsHelp = "Show running agents"
    package static let unknownAgents = "Agent status unavailable"
    package static let working = "Working…"
    package static let loading = "Loading activity…"
    package static let unavailable = "Activity unavailable"

    package struct Row: Equatable, Sendable {
        package var symbol: String
        package var text: String
        package var elapsed: String?
        package var agentsBadge: String?
        package var warning: Bool
        package var pulse: Bool
        package var retry: Bool
        package var agentsEnabled: Bool
    }
    package struct AgentRow: Equatable, Identifiable, Sendable {
        package var agent: SessionLiveAgent
        package var title: String
        package var action: String
        package var elapsed: String?
        package var id: String { agent.id }
    }
    package static func row(
        snapshot: SessionFeedLive?,
        error: String?,
        loaded: Bool,
        working: Bool,
        stateAt: Date?,
        now: Date
    ) -> Row? {
        guard working else { return nil }
        let stale = snapshot?.observedAt.map { now.timeIntervalSince($0) >= staleAfter } ?? false
        if error != nil || stale || (loaded && (snapshot == nil || snapshot?.observedAt == nil)) {
            let text: String
            if stale, let at = snapshot?.observedAt {
                text = "Activity out of date · \(max(0, Int(now.timeIntervalSince(at))))s ago"
            } else { text = unavailable }
            return Row(symbol: stale ? "clock" : "exclamationmark.circle", text: text, elapsed: nil,
                       agentsBadge: "?", warning: true, pulse: false, retry: true, agentsEnabled: false)
        }
        guard let snapshot else {
            return Row(symbol: "ellipsis", text: loading, elapsed: elapsed(from: stateAt, now: now), agentsBadge: nil,
                       warning: false, pulse: false, retry: false, agentsEnabled: false)
        }
        let active = snapshot.agents.filter { $0.ref.status != "finished" }
        let unknown = snapshot.agentsState != "known" || active.contains { $0.ref.status != "running" }
        let count = active.count + snapshot.agentsMore
        let badge = unknown ? "?" : (count > 0 ? String(count) : nil)
        var result = Row(symbol: "ellipsis", text: workingText(snapshot), elapsed: elapsed(from: snapshot.turnAt ?? stateAt, now: now),
                         agentsBadge: badge, warning: false, pulse: false, retry: false, agentsEnabled: badge != nil)
        if snapshot.turnActive, let current = snapshot.current, current.startedAt != nil {
            result.symbol = WorkchatActivityPresenter.symbol(for: current.tool)
            result.text = current.summary + (current.more > 0 ? " · \(current.more) more" : "")
            result.elapsed = elapsed(from: current.startedAt, now: now)
            result.pulse = true
        } else if snapshot.turnActive, let latest = snapshot.latest {
            result.symbol = WorkchatActivityPresenter.symbol(for: latest.tool)
            result.text = "Last · \(latest.summary)"
        }
        return result
    }
    private static func workingText(_ snapshot: SessionFeedLive) -> String { working }
    package static func agentsTitle(count: Int) -> String { "Running agents · \(count)" }
    package static func moreAgents(_ count: Int) -> String { "\(count) more agents" }
    package static func agentRows(_ snapshot: SessionFeedLive?, error: String? = nil, now: Date) -> [AgentRow] {
        guard error == nil, let snapshot, let observed = snapshot.observedAt,
              now.timeIntervalSince(observed) < staleAfter else { return [] }
        return snapshot.agents.filter { $0.ref.status != "finished" }.map {
            AgentRow(agent: $0, title: $0.ref.description.isEmpty ? ($0.ref.type.isEmpty ? "Agent" : $0.ref.type) : $0.ref.description,
                     action: $0.ref.status == "running" ? ($0.action?.summary ?? working) : unknownAgents,
                     elapsed: elapsed(from: $0.startedAt, now: now))
        }
    }
    package static func elapsed(from start: Date?, now: Date) -> String? {
        guard let start else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
