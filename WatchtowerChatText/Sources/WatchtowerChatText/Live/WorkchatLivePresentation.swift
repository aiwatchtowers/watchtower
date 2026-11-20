import Foundation

/// All live-row and agent-picker copy. Time passage only changes this pure
/// projection; the one existing poller owns the snapshot and retry.
public enum WorkchatLivePresentation {
    public static let staleAfter: TimeInterval = 10
    public static let retryTitle = "Retry"
    public static let agentsHelp = "Show running agents"
    public static let unknownAgents = "Agent status unavailable"
    public static let working = "Working…"
    public static let loading = "Loading activity…"
    public static let unavailable = "Activity unavailable"
    // The 👥 list (#2065 spec §2).
    public static let listTitle = "Agents"
    public static let workingTitle = "WORKING"
    public static let noneWorking = "No agents working"
    public static let listLoading = "Loading agents…"
    public static let listError = "Couldn’t read the agents"
    public static func doneTitle(_ count: Int) -> String { "Done · \(count)" }
    /// Done shows at most this many rows, the rest scroll.
    public static let maxDoneRows = 5
    // The live steps of the current turn (#2065 spec §3).
    /// The steps slot is this many rows tall from the moment it appears; more scroll.
    public static let stepsVisibleRows = 6
    public static func stepsHeight(rowHeight: CGFloat) -> CGFloat { CGFloat(stepsVisibleRows) * rowHeight }
    /// The live line's accessibility hint while it toggles the steps.
    public static func stepsToggleHint(open: Bool) -> String { open ? "Hide this turn’s steps" : "Show this turn’s steps" }
    public static func turnSummary(_ count: Int) -> String { "This turn · \(count) \(count == 1 ? "step" : "steps")" }

    public struct Row: Equatable, Sendable {
        public var symbol: String
        public var text: String
        public var elapsed: String?
        public var agentsBadge: String?
        public var warning: Bool
        public var pulse: Bool
        public var retry: Bool
        public var agentsEnabled: Bool
        /// false: no turn runs, the row holds only the 👥 button (no text or timer).
        public var activity = true
        /// "person.2" for working agents (or unknown), "checkmark" when only finished ones remain.
        public var agentsSymbol = "person.2"
        /// The badge counts finished agents only: tertiary on a faint capsule.
        public var agentsDimmed = false
        /// The steps disclosure: "chevron.up" closed, "chevron.down" open, nil without a steps slot.
        public var chevron: String?
    }
    public struct StepRow: Equatable, Identifiable, Sendable {
        public var id: String
        public var symbol: String
        public var summary: String
        /// The step's duration, or the running timer; nil without its times.
        public var time: String?
        public var running: Bool
    }
    public struct StepsSlot: Equatable, Sendable {
        public var rows: [StepRow]
        /// "This turn · N steps", counting the steps the cap cut.
        public var title: String
    }
    public struct AgentRow: Equatable, Identifiable, Sendable {
        public var agent: SessionLiveAgent
        public var title: String
        public var action: String
        public var elapsed: String?
        public var id: String { agent.id }
        /// The list row's first line: the agent's type (else the title).
        public var heading: String { agent.ref.type.isEmpty ? title : agent.ref.type }
        /// The list row's second line: the task, then what it does now.
        public var subtitle: String { heading == title ? action : "\(title) · \(action)" }
    }
    public struct DoneRow: Equatable, Identifiable, Sendable {
        public var ref: SessionFeedSubagent
        public var title: String
        public var subtitle: String
        public var id: String
    }
    public struct AgentsList: Equatable, Sendable {
        public enum State: Equatable, Sendable { case ready, loading, error }
        public var state: State
        public var working: [AgentRow]
        /// Said under WORKING when it has no rows; nil when rows show.
        public var workingNote: String?
        public var done: [DoneRow]
        public var doneTitle: String
        /// Done opens by itself when nothing is known to work (C2).
        public var doneOpenByDefault: Bool
    }
    public static func row(
        snapshot: SessionFeedLive?,
        error: String?,
        loaded: Bool,
        working: Bool,
        stateAt: Date?,
        now: Date,
        done: [SessionFeedSubagent] = [],
        activityHidden: Bool = false,
        stepsOpen: Bool = false
    ) -> Row? {
        guard working else {
            // Idle or ended: only the 👥 button, and only with finished agents to list.
            guard !done.isEmpty else { return nil }
            return Row(symbol: "", text: "", elapsed: nil, agentsBadge: String(done.count), warning: false, pulse: false,
                       retry: false, agentsEnabled: true, activity: false, agentsSymbol: "checkmark", agentsDimmed: true)
        }
        // An agent already in Done is never counted as working (the list filters it too).
        var counted = snapshot
        if !done.isEmpty {
            let doneIDs = Set(done.map(\.toolUseID))
            counted?.agents.removeAll { doneIDs.contains($0.id) }
        }
        var result = workingRow(snapshot: counted, error: error, loaded: loaded, stateAt: stateAt, now: now)
        let unknown = result.agentsBadge == "?"
        if result.agentsBadge == nil, !done.isEmpty {
            result.agentsBadge = String(done.count)
            result.agentsSymbol = "checkmark"
            result.agentsDimmed = true
        }
        // Unknown live status still opens the list when Done has rows to read.
        result.agentsEnabled = result.agentsBadge != nil && (!unknown || !done.isEmpty)
        if activityHidden {
            // A permission card stands in for the step and its timer; the 👥 button keeps the real count.
            result.activity = false
            result.elapsed = nil
            result.pulse = false
            result.retry = false
            result.warning = false
        } else if let snapshot, let slot = stepsSlot(snapshot: snapshot, error: error, working: true, now: now) {
            result.chevron = stepsOpen ? "chevron.down" : "chevron.up"
            if stepsOpen {
                // The list shows the newest step; the line sums up the turn.
                result.symbol = "list.bullet"
                result.text = slot.title
                result.elapsed = elapsed(from: snapshot.turnAt ?? stateAt, now: now)
                result.pulse = false
            }
        }
        return result
    }

