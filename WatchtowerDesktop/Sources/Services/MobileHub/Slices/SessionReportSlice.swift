import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// The `session_report` slice (mobile POC spec §4.8), record name
/// `session_report-<terminal_sessions.id>`: the output of
/// `watchtower workbench session-report --workbench N --session S --json`
/// (Go `internal/sessionreport.Report`), capped. `SessionReportRunner` runs
/// the CLI and stores each session's capped payload in the sidecar
/// (`session_reports`), so a hub restart publishes the last good report
/// instead of deleting the record until the next run; this source only
/// publishes the stored payloads of the sessions in the window.
///
/// **Window:** the `terminal_session` window's sessions that are live or
/// were active in the last 7 days.
///
/// **Caps:** `on_you` 30, `now` 20, `next` 20, `phases` 30 with ≤ 50 items
/// each, `prs` 10 (`<list>_more` for the rest); every free text 500 (no
/// per-text `_clipped`, the Kit mirror has none); the whole payload
/// ≤ 128 KiB, dropping phase items oldest phase first (a phase not started
/// yet counts as the newest) and setting
/// `phases_clipped`.
///
/// Wire shape: the Kit mirror `WatchtowerKit.SessionReport`.
struct SessionReportSlice: SliceSource {
    let kind = SliceKind.sessionReport

    static let activeWindow: TimeInterval = 7 * 86_400
    static let maxPayloadBytes = 128 * 1024
    static let maxText = 500
    static let maxOnYou = 30
    static let maxNow = 20
    static let maxNext = 20
    static let maxPhases = 30
    static let maxPhaseItems = 50
    static let maxPRs = 10

    let sessions: TerminalSessionSlice
    let sidecar: HubSyncState
    let now: @Sendable () -> Date

    init(sessions: TerminalSessionSlice, sidecar: HubSyncState, now: @escaping @Sendable () -> Date = { Date() }) {
        self.sessions = sessions
        self.sidecar = sidecar
        self.now = now
    }

    func records(_ db: Database) throws -> [SliceRecord] {
        let window = try Self.window(db, sessions: sessions, now: now())
        guard !window.isEmpty else { return [] }
        let stored = try sidecar.sessionReports()
        return window.compactMap { session in
            guard let report = stored[session.sessionID] else { return nil }
            return SliceRecord(kind: kind, id: String(session.sessionID), modifiedAt: report.fetchedAt, payload: report.payload)
        }
    }

    // MARK: - Window

    /// One session of the report window, with the Mac's resolved state.
    struct Windowed: Equatable, Sendable {
        let sessionID: Int64
        let workbenchID: Int64
        let live: Bool
        let createdAt: Date?
        let lastActiveAt: Date
        let state: SessionSwitcherPresentation.State
        /// When the current state was reported (`TerminalSessionSlice.stateAt`).
        let stateAt: Date?
    }

    /// The `terminal_session` window's sessions that are live or had
    /// `last_active_at` in the last 7 days (the window of both
    /// `session_report` and `session_timeline`).
    static func window(_ db: Database, sessions: TerminalSessionSlice, now: Date) throws -> [Windowed] {
        let cutoff = now.addingTimeInterval(-activeWindow)
        return try sessions.publishedSessions(db).compactMap { item in
            let lastActive = SliceDate.parse(item.session.lastActiveAt) ?? Date(timeIntervalSince1970: 0)
            guard item.state.live || lastActive >= cutoff else { return nil }
            return Windowed(
                sessionID: item.session.id,
                workbenchID: item.workbenchID,
                live: item.state.live,
                createdAt: SliceDate.parse(item.session.createdAt),
                lastActiveAt: lastActive,
                state: item.state,
                stateAt: TerminalSessionSlice.stateAt(item)
            )
        }
    }

    // MARK: - Payload

