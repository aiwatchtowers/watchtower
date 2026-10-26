import Foundation
import WatchtowerKit

/// One SESSIONS row (spec §4.5, design pass S3): the Mac's resolved dot and
/// caption drawn as given (PROJ-11 stays on the Mac), then one meta line.
struct SessionRowModel: Equatable, Identifiable {
    let id: Int64
    let title: String
    /// The Mac's caption plus an age: a live session's time in its current
    /// state ("Needs approval · 40m", from `stateAt`; none while unknown), a
    /// session that is not live its last activity ("Stopped · 3h"). The
    /// phone computes it, so the record need not change every minute.
    let caption: String
    let tone: PhoneTone
    /// An SF Symbol name; nil when the Mac sent none. Kept in the model; the
    /// phone draws the dot only (design pass §9.1).
    let glyph: String?
    let isRing: Bool
    /// The caption in the session's tone, then `#<target> · <done>/<total>`,
    /// the PR line and "N closed" in secondary; the last truncates first.
    let metaItems: [MetaItem]
    let openAsks: Int
    let openAsksTone = PhoneTone.waitingForYou
    /// The sessions list's meta (mockup 2): the Mac's caption alone (the
    /// time trails the row), then the report items.
    let panelMetaItems: [MetaItem]
    /// The sessions list's trailing time: m:ss while a live session works,
    /// else the age of its state ("4m").
    let time: String?
    /// The Mac's orange states plus a session with open asks (finished with
    /// open asks): the only sessions whose orange is a waiting element.
    private let isWaiting: Bool

    init(_ session: TerminalSessionState, now: Date) {
        let since = session.live ? session.stateAt : session.lastActiveAt
        let caption = since.map { "\(session.stateCaption) · \(CompactAge.string(from: $0, now: now))" }
            ?? session.stateCaption
        let tone = PhoneTone(session.stateTone)
        let isWaiting = [.waitingOnAsk, .needsApproval].contains(session.stateKind) || session.openAsks > 0
        id = session.id
        title = session.title
        self.caption = caption
        self.tone = tone
        self.isWaiting = isWaiting
        glyph = session.stateGlyph.isEmpty ? nil : session.stateGlyph
        isRing = session.isRing
        openAsks = session.openAsks

        var items = [MetaItem(text: caption, tone: tone, role: .session(isWaiting: isWaiting))]
        if let target = session.reportTargetID {
            var report = "#\(target)"
            if let done = session.reportDone, let total = session.reportTotal {
                report += " · \(done)/\(total)"
            }
            items.append(MetaItem(text: report, tone: .secondary, role: .info))
            if let pr = session.reportPRLine, !pr.isEmpty {
                items.append(MetaItem(text: pr, tone: .secondary, role: .info))
            }
        }
        if session.closedAsks > 0 {
            items.append(MetaItem(text: "\(session.closedAsks) closed", tone: .secondary, role: .info))
        }
        metaItems = items
        panelMetaItems = [MetaItem(text: session.stateCaption, tone: tone, role: .session(isWaiting: isWaiting))] + items.dropFirst()
        time = if session.live, [.working, .running].contains(session.stateKind), let stateAt = session.stateAt {
            StateLineModel.timer(Int(now.timeIntervalSince(stateAt)))
        } else {
            CompactAge.string(from: since ?? session.lastActiveAt, now: now)
        }
    }

    /// The sessions list's icon (mockup 2): the Mac's glyph on a disc, else
    /// the dot.
    var icon: FlatRowIcon {
        glyph.map { .state(glyph: $0, tone: tone) } ?? .session(tone: tone, isRing: isRing)
    }

    var toneUses: [ToneUse] {
        var uses = [
            ToneUse(element: "session \(id) dot", tone: tone, role: .session(isWaiting: isWaiting)),
            ToneUse(element: "session \(id) label", tone: tone, role: .session(isWaiting: isWaiting))
        ]
        if openAsks > 0 {
            uses.append(ToneUse(element: "session \(id) open asks", tone: openAsksTone, role: .ask))
        }
        return uses
    }
}

