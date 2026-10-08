import Foundation
import WatchtowerKit

/// Everything the session detail draws (spec §4.8, §4.9, §13 B3): the
/// header, the session's open asks, the report and the timeline. Built from
/// the published records only; the session's transcript and terminal text
/// never reach the phone (I-4), so nothing here can hold them.
struct SessionDetailModel {
    let id: Int64
    let title: String
    /// Dot, glyph and caption exactly as the Mac resolved them.
    let state: SessionRowModel
    /// The session's board target; nil without one.
    let target: TargetChip?
    /// The target's branch, else the workbench's; nil when neither has one.
    let branch: String?
    /// "Claude Code · 41m": the agent and the session's age.
    let agentLine: String
    /// "Needs approval on the Mac": the phone never answers a permission
    /// prompt (PROJ-16).
    let approvalNotice: String?
    /// The session's open asks, newest first.
    let asks: [WaitingCardModel]
    /// "since 15m": the oldest open ask's age; nil without asks.
    let asksSince: String?
    /// nil until the hub has published a report for the session.
    let report: SessionReportSection?
    /// Newest first.
    let timeline: [MilestoneRow]
    let timelineEmptyText: String?
    /// "N earlier on your Mac" past the hub's 100-milestone cap.
    let timelineMoreText: String?

    struct TargetChip: Equatable {
        let id: Int64
        let label: String
    }

    init?(
        sessionID: Int64,
        snapshot: WorkbenchReplicaSnapshot,
        report: SessionReport?,
        timeline: SessionTimeline?,
        now: Date,
        calendar: Calendar = .current
    ) {
        guard let session = snapshot.session(sessionID) else { return nil }
        id = session.id
        title = session.title
        state = SessionRowModel(session, now: now)
        let targetRecord = session.targetID.flatMap { id in snapshot.targets.first { $0.id == id } }
        target = session.targetID.map { id in
            TargetChip(id: id, label: targetRecord.map { "#\(id) \($0.text)" } ?? "#\(id)")
        }
        branch = Self.branch(target: targetRecord, workbench: snapshot.workbench(session.workbenchID))
        let agent = session.agent == .claudeCode ? "Claude Code" : session.agent.rawValue
        agentLine = "\(agent) · \(CompactAge.string(from: session.createdAt, now: now))"
        approvalNotice = session.stateKind == .needsApproval ? "Needs approval on the Mac" : nil

        let openAsks = snapshot.asks
            .filter { $0.status == .open && $0.sessionID == sessionID }
            .sorted(by: WorkbenchReplicaSnapshot.newestFirst)
        asks = openAsks.map { WaitingCardModel($0, snapshot: snapshot, now: now) }
        asksSince = openAsks.last.map { "since \(CompactAge.string(from: $0.createdAt, now: now))" }

        self.report = report.map { SessionReportSection($0, finishSummary: session.finishSummary) }

        let milestones = (timeline?.milestones ?? []).sorted { $0.at > $1.at }
        let targetIDs = Set(snapshot.targets.map(\.id))
        self.timeline = milestones.enumerated().map { index, milestone in
            MilestoneRow(index: index, milestone: milestone, knownTargets: targetIDs, now: now, calendar: calendar)
        }
        timelineEmptyText = milestones.isEmpty ? "No milestones yet" : nil
        timelineMoreText = (timeline?.milestonesMore).flatMap { $0 > 0 ? "\($0) earlier on your Mac" : nil }
    }

    private static func branch(target: WorkbenchTarget?, workbench: Workbench?) -> String? {
        if let branch = target?.branch, !branch.isEmpty {
            return branch
        }
        guard let workbench else { return nil }
        if workbench.detached {
            return "detached"
        }
        return workbench.branch.isEmpty ? nil : workbench.branch
    }

    var toneUses: [ToneUse] {
        var uses = state.toneUses
        if approvalNotice != nil {
            uses.append(ToneUse(element: "session \(id) approval notice", tone: .waitingForYou, role: .waiting))
        }
        uses += asks.map(\.toneUse)
        uses += report?.segments.map { ToneUse(element: "session \(id) report \($0.label)", tone: $0.tone, role: .progress) } ?? []
        uses += timeline.map { ToneUse(element: "session \(id) milestone \($0.id)", tone: $0.tone, role: $0.role) }
        return uses
    }
}

/// The report card: progress segments, a short summary and the PRs.
struct SessionReportSection: Equatable {
    /// "2 / 7 targets".
    let progressLabel: String
    let segments: [ProgressSegment]
    /// "2 of 7 targets done, 1 in progress".
    let accessibilityLabel: String
    /// The finish summary of a finished session; otherwise "Now: …" and
    /// "Next: …".
    let summary: [String]
    /// "PR #175 open", "feature/x · no PR".
    let prLines: [String]