    /// The capped report. Keys are the CLI's own snake_case keys; nil
    /// optionals are omitted.
    struct Payload: Codable, Equatable, Sendable {
        var session: Session
        var progress: Progress
        var onYou: [Ask]
        var onYouMore: Int?
        var now: [NowItem]
        var nowMore: Int?
        var next: [Item]
        var nextMore: Int?
        var phases: [Phase]
        var phasesMore: Int?
        var phasesClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        var prs: [PullRequest]
        var prsMore: Int?
        var prNote: String

        enum CodingKeys: String, CodingKey {
            case session, progress, now, next, phases, prs
            case onYou = "on_you"
            case onYouMore = "on_you_more"
            case nowMore = "now_more"
            case nextMore = "next_more"
            case phasesMore = "phases_more"
            case phasesClipped = "phases_clipped"
            case prsMore = "prs_more"
            case prNote = "pr_note"
        }

        struct Session: Codable, Equatable, Sendable {
            let id: Int64
            let title: String
            let targetID: Int64?
            let kind: String
            let createdAt: String
            let lastActiveAt: String
            let agentState: String
            let agentStateAt: String
            let finishedAt: String
            let finishSummary: String

            enum CodingKeys: String, CodingKey {
                case id, title, kind
                case targetID = "target_id"
                case createdAt = "created_at"
                case lastActiveAt = "last_active_at"
                case agentState = "agent_state"
                case agentStateAt = "agent_state_at"
                case finishedAt = "finished_at"
                case finishSummary = "finish_summary"
            }
        }

        struct Progress: Codable, Equatable, Sendable {
            let done: Int
            let total: Int
        }

        struct Ask: Codable, Equatable, Sendable {
            let id: Int64
            let kind: String
            let title: String
            let targetID: Int64?
            let createdAt: String

            enum CodingKeys: String, CodingKey {
                case id, kind, title
                case targetID = "target_id"
                case createdAt = "created_at"
            }
        }

        struct Item: Codable, Equatable, Sendable {
            let id: Int64
            let text: String
            let status: String
        }

        struct NowItem: Codable, Equatable, Sendable {
            let id: Int64
            let text: String
            let status: String
            let branch: String
            let since: String
        }

        struct Phase: Codable, Equatable, Sendable {
            let targetID: Int64
            let text: String
            let done: Int
            let total: Int
            let startedAt: String
            let finishedAt: String
            var items: [Item]
            var itemsMore: Int?

            enum CodingKeys: String, CodingKey {
                case text, done, total, items
                case targetID = "target_id"
                case startedAt = "started_at"
                case finishedAt = "finished_at"
                case itemsMore = "items_more"
            }
        }

        struct PullRequest: Codable, Equatable, Sendable {
            let ref: String
            let prNumber: Int64?
            let title: String
            let state: String
            let additions: Int64?
            let deletions: Int64?
            let mergedAt: String
            let checkedAt: String
            let targets: [Int64]

            enum CodingKeys: String, CodingKey {
                case ref, title, state, additions, deletions, targets
                case prNumber = "pr_number"
                case mergedAt = "merged_at"
                case checkedAt = "checked_at"
            }
        }
    }

    private static let logger = Logger(subsystem: Constants.bundleID, category: "SessionReportSlice")

