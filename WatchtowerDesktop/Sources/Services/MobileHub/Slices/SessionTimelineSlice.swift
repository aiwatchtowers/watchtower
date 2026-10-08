import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// The `session_timeline` slice (mobile POC spec §4.9), record name
/// `session_timeline-<terminal_sessions.id>`: a session's milestones, newest
/// first, at most 100 (`milestones_more` for the rest), each `{at, kind,
/// text ≤ 200, ref}` with `ref` a target or ask id. Same window as
/// `session_report`; a session with no milestone still gets its record with
/// an empty list. Sources:
/// - `state`: the hub-observed transitions in the sidecar's
///   `session_milestones` (`SessionReportRunner`);
/// - `ask_opened` / `ask_answered` / `ask_withdrawn`: the session's
///   `owner_asks` (`created_at`, `answered_at`; a withdrawal has no stamp of
///   its own, so it takes the superseding ask's `created_at`, else the ask's);
/// - `target_linked`: `terminal_session_targets.first_at`;
/// - `target_status`: `target_status_history` of the linked targets (and the
///   session's own target) from the session's `created_at` on;
/// - `phase` and `pr`: the stored session report's phases and PRs;
/// - `finished`: `finished_at` with `finish_summary`.
///
/// No subagent events (OD-3: no stored source) and never the transcript or
/// terminal text (I-4).
///
/// Wire shape: the Kit mirror `WatchtowerKit.SessionTimeline`.
struct SessionTimelineSlice: SliceSource {
    let kind = SliceKind.sessionTimeline

    static let maxMilestones = 100
    static let maxText = 200
    private static let logger = Logger(subsystem: Constants.bundleID, category: "SessionTimelineSlice")

    let sessions: TerminalSessionSlice
    let sidecar: HubSyncState
    let now: @Sendable () -> Date

    init(sessions: TerminalSessionSlice, sidecar: HubSyncState, now: @escaping @Sendable () -> Date = { Date() }) {
        self.sessions = sessions
        self.sidecar = sidecar
        self.now = now
    }

    /// The wire milestone kinds this hub writes (the Kit's
    /// `SessionTimeline.Milestone.Kind` values).
    enum MilestoneKind: String, CaseIterable {
        case state
        case askOpened = "ask_opened"
        case askAnswered = "ask_answered"
        case askWithdrawn = "ask_withdrawn"
        case targetLinked = "target_linked"
        case targetStatus = "target_status"
        case phase, pr, finished
    }

    struct Milestone: Encodable, Equatable {
        let at: Date
        let kind: String
        let text: String
        let textClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let ref: Int64?
    }

