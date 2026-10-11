import Foundation
import WatchtowerKit

/// One SESSIONS row (spec §4.5): dot, glyph and label are the Mac's resolved
/// presentation, drawn as given (PROJ-11 stays on the Mac).
struct SessionRowModel: Equatable, Identifiable {
    let id: Int64
    let title: String
    /// The Mac's caption; a session that is not live adds its age
    /// ("Stopped · 3h").
    let caption: String
    let tone: PhoneTone
    /// An SF Symbol name; nil when the Mac sent none.
    let glyph: String?
    let isRing: Bool
    /// `#<target> · <done>/<total> · <pr line>`; nil until the hub's first
    /// report run names a target.
    let reportLine: String?
    /// done/total; nil without a total.
    let reportProgress: Double?
    let openAsks: Int
    /// "▸ N closed"; nil without closed asks.
    let closedLabel: String?
    let openAsksTone = PhoneTone.waitingForYou
    let progressTone = PhoneTone.green
    /// The Mac's orange states plus a session with open asks (finished with
    /// open asks): the only sessions whose orange is a waiting element.
    private let isWaiting: Bool

    init(_ session: TerminalSessionState, now: Date) {
        id = session.id
        title = session.title
        caption = session.live
            ? session.stateCaption
            : "\(session.stateCaption) · \(CompactAge.string(from: session.lastActiveAt, now: now))"
        tone = PhoneTone(session.stateTone)
        glyph = session.stateGlyph.isEmpty ? nil : session.stateGlyph
        isRing = session.isRing
        openAsks = session.openAsks
        closedLabel = session.closedAsks > 0 ? "▸ \(session.closedAsks) closed" : nil
        isWaiting = [.waitingOnAsk, .needsApproval].contains(session.stateKind) || session.openAsks > 0

        if let target = session.reportTargetID {
            var parts = ["#\(target)"]
            if let done = session.reportDone, let total = session.reportTotal {
                parts.append("\(done)/\(total)")
            }
            if let pr = session.reportPRLine, !pr.isEmpty {
                parts.append(pr)
            }
            reportLine = parts.joined(separator: " · ")
            if let done = session.reportDone, let total = session.reportTotal, total > 0 {
                reportProgress = min(1, Double(done) / Double(total))
            } else {
                reportProgress = nil
            }
        } else {
            reportLine = nil
            reportProgress = nil
        }
    }

    var toneUses: [ToneUse] {
        var uses = [
            ToneUse(element: "session \(id) dot", tone: tone, role: .session(isWaiting: isWaiting)),
            ToneUse(element: "session \(id) label", tone: tone, role: .session(isWaiting: isWaiting))
        ]
        if reportProgress != nil {
            uses.append(ToneUse(element: "session \(id) report progress", tone: progressTone, role: .progress))
        }
        if openAsks > 0 {
            uses.append(ToneUse(element: "session \(id) open asks", tone: openAsksTone, role: .ask))
        }
        return uses
    }
}

/// One Waiting-for-you card: REVIEW, ASK or CHECK, the title and
/// "Session · #target · age" (Now prefixes the workbench).
struct WaitingCardModel: Equatable, Identifiable {
    let id: Int64
    let kindLabel: String
    let title: String
    let subline: String
    /// Label, tint and border of the card.
    let tone = PhoneTone.waitingForYou

    init(_ ask: OwnerAsk, snapshot: WorkbenchReplicaSnapshot, now: Date, showWorkbench: Bool = false) {
        id = ask.id
        kindLabel = switch ask.kind {
        case .review: "REVIEW"
        case .check: "CHECK"
        case .question: "ASK"
        default: ask.kind.rawValue.uppercased()
        }
        title = ask.title
        var parts: [String] = []
        if showWorkbench {
            parts.append(ask.workbenchName)
        }
        if let sessionID = ask.sessionID, let session = snapshot.session(sessionID) {
            parts.append(session.title)
        }
        if let target = ask.targetID {
            parts.append("#\(target)")
        }
        parts.append(CompactAge.string(from: ask.createdAt, now: now))
        subline = parts.joined(separator: " · ")
    }

