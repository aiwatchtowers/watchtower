import Foundation
import WatchtowerKit
import WatchtowerSync

/// What the workchat's composer may do now (spec §5.4).
enum ComposerState: Equatable {
    /// No composer: the session does not run (nil), or this phone may not
    /// type to it and the hint says why (board #515).
    case hidden(SessionInputModel.TypingHint?)
    /// The owner can write; `footnote` says when a line reaches a busy
    /// agent (none for Claude, which takes it at its next step).
    case ready(footnote: String?)
    /// A permission prompt: no send ("Answer the request above" when the
    /// card takes this phone's answer, else "Needs approval on the Mac").
    case approval(String)
    /// The Mac is away: a line still queues and says so under the field.
    case macAway(String)

    /// The composer bar's mode and note; nil when no bar shows.
    var bar: (mode: ComposerMode, note: String?)? {
        switch self {
        case .hidden: nil
        case let .ready(footnote): (.message, footnote)
        case let .approval(text): (text == SessionInputModel.answerAbove ? .answerAbove : .unavailable(text), nil)
        case let .macAway(note): (.message, note)
        }
    }
}

/// One entry of the workchat's actions menu, in menu order.
enum WorkchatMenuItem: Hashable {
    case stop, finish, interrupt, report
    case openTarget(Int64)

    var title: String {
        switch self {
        case .stop: "Stop"
        case .finish: "Finish"
        case .interrupt: "Interrupt"
        case .report: "Report and timeline"
        case .openTarget: "Open board target"
        }
    }

    var systemImage: String {
        switch self {
        case .stop: "stop.fill"
        case .finish: "flag.checkered"
        case .interrupt: "escape"
        case .report: "chart.bar.doc.horizontal"
        case .openTarget: "square.grid.2x2"
        }
    }
}

/// Everything the workchat draws (spec §5.3, mockups 3, 4, 8): the header
/// (title, workbench, one state line counting up while the agent works),
/// the dialog, the permission card and the session's open asks at the foot
/// of the feed, and the composer's state. Built from the published records
/// and the session's chat only.
struct WorkchatModel: Equatable {
    let id: Int64
    let title: String
    let workbenchName: String
    let stateLine: StateLineModel
    /// The dialog, oldest first; empty until the chat arrives.
    let entries: [SessionChat.Entry]
    /// The session's open asks, newest first, as the Waiting stack builds
    /// them.
    let inlineAsks: [WaitingCardModel]
    /// Ask id → the one-tap answers the Mac computed (`OwnerAsk.quick`); an
    /// ask without them opens its form.
    let askOptions: [Int64: [InlineAskOption]]
    /// A live Claude session's pending permission prompt (#517).
    let permission: PermissionCardModel?
    /// The phone's answers to the session's prompts, until the Mac applied
    /// them.
    let answerRows: [PermissionAnswerRow]
    /// "Sent to the session" once the Mac applied this phone's answer.
    let answerNotice: String?
    let composer: ComposerState
    /// The session's board target, for "Open board target".
    let targetID: Int64?

    init(
        session: TerminalSessionState,
        chat: SessionChat?,
        snapshot: WorkbenchReplicaSnapshot,
        input: SessionInputModel,
        permission: PermissionCardModel?,
        macOnline: Bool,
        now: Date,
        sentRequestID: Int64? = nil
    ) {
        id = session.id
        title = session.title
        workbenchName = snapshot.workbench(session.workbenchID)?.name ?? ""
        targetID = session.targetID
        stateLine = Self.stateLine(session, asOf: macOnline ? nil : snapshot.heartbeat?.updatedAt, now: now)
        entries = chat?.entries ?? []
        let asks = snapshot.asks
            .filter { $0.status == .open && $0.sessionID == session.id }
            .sorted(by: WorkbenchReplicaSnapshot.newestFirst)
        inlineAsks = asks.map { WaitingCardModel($0, snapshot: snapshot, now: now) }
        askOptions = Dictionary(uniqueKeysWithValues: asks.compactMap { ask in
            ask.quick.map { quick in
                (ask.id, quick.options.map { InlineAskOption(id: $0.label, label: $0.label, isRecommended: $0.recommended) })
            }
        })
        self.permission = permission
        let rows = PermissionAnswerRow.rows(sessionID: session.id, snapshot: snapshot, now: now)
        answerRows = rows
        answerNotice = PermissionAnswerRow.notice(rows: rows, permission: permission, sentRequestID: sentRequestID)
        composer = if !input.showsBar {
            .hidden(input.typingHint)
        } else if let approval = input.approvalText {
            .approval(approval)
        } else if !macOnline {
            .macAway(BoardWriteText.waitingForMac)
        } else {
            .ready(footnote: SessionInputModel.footnote(session.agent))
        }
    }

    /// The Mac's glyph, tone and caption; a timer while working, an age
    /// while waiting for the owner, the last activity once stopped, and
    /// "as of" the last contact while the Mac is away.
    static func stateLine(_ session: TerminalSessionState, asOf: Date?, now: Date) -> StateLineModel {
        let waiting = [.waitingOnAsk, .needsApproval].contains(session.stateKind)
        let counts = session.live && (waiting || session.stateKind == .working)
        return StateLineModel(
            glyph: session.stateGlyph,
            tone: PhoneTone(session.stateTone),
            isRing: session.isRing,
            caption: session.live ? session.stateCaption : SessionRowModel(session, now: now).caption,
            isWaiting: waiting,
            stateAt: counts ? session.stateAt : nil,
            now: now,
            asOf: session.live ? asOf : nil
        )
    }

    /// The actions menu: what the session takes now, then the report and
    /// the board target, which every session has.
    static func menu(actions: SessionActionsModel, targetID: Int64?) -> [WorkchatMenuItem] {
        var items: [WorkchatMenuItem] = []
        if actions.canStop { items.append(.stop) }
        if actions.showsFinish { items.append(.finish) }
        if actions.canInterrupt { items.append(.interrupt) }
        items.append(.report)
        if let targetID { items.append(.openTarget(targetID)) }
        return items
    }

    var toneUses: [ToneUse] {
        var uses = [stateLine.toneUse]
        if permission != nil {
            uses.append(ToneUse(element: "session \(id) permission card", tone: .waitingForYou, role: .waiting))
        }
        return uses + inlineAsks.map(\.toneUse)
    }
}

/// Which chat screen this is: the session's own (with the composer) or a
/// subagent's, which is read-only.
enum ChatScreen {
    case session, subagent

    var hasComposer: Bool { self == .session }
}