    /// The current turn's steps above the live line, or nil when the slot
    /// hides: not working (stop, the host or session closed), no snapshot
    /// (the pane passes none while a permission card shows), a failed or
    /// stale read, the turn ended, or no steps yet. Stricter than `row`: a
    /// snapshot without `observedAt` hides the list even before `loaded`,
    /// since its freshness cannot be told.
    public static func stepsSlot(snapshot: SessionFeedLive?, error: String?, working: Bool, now: Date) -> StepsSlot? {
        guard working, error == nil, let snapshot, snapshot.turnActive, !snapshot.steps.isEmpty,
              let observed = snapshot.observedAt, now.timeIntervalSince(observed) < staleAfter else { return nil }
        let rows = snapshot.steps.map { step in
            let running = step.completedAt == nil
            let time = step.startedAt.flatMap { start in
                (running ? now : step.completedAt).flatMap { elapsed(from: start, now: $0) }
            }
            return StepRow(id: step.id, symbol: WorkchatActivityPresenter.symbol(for: step.tool), summary: step.summary,
                           time: time, running: running)
        }
        return StepsSlot(rows: rows, title: turnSummary(snapshot.steps.count + snapshot.stepsMore))
    }

    private static func workingRow(
        snapshot: SessionFeedLive?,
        error: String?,
        loaded: Bool,
        stateAt: Date?,
        now: Date
    ) -> Row {
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
    public static func agentsTitle(count: Int) -> String { "Running agents · \(count)" }
    /// The 👥 button's help and accessibility label, naming its count; nil without a button.
    public static func agentsLabel(_ row: Row) -> String? {
        guard let badge = row.agentsBadge else { return nil }
        if badge == "?" { return "\(listTitle) · status unavailable" }
        return row.agentsDimmed ? "\(listTitle) · Done \(badge)" : "\(listTitle) · \(badge) working"
    }
    public static func agentsTitle(snapshot: SessionFeedLive?) -> String {
        guard let snapshot, snapshot.agentsState == "known",
              !snapshot.agents.contains(where: { $0.ref.status == "unknown" }) else { return "Running agents · unknown" }
        let count = snapshot.agents.filter { $0.ref.status != "finished" }.count + snapshot.agentsMore
        return agentsTitle(count: count)
    }
    public static func moreAgents(_ count: Int) -> String { "\(count) more agents" }
    public static func agentRows(_ snapshot: SessionFeedLive?, error: String? = nil, now: Date) -> [AgentRow] {
        guard error == nil, let snapshot, let observed = snapshot.observedAt,
              now.timeIntervalSince(observed) < staleAfter else { return [] }
        return snapshot.agents.filter { $0.ref.status != "finished" }.map {
            AgentRow(agent: $0, title: $0.ref.description.isEmpty ? ($0.ref.type.isEmpty ? "Agent" : $0.ref.type) : $0.ref.description,
                     action: $0.ref.status == "running" ? ($0.action?.summary ?? working) : unknownAgents,
                     elapsed: elapsed(from: $0.startedAt, now: now))
        }
    }
    /// The 👥 list: Working from the live snapshot (minus any id already in
    /// Done), Done from the feed's finished markers (`done(from:)`). Done from
    /// the last good read survives a later failure (`feedLoaded`). `idle`: the
    /// session runs no turn; otherwise a missing or stale snapshot means the
    /// agents are not observed, never that none works.
    public static func agentsList(
        snapshot: SessionFeedLive?,
        error: String?,
        feedLoaded: Bool,
        feedError: String?,
        done: [SessionFeedSubagent],
        idle: Bool,
        now: Date
    ) -> AgentsList {
        let state: AgentsList.State = feedLoaded ? .ready : (feedError == nil ? .loading : .error)
        let doneIDs = Set(done.map(\.toolUseID))
        let working = agentRows(snapshot, error: error, now: now).filter { !doneIDs.contains($0.id) }
        var counted = snapshot
        counted?.agents.removeAll { doneIDs.contains($0.id) }
        let unknown = workingUnknown(counted, error: error, idle: idle, now: now)
        let note: String? = unknown ? unknownAgents : (working.isEmpty ? noneWorking : nil)
        let rows = done.map {
            DoneRow(ref: $0, title: $0.type.isEmpty ? "Subagent" : $0.type, subtitle: $0.description, id: $0.toolUseID)
        }
        return AgentsList(state: state, working: working, workingNote: note, done: rows, doneTitle: doneTitle(done.count),
                          doneOpenByDefault: working.isEmpty || unknown)
    }

    /// The live snapshot cannot say who works: a read error, no fresh snapshot
    /// while the session is busy, agents state not known, or an agent whose
    /// status is not resolved. An idle session's missing or old read is none.
    private static func workingUnknown(_ snapshot: SessionFeedLive?, error: String?, idle: Bool, now: Date) -> Bool {
        if error != nil { return true }
        guard let snapshot, let observed = snapshot.observedAt, now.timeIntervalSince(observed) < staleAfter else {
            return !idle
        }
        return snapshot.agentsState != "known"
            || snapshot.agents.contains { $0.ref.status != "finished" && $0.ref.status != "running" }
    }

    /// The finished subagents among the feed's markers' subagents:
    /// `started_at` newest first; undated ones after them, ties and undated in
    /// the CLI's order.
    public static func done(from subagents: [SessionFeedSubagent]) -> [SessionFeedSubagent] {
        let finished = subagents.filter { $0.status == "finished" }
        let ordered = finished.enumerated().sorted { lhs, rhs in
            switch (lhs.element.startedAt, rhs.element.startedAt) {
            case let (l?, r?) where l != r: l > r
            case (.some, nil): true
            case (nil, .some): false
            default: lhs.offset < rhs.offset
            }
        }
        return ordered.map(\.element)
    }

    public static func elapsed(from start: Date?, now: Date) -> String? {
        guard let start else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