    /// Up to this many targets draw one segment each; more draw one segment
    /// per run, sized by its count.
    static let maxSingleSegments = 24

    init(_ report: SessionReport, finishSummary: String) {
        let total = max(0, report.progress.total)
        let done = min(total, max(0, report.progress.done))
        var left = total - done
        func take(_ status: String) -> Int {
            let count = min(left, report.now.filter { $0.status == status }.count)
            left -= count
            return count
        }
        let inProgress = take("in_progress")
        let inReview = take("in_review")
        let blocked = take("blocked")
        let runs: [(amount: Int, label: String, tone: PhoneTone)] = [
            (done, "done", .green),
            (inProgress, "in progress", .accent),
            (inReview, "in review", .accent),
            (blocked, "blocked", .red),
            (left, "to do", .secondary)
        ].filter { $0.amount > 0 }

        progressLabel = "\(done) / \(total) targets"
        if total <= Self.maxSingleSegments {
            segments = runs.flatMap { run in
                Array(repeating: (run.label, run.tone), count: run.amount)
            }
            .enumerated()
            .map { ProgressSegment(id: $0.offset, label: $0.element.0, tone: $0.element.1, weight: 1) }
        } else {
            segments = runs.enumerated().map { index, run in
                ProgressSegment(id: index, label: "\(run.amount) \(run.label)", tone: run.tone, weight: run.amount)
            }
        }
        accessibilityLabel = (["\(done) of \(total) targets done"]
            + runs.filter { !["done", "to do"].contains($0.label) }.map { "\($0.amount) \($0.label)" })
            .joined(separator: ", ")

        let finished = finishSummary.isEmpty ? report.session.finishSummary : finishSummary
        if !finished.isEmpty {
            summary = [finished]
        } else {
            summary = [
                Self.line("Now", report.now.map(\.text), more: report.nowMore),
                Self.line("Next", report.next.map(\.text), more: report.nextMore)
            ].compactMap { $0 }
        }
        prLines = report.prs.map { pr in
            if let number = pr.prNumber {
                return "PR #\(number) \(pr.state)"
            }
            let branch = pr.ref.hasPrefix("branch:") ? String(pr.ref.dropFirst("branch:".count)) : pr.ref
            return "\(branch) · no PR"
        }
    }

    /// "Now: A; B; C +2", the first three entries; nil without entries.
    private static func line(_ name: String, _ texts: [String], more: Int?) -> String? {
        guard !texts.isEmpty else { return nil }
        let hidden = texts.count - min(3, texts.count) + (more ?? 0)
        return "\(name): " + texts.prefix(3).joined(separator: "; ") + (hidden > 0 ? " +\(hidden)" : "")
    }
}

/// One segment of the report's progress bar.
struct ProgressSegment: Equatable, Identifiable {
    let id: Int
    /// "done", "in progress", … or, for a run, "30 done".
    let label: String
    let tone: PhoneTone
    /// The segment's share of the bar.
    let weight: Int
}

/// One timeline row: time, dot and the hub's text as published.
struct MilestoneRow: Equatable, Identifiable {
    let id: Int
    let at: Date
    /// "13:06" today, "8 Oct" before.
    let time: String
    let text: String
    let tone: PhoneTone
    let role: ToneRole
    /// The board target the row opens; nil when it is about none (or an
    /// ask, which opens with the answer flow).
    let targetID: Int64?
    let accessibilityLabel: String

    init(index: Int, milestone: SessionTimeline.Milestone, knownTargets: Set<Int64>, now: Date, calendar: Calendar) {
        id = index
        at = milestone.at
        time = calendar.isDate(milestone.at, inSameDayAs: now)
            ? milestone.at.formatted(.dateTime.hour().minute())
            : milestone.at.formatted(.dateTime.day().month(.abbreviated))
        text = milestone.text
        switch milestone.kind {
        case .askOpened:
            tone = .waitingForYou
            role = .ask
        case .finished:
            tone = .blue
            role = .status
        case .targetLinked, .targetStatus, .phase, .pr:
            tone = .accent
            role = .info
        default:
            tone = .secondary
            role = .info
        }
        let isTargetKind = [.targetLinked, .targetStatus, .phase].contains(milestone.kind)
        targetID = isTargetKind ? milestone.ref.flatMap { knownTargets.contains($0) ? $0 : nil } : nil
        accessibilityLabel = "\(time), \(milestone.text)"
    }
}
