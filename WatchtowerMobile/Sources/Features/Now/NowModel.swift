import Foundation
import WatchtowerKit

/// The Now tab (spec §5.5, mockup 1): the Mac status chip, the outbox's
/// Waiting to send and Not delivered (relay client mockup 5a), then Waiting for
/// you across every workbench (open asks with their quick answers, pending
/// permission requests, sessions that stopped, finished or failed in the
/// last 24 h unless an open ask of theirs already shows; newest first, 20
/// shown), then Working (live working sessions with timers). The next
/// meeting is `NextMeetingCardModel` (Calendar).
struct NowModel {
    static let waitingLimit = 20
    /// A stopped, finished or failed session waits on Now this long after
    /// its state changed.
    static let endedSessionWindow: TimeInterval = 24 * 3_600

    let mac: MacReachability
    let chip: MacStatusChipModel
    let waitingForYou: [NowWaitingRow]
    /// Rows past the first 20.
    let waitingMore: Int
    /// "Nothing is waiting for you" when nothing is.
    let emptyText: String?
    let working: [NowWorkingRow]
    let waitingHeaderTone = PhoneTone.waitingForYou
    /// Waiting to send and Not delivered; nil when neither shows.
    let outbox: NowOutboxRows?

    /// `lastFlushStopped`: the session's last outbox flush stopped on a refusal (`OutboxBacklog`); the outbox's
    /// rows and counts come from the snapshot's own `pending` rows, so they always agree with each other.
    init(snapshot: WorkbenchReplicaSnapshot, linked: Bool, now: Date, lastFlushStopped: Bool = false, calendar: Calendar = .current) {
        outbox = NowOutboxRows(
            lastFlushStopped: lastFlushStopped, queued: OutboxItem.rows(snapshot.pending, .queued),
            undelivered: OutboxItem.rows(snapshot.pending, .undelivered), snapshot: snapshot, now: now, calendar: calendar)
        mac = .of(heartbeat: snapshot.heartbeat?.updatedAt, linked: linked, now: now)
        chip = MacStatusChipModel(macName: snapshot.heartbeat?.macName ?? "", state: mac.chipState(linked: linked), now: now)
        let openAsks = snapshot.openAsks()
        let asks: [NowWaitingRow] = openAsks.map { NowWaitingRow($0, snapshot: snapshot, now: now) }
        let requests: [NowWaitingRow] = snapshot.pendingPermissions.map { NowWaitingRow($0, snapshot: snapshot, now: now) }
        // One row per waiting thing (ask #622): an ended session with an open ask shows as that ask only.
        let askedSessions = Set(openAsks.compactMap(\.sessionID))
        let ended: [NowWaitingRow] = snapshot.sessions
            .filter { [.stopped, .finished, .failed].contains($0.stateKind) && !askedSessions.contains($0.id) }
            .map { NowWaitingRow(ended: $0, snapshot: snapshot, now: now) }
            .filter { now.timeIntervalSince($0.at) <= Self.endedSessionWindow }
        let all = (asks + requests + ended).sorted { $0.at != $1.at ? $0.at > $1.at : $0.order < $1.order }
        waitingForYou = Array(all.prefix(Self.waitingLimit))
        waitingMore = max(0, all.count - Self.waitingLimit)
        emptyText = all.isEmpty ? "Nothing is waiting for you" : nil
        let asOf = mac.asOf
        working = snapshot.sessions
            .filter { $0.live && [.working, .running].contains($0.stateKind) }
            .sorted { $0.lastActiveAt != $1.lastActiveAt ? $0.lastActiveAt > $1.lastActiveAt : $0.id < $1.id }
            .map { NowWorkingRow($0, snapshot: snapshot, asOf: asOf, now: now) }
    }

    /// The header's count; nil when nothing waits.
    var waitingCount: Int? {
        let total = waitingForYou.count + waitingMore
        return total > 0 ? total : nil
    }

    var toneUses: [ToneUse] {
        [chip.toneUse, ToneUse(element: "waiting header", tone: waitingHeaderTone, role: .waiting)]
            + waitingForYou.map(\.toneUse)
            + working.map { ToneUse(element: "working session \($0.id) dot", tone: .green, role: .session(isWaiting: false)) }
            + (outbox?.toneUses ?? [])
    }
}

/// Now's outbox group (relay client mockup 5a, Ruling 12): **Waiting to send** with the count and the oldest
/// queued actions, only while something is queued and the last flush stopped on a refusal; **Not delivered** with
/// the count, a link to the list, while anything is listed there. Never orange.
struct NowOutboxRows: Equatable {
    static let queuedLimit = 3

    let waitingTitle = "Waiting to send"
    /// nil: Waiting to send is hidden.
    let waitingCount: Int?
    /// The oldest queued actions, at most `queuedLimit`.
    let queued: [NowQueuedRow]
    /// "2 more" past the first rows.
    let moreText: String?
    /// "Not delivered · 2"; nil: the row is hidden.
    let notDeliveredText: String?

    /// `queued` and `undelivered`: the ordered rows in those states, oldest first (`OutboxItem.rows`).
    init?(
        lastFlushStopped: Bool,
        queued items: [OutboxItem],
        undelivered: [OutboxItem],
        snapshot: WorkbenchReplicaSnapshot,
        now: Date,
        calendar: Calendar
    ) {
        let waiting = !items.isEmpty && lastFlushStopped
        guard waiting || !undelivered.isEmpty else { return nil }
        waitingCount = waiting ? items.count : nil
        let format = RecordingsFormat(calendar: calendar, now: now)
        let shown = waiting ? Array(items.prefix(Self.queuedLimit)) : []
        queued = shown.map { NowQueuedRow(id: $0.id, summary: ActionSummary.text(for: $0, snapshot: snapshot), time: format.when($0.createdAt)) }
        let more = waiting ? items.count - shown.count : 0
        moreText = more > 0 ? "\(more) more" : nil
        notDeliveredText = undelivered.isEmpty ? nil : "\(NotDeliveredModel.title) · \(undelivered.count)"
    }