    /// Sorted keys, so an unchanged report encodes to the same bytes (the
    /// stored payload and the publisher's hash compare bytes).
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The stored payload read back (the timeline's phases and PRs).
    static func decode(_ data: Data) throws -> Payload {
        try JSONDecoder().decode(Payload.self, from: data)
    }

    /// The CLI's report capped for the wire: the list and text caps, then
    /// the 128 KiB payload cap.
    static func encode(_ report: SessionReport) throws -> Data {
        var payload = capped(report)
        return try fit(&payload, limit: maxPayloadBytes)
    }

    /// The list and text caps.
    static func capped(_ report: SessionReport) -> Payload {
        let onYou = SliceClip.list(report.onYou, limit: maxOnYou)
        let now = SliceClip.list(report.now, limit: maxNow)
        let next = SliceClip.list(report.next, limit: maxNext)
        let phases = SliceClip.list(report.phases, limit: maxPhases)
        let prs = SliceClip.list(report.prs, limit: maxPRs)
        let session = report.session
        return Payload(
            session: .init(
                id: session.id, title: text(session.title), targetID: session.targetID, kind: session.kind,
                createdAt: session.createdAt, lastActiveAt: session.lastActiveAt, agentState: session.agentState,
                agentStateAt: session.agentStateAt, finishedAt: session.finishedAt, finishSummary: text(session.finishSummary)
            ),
            progress: .init(done: report.progress.done, total: report.progress.total),
            onYou: onYou.items.map {
                .init(id: $0.id, kind: $0.kind, title: text($0.title), targetID: $0.targetID, createdAt: $0.createdAt)
            },
            onYouMore: onYou.more,
            now: now.items.map {
                .init(id: $0.id, text: text($0.text), status: $0.status, branch: text($0.branch), since: $0.since)
            },
            nowMore: now.more,
            next: next.items.map(item),
            nextMore: next.more,
            phases: phases.items.map { phase in
                let items = SliceClip.list(phase.items, limit: maxPhaseItems)
                return .init(
                    targetID: phase.targetID, text: text(phase.text), done: phase.done, total: phase.total,
                    startedAt: phase.startedAt, finishedAt: phase.finishedAt, items: items.items.map(item), itemsMore: items.more
                )
            },
            phasesMore: phases.more,
            phasesClipped: nil,
            prs: prs.items.map {
                .init(
                    ref: text($0.ref), prNumber: $0.prNumber, title: text($0.title), state: $0.state, additions: $0.additions,
                    deletions: $0.deletions, mergedAt: $0.mergedAt, checkedAt: $0.checkedAt, targets: $0.targets
                )
            },
            prsMore: prs.more,
            prNote: text(report.prNote)
        )
    }

    /// Encodes `payload`, dropping phase items (oldest phase first, a
    /// phase's last items first) and then whole phases until it fits in
    /// `limit` bytes; `phases_clipped` is set once anything was dropped.
    /// A payload that does not fit without any phase is logged and returned
    /// as it is (the publisher's 900 000-byte guard still applies).
    static func fit(_ payload: inout Payload, limit: Int) throws -> Data {
        let encoder = encoder()
        var data = try encoder.encode(payload)
        while data.count > limit {
            var excess = data.count - limit
            for index in oldestFirst(payload.phases) where excess > 0 {
                while excess > 0, let last = payload.phases[index].items.last {
                    excess -= try encoder.encode(last).count + 1
                    payload.phases[index].items.removeLast()
                    payload.phases[index].itemsMore = (payload.phases[index].itemsMore ?? 0) + 1
                }
            }
            if excess > 0 {
                // No item left to drop: the oldest phase goes whole.
                guard let oldest = oldestFirst(payload.phases).first else {
                    let (id, size) = (payload.session.id, data.count)
                    logger.warning("session report \(id) is \(size) bytes without phases; published as is")
                    return data
                }
                payload.phases.remove(at: oldest)
                payload.phasesMore = (payload.phasesMore ?? 0) + 1
            }
            payload.phasesClipped = true
            data = try encoder.encode(payload)
        }
        return data
    }

    /// Phase indices, oldest first: by `started_at`, then board order. A
    /// phase not started yet ("") counts as the newest, so its items go last.
    private static func oldestFirst(_ phases: [Payload.Phase]) -> [Int] {
        phases.indices.sorted { lhs, rhs in
            let left = phases[lhs].startedAt
            let right = phases[rhs].startedAt
            guard left != right else { return lhs < rhs }
            if left.isEmpty { return false }
            if right.isEmpty { return true }
            return left < right
        }
    }

    private static func item(_ item: SessionReport.Item) -> Payload.Item {
        .init(id: item.id, text: text(item.text), status: item.status)
    }

    private static func text(_ value: String) -> String {
        SliceClip.text(value, limit: maxText).text
    }
}