    var toneUse: ToneUse {
        ToneUse(element: "ask \(id) card", tone: tone, role: .ask)
    }
}

/// The board's counts as one line: "3 in progress · 3 todo · 1 blocked ·
/// 1 done". "todo" is the open targets that are neither in progress nor
/// blocked (in review counts there too).
enum BoardCounts {
    static func parts(_ workbench: Workbench, includeDone: Bool) -> [String] {
        let todo = max(0, workbench.openTargets - workbench.inProgressTargets - workbench.blockedTargets)
        var parts = ["\(workbench.inProgressTargets) in progress", "\(todo) todo"]
        if workbench.blockedTargets > 0 {
            parts.append("\(workbench.blockedTargets) blocked")
        }
        if includeDone {
            parts.append("\(workbench.doneTargets) done")
        }
        return parts
    }
}

/// One card of the Workbench list (spec §4.2).
struct WorkbenchCardModel: Equatable, Identifiable {
    let id: Int64
    let name: String
    let folder: String
    /// The branch, "detached", or nil when the Mac has none yet.
    let branch: String?
    let waitingCount: Int
    /// "N waiting" (orange), "N error" (red), or "idle" when no session is
    /// working or waiting.
    let pills: [Pill]
    let stateCounts: [SessionStateCount]
    /// done/(open+done); nil for a 0-of-0 board (no bar).
    let progress: Double?
    let progressTone = PhoneTone.green
    let countsLine: String

    struct Pill: Equatable, Identifiable {
        let text: String
        let tone: PhoneTone
        let role: ToneRole

        var id: String { text }
    }

    init(_ workbench: Workbench) {
        id = workbench.id
        name = workbench.name
        folder = workbench.folderDisplay
        branch = workbench.detached ? "detached" : (workbench.branch.isEmpty ? nil : workbench.branch)
        waitingCount = workbench.openAsks
        stateCounts = SessionStateCount.list(workbench.sessionCounts)
        let counts = workbench.sessionCounts
        var pills: [Pill] = []
        if workbench.openAsks > 0 {
            pills.append(Pill(text: "\(workbench.openAsks) waiting", tone: .waitingForYou, role: .waiting))
        }
        if counts.failed > 0 {
            pills.append(Pill(text: "\(counts.failed) error", tone: .red, role: .info))
        }
        if counts.working + counts.waiting + counts.needsApproval == 0 {
            pills.append(Pill(text: "idle", tone: .secondary, role: .info))
        }
        self.pills = pills
        let total = workbench.openTargets + workbench.doneTargets
        progress = total > 0 ? Double(workbench.doneTargets) / Double(total) : nil
        countsLine = BoardCounts.parts(workbench, includeDone: true).joined(separator: " · ")
    }

    var toneUses: [ToneUse] {
        var uses = stateCounts.map(\.toneUse)
        uses += pills.map { ToneUse(element: "workbench \(id) pill \($0.text)", tone: $0.tone, role: $0.role) }
        if progress != nil {
            uses.append(ToneUse(element: "workbench \(id) progress", tone: progressTone, role: .progress))
        }
        return uses
    }
}

/// Level 2 of the Workbench tab: the header subline, the Waiting-for-you
/// stack with its closed asks, and the SESSIONS list.
struct WorkbenchMenuModel {
    let id: Int64
    let title: String
    let subline: String
    let waiting: [WaitingCardModel]
    /// Answered, delivered and withdrawn asks, newest first.
    let closedAsks: [OwnerAsk]
    let closedLabel: String?
    /// Live first, then by latest activity.
    let sessions: [SessionRowModel]
    /// "No sessions yet" when the workbench has none.
    let sessionsEmptyText: String?
    /// "Waiting for you · N".
    let waitingHeader: String
    let waitingHeaderTone = PhoneTone.waitingForYou