    var toneUses: [ToneUse] {
        (waitingCount == nil ? [] : [ToneUse(element: "waiting to send count", tone: .secondary, role: .info)])
            + (notDeliveredText == nil ? [] : [ToneUse(element: "not delivered row", tone: .red, role: .status)])
    }
}

/// One queued action under Waiting to send: its summary and "Today 09:58".
struct NowQueuedRow: Equatable, Identifiable {
    let id: String
    let summary: String
    let time: String
}

/// One Waiting-for-you row of Now (mockup 1): a state mark, the title, a
/// mono line for a permission prompt's command, the meta line and the age;
/// a quick question carries its one-tap answers.
struct NowWaitingRow: Equatable, Identifiable {
    enum Key: Hashable {
        case ask(Int64)
        case request(Int64)
        case session(Int64)
    }

    let id: Key
    /// Where a tap goes: the ask's form, or the session's workchat.
    let destination: WaitingCardModel.Destination
    let glyph: String
    let tone: PhoneTone
    let title: String
    /// The first line of a permission prompt's summary, drawn mono.
    let code: String?
    /// "Acme · Archive closed targets · ask #109".
    let meta: String
    let age: String
    /// The Mac's one-tap answers (`OwnerAsk.quick`); empty opens the form.
    let options: [InlineAskOption]
    let at: Date
    private let role: ToneRole

    /// Ties at the same moment: asks, then requests, then sessions.
    fileprivate var order: Int {
        switch id {
        case .ask: 0
        case .request: 1
        case .session: 2
        }
    }

    init(_ ask: OwnerAsk, snapshot: WorkbenchReplicaSnapshot, now: Date) {
        id = .ask(ask.id)
        destination = .ask(ask.id)
        glyph = ask.kind == .question ? "questionmark" : AskKindStyle.icon(ask.kind)
        tone = .waitingForYou
        title = ask.title
        code = nil
        meta = ([ask.workbenchName, ask.sessionID.flatMap(snapshot.session)?.title, "ask #\(ask.id)"] as [String?])
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        at = ask.createdAt
        age = CompactAge.string(from: at, now: now)
        options = ask.quick.map { quick in
            quick.options.map { InlineAskOption(id: $0.label, label: $0.label, isRecommended: $0.recommended) }
        } ?? []
        role = .ask
    }

    init(_ request: PermissionRequest, snapshot: WorkbenchReplicaSnapshot, now: Date) {
        id = .request(request.id)
        destination = .session(request.sessionID)
        glyph = "hand.raised.fill"
        tone = .waitingForYou
        title = "Needs approval: \(request.toolName)"
        code = request.summary.split(separator: "\n", maxSplits: 1).first.map(String.init)
        meta = [snapshot.workbench(request.workbenchID)?.name, snapshot.session(request.sessionID)?.title]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        at = request.createdAt
        age = CompactAge.string(from: at, now: now)
        options = []
        role = .waiting
    }

    /// A stopped, finished or failed session: its turn is over, the next
    /// move is the owner's. `at` is its state's time (`state_at`, else the
    /// last activity).
    init(ended session: TerminalSessionState, snapshot: WorkbenchReplicaSnapshot, now: Date) {
        id = .session(session.id)
        destination = .session(session.id)
        let failed = session.stateKind == .failed
        let finished = session.stateKind == .finished
        let fallbackGlyph = failed ? "exclamationmark" : finished ? "checkmark" : "pause.fill"
        glyph = session.stateGlyph.isEmpty ? fallbackGlyph : session.stateGlyph
        tone = PhoneTone(session.stateTone)
        let word = failed ? "failed" : finished ? "finished" : "stopped"
        title = "\(session.title) — \(word)"
        code = nil
        let detail = failed ? session.stateCaption : (session.finishSummary.isEmpty ? "" : "“\(session.finishSummary)”")
        meta = [snapshot.workbench(session.workbenchID)?.name ?? "", detail].filter { !$0.isEmpty }.joined(separator: " · ")
        at = session.stateAt ?? session.lastActiveAt
        age = CompactAge.string(from: at, now: now)
        options = []
        // A finished session with an open ask is orange: it waits on that ask.
        role = .session(isWaiting: session.openAsks > 0)
    }

    var toneUse: ToneUse {
        ToneUse(element: "now waiting row \(id)", tone: tone, role: role)
    }
}

/// One Working row of Now (mockup 1): the green dot, the title, "workbench ·
/// caption" and the time in its state, "as of …" while the Mac is asleep.
struct NowWorkingRow: Equatable, Identifiable {
    let id: Int64
    let title: String
    let meta: String
    let time: String?

    init(_ session: TerminalSessionState, snapshot: WorkbenchReplicaSnapshot, asOf: Date?, now: Date) {
        id = session.id
        title = session.title
        meta = [snapshot.workbench(session.workbenchID)?.name ?? "", session.stateCaption]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        time = StateLineModel(
            glyph: nil, tone: .green, caption: session.stateCaption, isWaiting: false, stateAt: session.stateAt,
            now: now, asOf: asOf
        ).time
    }
}
