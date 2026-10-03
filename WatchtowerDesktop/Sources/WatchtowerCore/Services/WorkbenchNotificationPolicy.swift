import Foundation

package enum WorkbenchNoticeKind: String, Codable, Sendable {
    case agentAsks
    /// The agent filed an owner ask (spec 2026-10-03 Part 8).
    case askOpened
    case targetDone
    /// A write the agent proposed from the workbench terminal that only the
    /// owner can approve (a Slack send, DEV-06) — the card is in the Inbox.
    case actionAwaitsApproval
}

package struct WorkbenchNotice: Equatable, Sendable {
    package let kind: WorkbenchNoticeKind
    package let projectID: Int64
    package let title: String
    package let body: String
    package let route: WorkbenchRoute
    /// Stable per event, so a re-post replaces instead of stacking.
    package let identifier: String
}

/// Which project events become owner notifications (spec §6.5). Pure: the
/// center feeds it the previous and current snapshot of each project; no
/// clock, no I/O.
package enum WorkbenchNotificationPolicy {
    package static let coalesceThreshold = 3

    package struct Question: Codable, Equatable, Sendable {
        package let id: Int64
        package let targetID: Int64
        package let targetTitle: String
        package let body: String

        package init(id: Int64, targetID: Int64, targetTitle: String, body: String) {
            self.id = id
            self.targetID = targetID
            self.targetTitle = targetTitle
            self.body = body
        }
    }

    /// An `owner_asks` row still `open` at the poll.
    package struct OpenAsk: Codable, Equatable, Sendable {
        package let title: String
        /// The terminal session that filed it; nil for one filed outside the app.
        package let sessionID: Int64?

        package init(title: String, sessionID: Int64? = nil) {
            self.title = title
            self.sessionID = sessionID
        }
    }

    /// A pending `agent_actions` row the project's session proposed.
    package struct PendingAction: Codable, Equatable, Sendable {
        package let id: Int64
        package let tool: String
        package let summary: String

        package init(id: Int64, tool: String, summary: String) {
            self.id = id
            self.tool = tool
            self.summary = summary
        }
    }

    package struct TargetState: Codable, Equatable, Sendable {
        package let title: String
        package let status: String

        package init(title: String, status: String) {
            self.title = title
            self.status = status
        }
    }

    /// One project's state at a poll. `questions` holds only the agent root
    /// comments past the previous watermark, `pendingActions` only the
    /// pending proposals past `lastActionID`; `ownerTouched` what the owner
    /// changed since the previous poll. All three are transient (`persisted`).
    package struct Snapshot: Codable, Equatable, Sendable {
        package var projectID: Int64
        package var projectName: String
        package var lastAgentCommentID: Int64
        /// The highest `agent_actions` id bound to this project at the poll.
        package var lastActionID: Int64
        package var pendingActions: [PendingAction]
        package var questions: [Question]
        package var targets: [Int64: TargetState]
        /// The open asks by id. An ask is announced when its id first shows.
        package var openAsks: [Int64: OpenAsk]
        /// False for a snapshot persisted before asks existed: which asks it
        /// had seen is unknown, so none is announced from it (the `reviewKnown`
        /// precedent). Not encoded — every snapshot written now knows.
        package var asksKnown: Bool
        package var ownerTouched: Set<WorkbenchSubject>

        package init(
            projectID: Int64,
            projectName: String,
            lastAgentCommentID: Int64,
            questions: [Question],
            targets: [Int64: TargetState],
            ownerTouched: Set<WorkbenchSubject>,
            openAsks: [Int64: OpenAsk] = [:],
            asksKnown: Bool = true,
            lastActionID: Int64 = 0,
            pendingActions: [PendingAction] = []
        ) {
            self.projectID = projectID
            self.projectName = projectName
            self.lastAgentCommentID = lastAgentCommentID
            self.lastActionID = lastActionID
            self.pendingActions = pendingActions
            self.questions = questions
            self.targets = targets
            self.openAsks = openAsks
            self.asksKnown = asksKnown
            self.ownerTouched = ownerTouched
        }

        /// The baseline of a project just created in-app: everything after it counts.
        package static func empty(projectID: Int64, projectName: String) -> Self {
            Self(projectID: projectID, projectName: projectName, lastAgentCommentID: 0,
                 questions: [], targets: [:], ownerTouched: [])
        }

        package var persisted: Self {
            var copy = self
            copy.questions = []
            copy.pendingActions = []
            copy.ownerTouched = []
            return copy
        }

        private enum CodingKeys: String, CodingKey {
            case projectID, projectName, lastAgentCommentID, lastActionID, pendingActions
            case questions, targets, openAsks, ownerTouched
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            projectID = try c.decode(Int64.self, forKey: .projectID)
            projectName = try c.decode(String.self, forKey: .projectName)
            lastAgentCommentID = try c.decode(Int64.self, forKey: .lastAgentCommentID)
            // A snapshot persisted before proposals were watched has no
            // watermark: the first poll baselines instead of announcing every
            // pending proposal at once.
            lastActionID = try c.decodeIfPresent(Int64.self, forKey: .lastActionID) ?? Self.unknownActionWatermark
            pendingActions = try c.decodeIfPresent([PendingAction].self, forKey: .pendingActions) ?? []
            questions = try c.decode([Question].self, forKey: .questions)
            // A snapshot persisted before asks still carries its retired
            // `documents` key; it is ignored.
            targets = try c.decode([Int64: TargetState].self, forKey: .targets)
            let asks = try c.decodeIfPresent([Int64: OpenAsk].self, forKey: .openAsks)
            openAsks = asks ?? [:]
            asksKnown = asks != nil
            ownerTouched = try c.decode(Set<WorkbenchSubject>.self, forKey: .ownerTouched)
        }

        /// The watermark of a snapshot persisted before proposals were
        /// watched: no edge is read from it.
        package static let unknownActionWatermark: Int64 = -1
    }

    package static func decide(previous: Snapshot, current: Snapshot) -> [WorkbenchNotice] {
        [
            coalesce(questions(previous, current), kind: .agentAsks, in: current),
            coalesce(openedAsks(previous, current), kind: .askOpened, in: current),
            coalesce(doneTargets(previous, current), kind: .targetDone, in: current),
            coalesce(proposedActions(previous, current), kind: .actionAwaitsApproval, in: current)
        ].flatMap { $0 }
    }

    // MARK: - Events

    private static func questions(_ previous: Snapshot, _ current: Snapshot) -> [WorkbenchNotice] {
        current.questions.filter { $0.id > previous.lastAgentCommentID }.map { question in
            notice(.agentAsks, current,
                   title: "Agent asks on \(question.targetTitle)",
                   body: "\(current.projectName): \(question.body.prefix(200))",
                   route: WorkbenchRoute(projectID: current.projectID, pane: .board, subjectID: question.targetID),
                   key: "\(question.id)")
        }
    }

    /// An ask open now that the previous poll did not see. The owner's
    /// answer only closes asks, so it is never announced.
    private static func openedAsks(_ previous: Snapshot, _ current: Snapshot) -> [WorkbenchNotice] {
        guard previous.asksKnown else { return [] }
        return current.openAsks.sorted { $0.key < $1.key }.compactMap { id, ask in
            guard previous.openAsks[id] == nil else { return nil }
            // The session it was filed from; one filed outside the app has
            // none, so it lands on the board (the asks stack sits beside it).
            let route = ask.sessionID.map {
                WorkbenchRoute(projectID: current.projectID, pane: .terminal, subjectID: $0, askID: id)
            } ?? WorkbenchRoute(projectID: current.projectID, pane: .board, askID: id)
            return notice(.askOpened, current, title: "Агент просит: \(ask.title)", body: current.projectName,
                          route: route, key: "\(id)")
        }
    }

    private static func doneTargets(_ previous: Snapshot, _ current: Snapshot) -> [WorkbenchNotice] {
        current.targets.sorted { $0.key < $1.key }.compactMap { id, target in
            guard target.status == "done", let before = previous.targets[id], before.status != "done",
                  !current.ownerTouched.contains(.target(id)) else { return nil }
            return notice(.targetDone, current,
                          title: "\(target.title) done", body: current.projectName,
                          route: WorkbenchRoute(projectID: current.projectID, pane: .board, subjectID: id),
                          key: "\(id)")
        }
    }

    /// A proposal the workbench session filed since the previous poll that
    /// still waits for the owner. The card lives in the Inbox → Actions strip.
    private static func proposedActions(_ previous: Snapshot, _ current: Snapshot) -> [WorkbenchNotice] {
        guard previous.lastActionID != Snapshot.unknownActionWatermark else { return [] }
        return current.pendingActions.filter { $0.id > previous.lastActionID }.map { action in
            notice(.actionAwaitsApproval, current,
                   title: "\(ReactionToolCatalog.title(for: action.tool)) awaits your approval",
                   body: "\(current.projectName): \(action.summary.prefix(200))",
                   route: WorkbenchRoute(projectID: current.projectID, pane: .board),
                   key: "\(action.id)")
        }
    }

    // MARK: - Shaping

    private static func coalesce(_ notices: [WorkbenchNotice], kind: WorkbenchNoticeKind, in snapshot: Snapshot) -> [WorkbenchNotice] {
        guard notices.count >= coalesceThreshold else { return notices }
        return [notice(kind, snapshot,
                       title: summaryTitle(kind, count: notices.count), body: snapshot.projectName,
                       route: WorkbenchRoute(projectID: snapshot.projectID, pane: .board),
                       key: "summary-" + notices.map(\.identifier).joined(separator: ",").hashValueString)]
    }

    private static func summaryTitle(_ kind: WorkbenchNoticeKind, count: Int) -> String {
        switch kind {
        case .agentAsks: "\(count) agent questions"
        // The asks stack's own header (spec 2026-10-03 Part 8).
        case .askOpened: "Ждёт тебя \(count)"
        case .targetDone: "\(count) targets done"
        case .actionAwaitsApproval: "\(count) proposals await your approval"
        }
    }

    private static func notice(
        _ kind: WorkbenchNoticeKind, _ snapshot: Snapshot, title: String, body: String, route: WorkbenchRoute, key: String
    ) -> WorkbenchNotice {
        WorkbenchNotice(kind: kind, projectID: snapshot.projectID, title: title, body: body, route: route,
                        identifier: "project-\(snapshot.projectID)-\(kind.rawValue)-\(key)")
    }
}

private extension String {
    /// A short, stable (FNV-1a) digest — Swift's `hashValue` is seeded per
    /// process and would give every relaunch a new identifier.
    var hashValueString: String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
