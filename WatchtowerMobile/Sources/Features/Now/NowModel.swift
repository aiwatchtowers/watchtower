import Foundation
import WatchtowerKit

/// The Now tab (spec §5.5, mockup 1): the Mac status chip, then Waiting for
/// you across every workbench (open asks with their quick answers, pending
/// permission requests, stopped and failed sessions; newest first, 20
/// shown), then Working (live working sessions with timers). The next
/// meeting is `NextMeetingCardModel` (Calendar).
struct NowModel {
    static let waitingLimit = 20

    let mac: MacReachability
    let chip: MacStatusChipModel
    let waitingForYou: [NowWaitingRow]
    /// Rows past the first 20.
    let waitingMore: Int
    /// "Nothing is waiting for you" when nothing is.
    let emptyText: String?
    let working: [NowWorkingRow]
    let waitingHeaderTone = PhoneTone.waitingForYou

    init(snapshot: WorkbenchReplicaSnapshot, linked: Bool, now: Date) {
        mac = .of(heartbeat: snapshot.heartbeat?.updatedAt, linked: linked, now: now)
        chip = MacStatusChipModel(macName: snapshot.heartbeat?.macName ?? "", state: mac.chipState(linked: linked), now: now)
        let all = (
            snapshot.openAsks().map { NowWaitingRow($0, snapshot: snapshot, now: now) }
                + snapshot.pendingPermissions.map { NowWaitingRow($0, snapshot: snapshot, now: now) }
                + snapshot.sessions.filter { [.stopped, .failed].contains($0.stateKind) }
                .map { NowWaitingRow(stopped: $0, snapshot: snapshot, now: now) }
        )
        .sorted { $0.at != $1.at ? $0.at > $1.at : $0.order < $1.order }
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
    }
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

    /// A stopped or failed session: its turn is over, the next move is the
    /// owner's.
    init(stopped session: TerminalSessionState, snapshot: WorkbenchReplicaSnapshot, now: Date) {
        id = .session(session.id)
        destination = .session(session.id)
        glyph = session.stateGlyph.isEmpty ? "pause.fill" : session.stateGlyph
        tone = PhoneTone(session.stateTone)
        let failed = session.stateKind == .failed
        title = "\(session.title) — \(failed ? "failed" : "stopped")"
        code = nil
        let detail = failed ? session.stateCaption : (session.finishSummary.isEmpty ? "" : "“\(session.finishSummary)”")
        meta = [snapshot.workbench(session.workbenchID)?.name ?? "", detail].filter { !$0.isEmpty }.joined(separator: " · ")
        at = session.lastActiveAt
        age = CompactAge.string(from: at, now: now)
        options = []
        role = .session(isWaiting: false)
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