/// One Waiting-for-you ask: its kind (word and the Mac's icon), the title and "Session · #target · age" (Now prefixes the workbench).
/// A pending permission request (#517) is one too: "Needs approval", the
/// tool, then the summary's first line and "Session · age" (Now prefixes
/// the workbench there too); it opens its session.
struct WaitingCardModel: Equatable, Identifiable {
    /// Where a tap goes: the ask's form, or the session with the prompt.
    enum Destination: Hashable {
        case ask(Int64)
        case session(Int64)
    }

    let destination: Destination
    let kindLabel: String
    /// The Mac's kind icon (`OwnerAskPresentation.swift:136-142`).
    let kindIcon: String
    let title: String
    let subline: String
    /// Label, tint and border of the card.
    let tone = PhoneTone.waitingForYou

    var id: Destination { destination }

    init(_ ask: OwnerAsk, snapshot: WorkbenchReplicaSnapshot, now: Date, showWorkbench: Bool = false) {
        destination = .ask(ask.id)
        kindLabel = AskKindStyle.name(ask.kind)
        kindIcon = AskKindStyle.icon(ask.kind)
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

    init(_ request: PermissionRequest, snapshot: WorkbenchReplicaSnapshot, now: Date, showWorkbench: Bool = false) {
        destination = .session(request.sessionID)
        kindLabel = "Needs approval"
        kindIcon = "hand.raised.fill"
        title = request.toolName
        var parts: [String] = []
        if let line = request.summary.split(separator: "\n", maxSplits: 1).first {
            parts.append(String(line))
        }
        if showWorkbench, let workbench = snapshot.workbench(request.workbenchID) {
            parts.append(workbench.name)
        }
        if let session = snapshot.session(request.sessionID) {
            parts.append(session.title)
        }
        parts.append(CompactAge.string(from: request.createdAt, now: now))
        subline = parts.joined(separator: " · ")
    }

    var toneUse: ToneUse {
        switch destination {
        case let .ask(id): ToneUse(element: "ask \(id) card", tone: tone, role: .ask)
        case let .session(id): ToneUse(element: "session \(id) permission request card", tone: tone, role: .waiting)
        }
    }
}

/// One coloured count of the Workbench header line, role `.status`.
typealias BoardCountItem = MetaItem

/// The board's counts for the Workbench header (design pass S1): "3 in
/// progress" blue, "3 todo" secondary, "1 blocked" red (only when there is
/// one). "todo" is the open targets that are neither in progress nor
/// blocked (in review counts there too).
enum BoardCounts {
    static func items(_ workbench: Workbench) -> [BoardCountItem] {
        let todo = max(0, workbench.openTargets - workbench.inProgressTargets - workbench.blockedTargets)
        var items = [
            BoardCountItem(text: "\(workbench.inProgressTargets) in progress", tone: .blue, role: .status),
            BoardCountItem(text: "\(todo) todo", tone: .secondary, role: .status)
        ]
        if workbench.blockedTargets > 0 {
            items.append(BoardCountItem(text: "\(workbench.blockedTargets) blocked", tone: .red, role: .status))
        }
        return items
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
    /// "1/8 done"; "No targets" for a 0-of-0 board (which draws no bar).
    let doneLine: String

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
        doneLine = total > 0 ? "\(workbench.doneTargets)/\(total) done" : "No targets"
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

/// One section of a workbench's sessions (mockup 2).
struct SessionSection: Equatable, Identifiable {
    let title: String
    let tone: PhoneTone
    let rows: [SessionRowModel]

    var id: String { title }
}

/// Level 2 of the Workbench tab: the branch and board counts, then the
/// sessions in the Desktop sessions panel's order (spec §5.5, mockup 2):
/// Waiting for you, Working, Ready to check, Not running, then "▸ N
/// finished" folded; asks whose session is not listed wait on top, and the
/// closed asks fold at the end.
struct WorkbenchMenuModel {
    let id: Int64
    let title: String
    /// The branch, "detached", or nil when the Mac has none yet.
    let branch: String?
    let boardCounts: [BoardCountItem]
    /// The non-empty sections, in the panel's order; rows newest first.
    let sections: [SessionSection]
    /// Finished with no open ask, newest first: the folded group.
    let finished: [SessionRowModel]
    /// "6 finished"; nil when none.
    let finishedLabel: String?
    /// Open asks whose session this list does not show (none, or another
    /// workbench's), newest first.
    let unattachedAsks: [WaitingCardModel]
    /// Answered, delivered and withdrawn asks, newest first.
    let closedAsks: [OwnerAsk]
    let closedLabel: String?
    /// "No sessions yet" when the workbench has none.
    let sessionsEmptyText: String?

    init?(workbenchID: Int64, snapshot: WorkbenchReplicaSnapshot, now: Date) {
        guard let workbench = snapshot.workbench(workbenchID) else { return nil }
        id = workbench.id
        title = workbench.name
        let branchName = workbench.detached ? "detached" : workbench.branch
        branch = branchName.isEmpty ? nil : branchName
        boardCounts = BoardCounts.items(workbench)
        let sessions = snapshot.sessions
            .filter { $0.workbenchID == workbenchID }
            .sorted { $0.lastActiveAt != $1.lastActiveAt ? $0.lastActiveAt > $1.lastActiveAt : $0.id > $1.id }
        var grouped: [Group: [SessionRowModel]] = [:]
        for session in sessions {
            grouped[Group(session), default: []].append(SessionRowModel(session, now: now))
        }
        sections = Group.listed.compactMap { group in
            grouped[group].map { SessionSection(title: group.title, tone: group.tone, rows: $0) }
        }
        finished = grouped[.finished] ?? []
        finishedLabel = finished.isEmpty ? nil : "\(finished.count) finished"
        let listed = Set(sessions.map(\.id))
        unattachedAsks = snapshot.openAsks(in: workbenchID)
            .filter { $0.sessionID.map { !listed.contains($0) } ?? true }
            .map { WaitingCardModel($0, snapshot: snapshot, now: now) }
        closedAsks = snapshot.asks
            .filter { $0.workbenchID == workbenchID && $0.status != .open }
            .sorted(by: WorkbenchReplicaSnapshot.newestFirst)
        closedLabel = closedAsks.isEmpty ? nil : "\(closedAsks.count) closed"
        sessionsEmptyText = sessions.isEmpty ? "No sessions yet" : nil
    }

    /// Where a session sits in the list, by the Mac's state: the owner's
    /// move (an ask, an approval, a finished session's open ask, a stopped
    /// or failed turn), the agent's, a verdict, not running, or done.
    private enum Group: CaseIterable {
        case waiting, working, readyToCheck, notRunning, finished

        static let listed: [Self] = [.waiting, .working, .readyToCheck, .notRunning]

        init(_ session: TerminalSessionState) {
            switch session.stateKind {
            case .waitingOnAsk, .needsApproval, .stopped, .failed: self = .waiting
            case .finished: self = session.openAsks > 0 ? .waiting : .finished
            case .readyToCheck: self = .readyToCheck
            case .working, .running: self = .working
            case .notStarted: self = .notRunning
            default: self = session.live ? .working : .notRunning
            }
        }

        var title: String {
            switch self {
            case .waiting: "Waiting for you"
            case .working: "Working"
            case .readyToCheck: "Ready to check"
            case .notRunning: "Not running"
            case .finished: "Finished"
            }
        }

        var tone: PhoneTone {
            self == .waiting ? .waitingForYou : .secondary
        }
    }

    var toneUses: [ToneUse] {
        sections.filter { $0.tone == .waitingForYou }
            .map { ToneUse(element: "workbench \(id) \($0.title) header", tone: $0.tone, role: .waiting) }
            + boardCounts.map { ToneUse(element: "workbench \(id) \($0.text)", tone: $0.tone, role: $0.role) }
            + unattachedAsks.map(\.toneUse)
            + (sections.flatMap(\.rows) + finished).flatMap(\.toneUses)
    }
}

/// One session-state count with its dot (Workbench card).
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

    var toneUse: ToneUse {
        ToneUse(element: "session count \(label)", tone: tone, role: .session(isWaiting: isWaiting))
    }
}