    init?(workbenchID: Int64, snapshot: WorkbenchReplicaSnapshot, now: Date) {
        guard let workbench = snapshot.workbench(workbenchID) else { return nil }
        id = workbench.id
        title = workbench.name
        let branch = workbench.detached ? "detached" : workbench.branch
        subline = ([branch].filter { !$0.isEmpty } + BoardCounts.parts(workbench, includeDone: false)).joined(separator: " · ")
        waiting = snapshot.openAsks(in: workbenchID).map { WaitingCardModel($0, snapshot: snapshot, now: now) }
        closedAsks = snapshot.asks
            .filter { $0.workbenchID == workbenchID && $0.status != .open }
            .sorted(by: WorkbenchReplicaSnapshot.newestFirst)
        closedLabel = closedAsks.isEmpty ? nil : "▸ \(closedAsks.count) closed"
        waitingHeader = "Waiting for you · \(waiting.count)"
        sessions = snapshot.sessions
            .filter { $0.workbenchID == workbenchID }
            .sorted { lhs, rhs in
                if lhs.live != rhs.live { return lhs.live }
                return lhs.lastActiveAt != rhs.lastActiveAt ? lhs.lastActiveAt > rhs.lastActiveAt : lhs.id < rhs.id
            }
            .map { SessionRowModel($0, now: now) }
        sessionsEmptyText = sessions.isEmpty ? "No sessions yet" : nil
    }

    var toneUses: [ToneUse] {
        [ToneUse(element: "workbench \(id) waiting header", tone: waitingHeaderTone, role: .waiting)]
            + waiting.map(\.toneUse) + sessions.flatMap(\.toneUses)
    }
}

/// One session-state count with its dot (Workbench card, Now chips).
struct SessionStateCount: Equatable, Identifiable {
    let label: String
    let amount: Int
    let tone: PhoneTone
    /// Not-live states draw a ring, as a session row does.
    let isRing: Bool
    /// The waiting and needs-approval counts are waiting-for-you elements.
    let isWaiting: Bool

    var id: String { label }
    var text: String { "\(amount) \(label)" }

    /// The non-zero counts in a fixed order. "Not running" sessions are left
    /// out: they are old sessions, not state worth a dot.
    static func list(_ counts: Workbench.SessionCounts) -> [Self] {
        [
            Self(label: "working", amount: counts.working, tone: .green, isRing: false, isWaiting: false),
            Self(label: "waiting for you", amount: counts.waiting, tone: .waitingForYou, isRing: false, isWaiting: true),
            Self(label: "needs approval", amount: counts.needsApproval, tone: .waitingForYou, isRing: false, isWaiting: true),
            Self(label: "finished", amount: counts.finished, tone: .blue, isRing: true, isWaiting: false),
            Self(label: "failed", amount: counts.failed, tone: .red, isRing: true, isWaiting: false),
            Self(label: "stopped", amount: counts.stopped, tone: .secondary, isRing: true, isWaiting: false)
        ].filter { $0.amount > 0 }
    }

    static func sum(_ all: [Workbench.SessionCounts]) -> Workbench.SessionCounts {
        Workbench.SessionCounts(
            working: all.reduce(0) { $0 + $1.working },
            waiting: all.reduce(0) { $0 + $1.waiting },
            needsApproval: all.reduce(0) { $0 + $1.needsApproval },
            finished: all.reduce(0) { $0 + $1.finished },
            failed: all.reduce(0) { $0 + $1.failed },
            stopped: all.reduce(0) { $0 + $1.stopped },
            notRunning: all.reduce(0) { $0 + $1.notRunning }
        )
    }

    var toneUse: ToneUse {
        ToneUse(element: "session count \(label)", tone: tone, role: .session(isWaiting: isWaiting))
    }
}
