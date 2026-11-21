import Foundation
import WatchtowerChatText
import WatchtowerKit
import WatchtowerSync

/// The session's subagents for the agents sheet (#2065, spec §2): the markers leave the dialog and sort into
/// Working and Done. With the chat's live block (#2112 spec §6) Working and the toolbar badge come from the shared
/// `WorkchatLivePresentation` (C1), as on the Mac: a row is the agent's type, task, current step and timer, an agent
/// the block reports finished is Done, and a stale tower or a failed read shows no step (spec §4, C4). Without the
/// block (older hub) a Working row is type, description and "Running", counted from the markers.
struct WorkchatAgents: Equatable {
    struct Row: Identifiable, Equatable {
        let id: String
        let type: String
        let description: String
        /// nil for an agent without its agent id or tool_use id, or one the live block says cannot be opened.
        let route: SessionChatRoute?
        /// What the agent does now (the shared `AgentRow.action`); nil without live data for it.
        var action: String?
        /// The SF Symbol of the step's tool (`AgentRow.symbol`).
        var symbol: String?
        /// The agent's running time at the moment the row was built (`AgentRow.elapsed`).
        var elapsed: String?
    }

    /// The toolbar button's face.
    enum Badge: Equatable {
        case working(Int)
        case done(Int)
        /// The live block cannot say who works (failed read, stale tower, unresolved agent).
        case unknown
    }

    /// The owner's choice for the Done section; `automatic` until they toggle it.
    enum DoneDisclosure: Equatable {
        case automatic, open, closed
    }

    /// The live block as the shared presentation reads it on the phone.
    private struct Live: Equatable {
        var snapshot: SessionFeedLive?
        var error: String?
        var tower: TowerFreshness
        var sessionWorking: Bool
        var done: [SessionFeedSubagent]

        /// Spec §4 (C4): the snapshot counts as observed now while the tower sends, and at its last publish once it
        /// stopped, so the presentation's own staleness rule applies; never the hub's read time.
        func snapshot(at now: Date) -> SessionFeedLive? {
            var result = snapshot
            result?.observedAt = tower.staleSince(at: now) ?? now
            return result
        }
    }

    /// Working at the moment the model was built; the sheet redraws it with `working(at:)`.
    let working: [Row]
    /// Newest first.
    let done: [Row]
    let badge: Badge?
    private let live: Live?
    private let sessionID: Int64
    /// The markers' running agents, for an older hub or when the live block cannot say who works.
    private let markerWorking: [Row]

    /// `live`/`liveError`: the chat's `activityLive`/`liveError`; neither for an older hub. `sessionWorking`: the
    /// session runs a turn. `tower`: the heartbeat and link the tower's freshness is judged from.
    init(
        entries: [SessionChat.Entry],
        sessionID: Int64,
        live: SessionFeedLive? = nil,
        liveError: String? = nil,
        sessionWorking: Bool = false,
        tower: TowerFreshness = TowerFreshness(),
        now: Date = .distantPast
    ) {
        let finishedLive = Set((live?.agents ?? []).filter { $0.ref.status == "finished" }.map(\.id))
        var working: [Row] = []
        var done: [Row] = []
        var doneRefs: [SessionFeedSubagent] = []
        for entry in entries where entry.kind == .subagent {
            guard let subagent = entry.subagent else { continue }
            let row = Row(
                id: entry.id,
                type: Self.type(subagent.type),
                description: subagent.description,
                route: SessionChatEntryRow.route(for: subagent, sessionID: sessionID)
            )
            // A status a newer Mac adds lands in neither section; an agent the live block saw finish is Done.
            switch subagent.status {
            case "running" where !finishedLive.contains(subagent.toolUseID):
                working.append(row)
            case "running", "finished":
                done.append(row)
                doneRefs.append(SessionFeedSubagent(toolUseID: subagent.toolUseID, agentID: subagent.agentID,
                                                    type: subagent.type, description: subagent.description, status: "finished"))
            default: break
            }
        }
        // A finished agent whose marker the dialog's cap cut: Done from the live block, after the markers' (older).
        var seen = Set(entries.compactMap { $0.subagent?.toolUseID }.filter { !$0.isEmpty })
        var doneRows = Array(done.reversed())
        for agent in live?.agents ?? [] where agent.ref.status == "finished" && seen.insert(agent.id).inserted {
            let ref = agent.ref
            doneRows.append(Row(id: agent.id, type: Self.type(ref.type), description: ref.description,
                                route: Self.route(agent, sessionID: sessionID)))
            doneRefs.append(ref)
        }
        self.sessionID = sessionID
        markerWorking = working
        self.done = doneRows
        let input = live != nil || liveError != nil
            ? Live(snapshot: live, error: liveError, tower: tower, sessionWorking: sessionWorking, done: doneRefs)
            : nil
        self.live = input
        self.working = input.map { Self.working($0, markers: working, sessionID: sessionID, now: now) } ?? working
        badge = Self.badge(input, markers: working, done: doneRows, now: now)
    }