    struct Payload: Encodable, Equatable {
        let sessionID: Int64
        let milestones: [Milestone]
        let milestonesMore: Int?

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case milestones, milestonesMore
        }
    }

    /// One milestone before the cap and the clip.
    struct Raw: Equatable {
        let at: Date
        let kind: MilestoneKind
        let text: String
        var ref: Int64?
    }

    func records(_ db: Database) throws -> [SliceRecord] {
        let window = try SessionReportSlice.window(db, sessions: sessions, now: now())
        guard !window.isEmpty else { return [] }
        let states = try sidecar.stateMilestones()
        let reports = try sidecar.sessionReports()
        let encoder = RelayCoder.makeEncoder()
        return try window.map { session in
            var raw = states[session.sessionID, default: []].map { Raw(at: $0.at, kind: .state, text: $0.text) }
            raw += try Self.rowMilestones(db, session: session)
            if let stored = reports[session.sessionID] {
                raw += reportMilestones(stored.payload, sessionID: session.sessionID)
            }
            let payload = Self.payload(sessionID: session.sessionID, raw)
            return SliceRecord(
                kind: kind, id: String(session.sessionID), modifiedAt: payload.milestones.first?.at ?? session.lastActiveAt,
                payload: try encoder.encode(payload)
            )
        }
    }

    /// Newest first (ties keep their source order), the newest 100, texts
    /// clipped at 200.
    static func payload(sessionID: Int64, _ raw: [Raw]) -> Payload {
        let ordered = raw.enumerated()
            .sorted { lhs, rhs in lhs.element.at == rhs.element.at ? lhs.offset < rhs.offset : lhs.element.at > rhs.element.at }
            .map(\.element)
        let capped = SliceClip.list(ordered, limit: maxMilestones)
        return Payload(
            sessionID: sessionID,
            milestones: capped.items.map { item in
                let text = SliceClip.text(item.text, limit: maxText)
                return Milestone(at: item.at, kind: item.kind.rawValue, text: text.text, textClipped: text.clipped, ref: item.ref)
            },
            milestonesMore: capped.more
        )
    }

    /// The text of a resolved state's milestone; nil for a session that was
    /// never started (no milestone).
    static func stateText(_ state: SessionSwitcherPresentation.State) -> String? {
        switch state.kind {
        case .running: "Started"
        case .working: "Working"
        case .waitingOnAsk: "Waiting for you"
        case .needsApproval: "Needs approval"
        case .finished: "Finished"
        case .stopped: "Stopped"
        // "Error: rate limit", or "Stopped on an error".
        case .failed: SessionStatePresentation.caption(for: state)
        case .notStarted: nil
        }
    }

    // MARK: - Main DB sources

    static func rowMilestones(_ db: Database, session: SessionReportSlice.Windowed) throws -> [Raw] {
        try askMilestones(db, sessionID: session.sessionID)
            + linkAndStatusMilestones(db, session: session)
            + finishedMilestone(db, sessionID: session.sessionID)
    }

    private static func askMilestones(_ db: Database, sessionID: Int64) throws -> [Raw] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT a.id, a.title, a.status, a.withdrawn_reason, a.created_at, a.answered_at,
                   (SELECT MIN(n.created_at) FROM owner_asks n WHERE n.previous_ask_id = a.id) AS superseded_at
            FROM owner_asks a WHERE a.session_id = ? ORDER BY a.id
            """, arguments: [sessionID])
        var out: [Raw] = []
        for row in rows {
            let id: Int64 = row["id"]
            let title: String = row["title"] ?? ""
            let created = SliceDate.parse(row["created_at"] ?? "")
            if let created { out.append(Raw(at: created, kind: .askOpened, text: "Asked: \(title)", ref: id)) }
            if let answered = SliceDate.parse(row["answered_at"] ?? "") {
                out.append(Raw(at: answered, kind: .askAnswered, text: "Answered: \(title)", ref: id))
            }
            if (row["status"] as String?) == "withdrawn",
               let at = SliceDate.parse(row["superseded_at"] ?? "") ?? created {
                let reason: String = row["withdrawn_reason"] ?? ""
                let text = reason == "superseded" ? "Superseded: \(title)" : "Withdrawn: \(title)"
                out.append(Raw(at: at, kind: .askWithdrawn, text: text, ref: id))
            }
        }
        return out
    }

    /// `target_linked` per link row, and `target_status` for each status
    /// move of a linked target (or the session's own) at or after the
    /// session's `created_at`.
    private static func linkAndStatusMilestones(_ db: Database, session: SessionReportSlice.Windowed) throws -> [Raw] {
        let links = try Row.fetchAll(db, sql: """
            SELECT l.target_id, l.first_at, t.text FROM terminal_session_targets l
            JOIN targets t ON t.id = l.target_id
            WHERE l.session_id = ? ORDER BY l.first_at, l.target_id
            """, arguments: [session.sessionID])
        var out: [Raw] = links.compactMap { row in
            guard let at = SliceDate.parse(row["first_at"] ?? "") else { return nil }
            let text: String = row["text"] ?? ""
            return Raw(at: at, kind: .targetLinked, text: "Linked: \(text)", ref: row["target_id"])
        }
        guard let created = session.createdAt else { return out }
        let history = try Row.fetchAll(db, sql: """
            SELECT h.target_id, h.from_status, h.to_status, h.actor, h.changed_at FROM target_status_history h
            WHERE h.target_id IN (
                SELECT target_id FROM terminal_session_targets WHERE session_id = ?1
                UNION SELECT target_id FROM terminal_sessions WHERE id = ?1 AND target_id IS NOT NULL
            )
            ORDER BY h.changed_at, h.id
            """, arguments: [session.sessionID])
        for row in history {
            guard let at = SliceDate.parse(row["changed_at"] ?? ""), at >= created else { continue }
            let from: String = row["from_status"] ?? "new"
            let target: String = row["to_status"] ?? ""
            let actor: String = row["actor"] ?? ""
            out.append(Raw(at: at, kind: .targetStatus, text: "\(from) → \(target) (\(actor))", ref: row["target_id"]))
        }
        return out
    }

    private static func finishedMilestone(_ db: Database, sessionID: Int64) throws -> [Raw] {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT finished_at, finish_summary FROM terminal_sessions WHERE id = ?", arguments: [sessionID]
        ), let at = SliceDate.parse(row["finished_at"] ?? "") else { return [] }
        let summary: String = row["finish_summary"] ?? ""
        return [Raw(at: at, kind: .finished, text: summary.isEmpty ? "Finished" : "Finished: \(summary)", ref: nil)]
    }

    // MARK: - Report sources

    /// `phase` at each phase's `started_at` and `finished_at`, `pr` at each
    /// pull request's `merged_at`, else `checked_at` (branch entries have no
    /// PR and no milestone).
    private func reportMilestones(_ data: Data, sessionID: Int64) -> [Raw] {
        let report: SessionReportSlice.Payload
        do {
            report = try SessionReportSlice.decode(data)
        } catch {
            // Written by this build's own encoder; unreadable only after a
            // format change, and rewritten by the session's next run.
            Self.logger.warning(
                "stored session report of \(sessionID) is unreadable: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
        var out: [Raw] = []
        for phase in report.phases {
            if let started = SliceDate.parse(phase.startedAt) {
                out.append(Raw(at: started, kind: .phase, text: "Started: \(phase.text)", ref: phase.targetID))
            }
            if let finished = SliceDate.parse(phase.finishedAt) {
                out.append(Raw(at: finished, kind: .phase, text: "Done: \(phase.text)", ref: phase.targetID))
            }
        }
        for pr in report.prs {
            guard let number = pr.prNumber,
                  let at = SliceDate.parse(pr.mergedAt) ?? SliceDate.parse(pr.checkedAt) else { continue }
            let title = pr.title.isEmpty ? "" : ": \(pr.title)"
            out.append(Raw(at: at, kind: .pr, text: "PR #\(number) \(pr.state)\(title)", ref: pr.targets.first))
        }
        return out
    }
}
