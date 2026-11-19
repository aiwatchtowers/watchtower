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
    /// Why the Mac cannot watch this working session, the Mac's tooltip as
    /// given (U6, `watch_help`): the row's accessibility hint; nil when
    /// watched.
    let watchHint: String?
    /// The bench folder the session runs in, named only on a bench of more
    /// than one folder (the Mac decides, spec 2026-11-18 §6.14); nil on a
    /// one-folder bench and from a Mac older than the key.
    let folderLabel: String?
    /// `from #<id>` on a sub-session (the list is flat); nil on a top-level
    /// session.
    let fromParent: String?

    /// `asOf`: the Mac's last contact while it is asleep; a live session's
    /// time then reads "as of …" instead of counting on.
    init(_ session: TerminalSessionState, now: Date, asOf: Date? = nil) {
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
        watchHint = session.watchHelp
        isRing = session.isRing
        openAsks = session.openAsks

        folderLabel = session.folder.flatMap { $0.isEmpty ? nil : $0 }
        fromParent = session.parentSessionID.map { "from #\($0)" }
        var items = [MetaItem(text: caption, tone: tone, role: .session(isWaiting: isWaiting))]
        // Right after the caption: the place a session runs in reads before
        // its report, and the report's tail truncates first.
        if let folder = folderLabel {
            items.append(MetaItem(text: folder, tone: .secondary, role: .info))
        }
        if let from = fromParent {
            items.append(MetaItem(text: from, tone: .secondary, role: .info))
        }
        if let target = session.reportTargetID {
            var report = "#\(target)"
            if let done = session.reportDone, let total = session.reportTotal {
                report += " · \(done)/\(total)"
            }
            if let merged = session.reportMergedText { report += " · \(merged)" }
            items.append(MetaItem(text: report, tone: .secondary, role: .info))
            if let pr = session.reportPRLine, !pr.isEmpty {
                items.append(MetaItem(text: pr, tone: .secondary, role: .info))
            }
        }
        if session.closedAsks > 0 {
            items.append(MetaItem(text: "\(session.closedAsks) closed", tone: .secondary, role: .info))
        }
        metaItems = items
        var panel = [MetaItem(text: session.stateCaption, tone: tone, role: .session(isWaiting: isWaiting))]
        // The open-ask count the badge of `SessionRowView` shows, unless the
        // Mac's caption already says it ("Finished · 1 ask open").
        let asksOpen = session.openAsks == 1 ? "1 ask open" : "\(session.openAsks) asks open"
        if session.openAsks > 0, !session.stateCaption.contains(asksOpen) {
            panel.append(MetaItem(text: asksOpen, tone: openAsksTone, role: .ask))
        }
        panelMetaItems = panel + items.dropFirst()
        let counts = session.live && [.working, .running].contains(session.stateKind) && session.stateAt != nil
        time = StateLineModel(
            glyph: nil, tone: tone, caption: session.stateCaption, isWaiting: !counts,
            stateAt: counts ? session.stateAt : (since ?? session.lastActiveAt), now: now,
            asOf: session.live ? asOf : nil
        ).time
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

/// Level 2 of the Workbench tab: the branch and board counts (the Board
/// segment shows them), then the sessions split as Now splits them (#1788):
/// Waiting for you (an ask, an approval, a verdict to give), Working, then
/// Ended in the last day and "▸ N older" folded; asks whose session is not
/// listed wait on top, and the closed asks fold at the end.
struct WorkbenchMenuModel {
    /// An ended session stays in Ended this long after it ended
    /// (`endedAt`, Now's former window for ended sessions); older ones fold.
    static let endedWindow: TimeInterval = 24 * 3_600

    /// When an ended session ended: its state's time, else its last
    /// activity, the time Now's ended rows use (`NowWaitingRow(ended:)`).
    static func endedAt(_ session: TerminalSessionState) -> Date {
        session.stateAt ?? session.lastActiveAt
    }

    let id: Int64
    let title: String
    /// The branch, "detached", or nil when the Mac has none yet.
    let branch: String?
    let boardCounts: [BoardCountItem]
    /// The non-empty sections, in the panel's order; rows newest first.
    let sections: [SessionSection]
    /// Ended sessions older than `endedWindow`, newest first: the folded
    /// group.
    let older: [SessionRowModel]
    /// "6 older"; nil when none.
    let olderLabel: String?
    /// Open asks whose session this list does not show (none, or another
    /// workbench's), newest first.
    let unattachedAsks: [WaitingCardModel]
    /// Answered, delivered and withdrawn asks, newest first.
    let closedAsks: [OwnerAsk]
    let closedLabel: String?
    /// "No sessions yet" when the workbench has none.
    let sessionsEmptyText: String?

    /// `asOf`: the Mac's last contact while it is asleep
    /// (`MacReachability.asOf`), so live rows stop counting. `typing`:
    /// whether this phone may type into the hub's sessions, which makes a
    /// live failed session wait for Continue.
    init?(workbenchID: Int64, snapshot: WorkbenchReplicaSnapshot, now: Date, asOf: Date?, typing: PhoneTyping = .off) {
        guard let workbench = snapshot.workbench(workbenchID) else { return nil }
        id = workbench.id
        title = workbench.name
        let branchName = workbench.detached ? "detached" : workbench.branch
        branch = branchName.isEmpty ? nil : branchName
        boardCounts = BoardCounts.items(workbench)
        let sessions = snapshot.sessions
            .filter { $0.workbenchID == workbenchID }
            .sorted { $0.lastActiveAt != $1.lastActiveAt ? $0.lastActiveAt > $1.lastActiveAt : $0.id > $1.id }
        var bySection: [Group: [TerminalSessionState]] = [:]
        for session in sessions {
            var group = Group(session, continues: SessionInputModel.waitsToContinue(session, in: snapshot, typing: typing))
            if group == .ended, now.timeIntervalSince(Self.endedAt(session)) > Self.endedWindow {
                group = .older
            }
            bySection[group, default: []].append(session)
        }
        // Ended and older read newest end first; the rest keep the panel's last-activity order.
        for group in [Group.ended, .older] {
            bySection[group]?.sort {
                let (lhs, rhs) = (Self.endedAt($0), Self.endedAt($1))
                return lhs != rhs ? lhs > rhs : $0.id > $1.id
            }
        }
        let grouped = bySection.mapValues { $0.map { SessionRowModel($0, now: now, asOf: asOf) } }
        sections = Group.listed.compactMap { group in
            grouped[group].map { SessionSection(title: group.title, tone: group.tone, rows: $0) }
        }
        older = grouped[.older] ?? []
        olderLabel = older.isEmpty ? nil : "\(older.count) older"
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

    /// Where a session sits in the list, by the Mac's state (#1788, Now's
    /// split): the owner's move (an open ask of any state, an approval, a
    /// verdict on a check, a failed turn this phone can continue), the
    /// agent's, or ended. A stopped or failed session with nothing open and
    /// no Continue from this phone is Ended (its caption keeps the colour).
    /// `older` is Ended past the window.
    private enum Group: CaseIterable {
        case waiting, working, ended, older

        static let listed: [Self] = [.waiting, .working, .ended]

        /// `continues`: `SessionInputModel.waitsToContinue`.
        init(_ session: TerminalSessionState, continues: Bool) {
            if continues {
                self = .waiting
                return
            }
            switch session.stateKind {
            case .waitingOnAsk, .needsApproval, .readyToCheck: self = .waiting
            case _ where session.openAsks > 0: self = .waiting
            case .working, .running: self = .working
            case .finished, .stopped, .failed, .notStarted: self = .ended
            default: self = session.live ? .working : .ended
            }
        }

        var title: String {
            switch self {
            case .waiting: "Waiting for you"
            case .working: "Working"
            case .ended: "Ended"
            case .older: "Older"
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
            + (sections.flatMap(\.rows) + older).flatMap(\.toneUses)
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