    /// Working at `now`: the shared agents list's rows, or the markers' when the live block cannot say who works.
    func working(at now: Date) -> [Row] {
        guard let live else { return markerWorking }
        return Self.working(live, markers: markerWorking, sessionID: sessionID, now: now)
    }

    /// The toolbar's face at `now`, the tower's freshness judged again.
    func badge(at now: Date) -> Badge? {
        Self.badge(live, markers: markerWorking, done: done, now: now)
    }

    /// Whether the rows carry a timer, so the sheet redraws them each second.
    var ticks: Bool { working.contains { $0.elapsed != nil } }

    private static func working(_ live: Live, markers: [Row], sessionID: Int64, now: Date) -> [Row] {
        // The turn is over: the record's last block no longer says who works.
        guard live.sessionWorking else { return [] }
        let list = WorkchatLivePresentation.agentsList(
            snapshot: live.snapshot(at: now), error: live.error, feedLoaded: true, feedError: nil, done: live.done,
            idle: !live.sessionWorking, now: now
        )
        if !list.working.isEmpty { return list.working.map { row($0, sessionID: sessionID) } }
        return list.workingNote == WorkchatLivePresentation.unknownAgents ? markers : []
    }

    private static func badge(_ live: Live?, markers: [Row], done: [Row], now: Date) -> Badge? {
        guard let live else { return !markers.isEmpty ? .working(markers.count) : (done.isEmpty ? nil : .done(done.count)) }
        let row = WorkchatLivePresentation.row(
            snapshot: live.snapshot(at: now), error: live.error, loaded: true, working: live.sessionWorking, stateAt: nil,
            now: now, done: live.done
        )
        guard let badge = row?.agentsBadge else { return nil }
        if badge == "?" { return .unknown }
        let count = Int(badge) ?? 0
        return row?.agentsDimmed == true ? .done(count) : .working(count)
    }

    private static func row(_ agent: WorkchatLivePresentation.AgentRow, sessionID: Int64) -> Row {
        Row(id: agent.id, type: agent.heading, description: agent.heading == agent.title ? "" : agent.title,
            route: route(agent.agent, sessionID: sessionID), action: agent.action, symbol: agent.symbol, elapsed: agent.elapsed)
    }

    private static func route(_ agent: SessionLiveAgent, sessionID: Int64) -> SessionChatRoute? {
        let ref = agent.ref
        guard agent.canOpen, !ref.agentID.isEmpty, !ref.toolUseID.isEmpty else { return nil }
        return SessionChatRoute(sessionID: sessionID, agentID: ref.agentID, toolUseID: ref.toolUseID)
    }

    private static func type(_ type: String) -> String { type.isEmpty ? "Subagent" : type }

    /// The dialog without the subagent markers.
    static func dialog(_ entries: [SessionChat.Entry]) -> [SessionChat.Entry] {
        entries.filter { $0.kind != .subagent }
    }

    /// Done opens by itself when nothing is known to work.
    var doneOpenByDefault: Bool {
        if case .working = badge { return false }
        return !done.isEmpty
    }

    /// Whether Done shows: the owner's choice wins over the default.
    func doneIsOpen(_ disclosure: DoneDisclosure) -> Bool {
        switch disclosure {
        case .automatic: doneOpenByDefault
        case .open: true
        case .closed: false
        }
    }
}

/// The agents button's and sheet's fixed strings.
enum WorkchatAgentsText {
    static let title = "Agents"
    static let working = "Working"
    static let running = "Running"
    static let close = "Close"
    static let unknownBadge = "?"

    static func done(_ n: Int) -> String { "Done · \(n)" }
    static func doneBadge(_ n: Int) -> String { "✓ \(n)" }
    /// The toolbar button's spoken value.
    static func badgeValue(_ badge: WorkchatAgents.Badge) -> String {
        switch badge {
        case let .working(n): "\(n) working"
        case let .done(n): "\(n) done"
        case .unknown: "status unavailable"
        }
    }
}
