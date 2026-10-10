import Foundation
import WatchtowerKit
import WatchtowerSync

/// The fixed texts of starting and stopping a session from the phone
/// (spec §6.5, §9).
enum SessionStartText {
    static let sheetTitle = "New session on the Mac"
    static let agent = "Claude Code"
    static let sent = "Sent to your Mac"
    static let pickedUp = "Mac picked it up"
    static let starting = "Starting Claude Code"
    static let openSession = "Open session"
    static let ended = "The session ended"
    static let clippedBrief = "The brief is shortened on the phone. Editing it replaces the Mac's full prompt."
    static let leaveHint = "If the Mac is asleep the request waits and starts when it wakes. You can leave this screen."
    static let notAllowed = "This phone is not allowed to start sessions on the Mac"
    static let briefReadOnly = "The Mac uses this brief. To edit it here, allow typing for this phone on the Mac."
    static let stopConfirm = "Stop this session on the Mac?"
    static let stopping = "Stopping…"
    static let outcomeUnknown = "Your Mac restarted while applying this — check it on the Mac"
    static let startFailed = "Your Mac could not start the session"
    static let stopFailed = "Your Mac could not stop the session"

    /// The hub's message, else a fallback for the reason.
    static func failure(_ row: PendingAction, fallback: String) -> String {
        if let message = row.errorMessage, !message.isEmpty, message != ActionOutbox.noMessageFallback {
            return message
        }
        return row.reason == .outcomeUnknown ? outcomeUnknown : fallback
    }
}

/// What this phone may do on the Mac (spec §4.13): the hub's grant, or the
/// spec's defaults while it has none (typing off, starts on).
struct StartGrant: Equatable {
    let typingAllowed: Bool
    let startSessionsAllowed: Bool

    init(_ grant: DeviceGrant?) {
        typingAllowed = grant?.typingAllowed ?? false
        startSessionsAllowed = grant?.startSessionsAllowed ?? true
    }
}

/// Where one start is (spec §6.5): the stage follows the Mac's echoes, so
/// with a stale heartbeat it stays on "Sent to your Mac".
enum StartStage: Equatable {
    /// The save succeeded.
    case sent
    /// The `received` echo.
    case pickedUp
    /// `applied`; the session record is not live yet.
    case starting(sessionID: Int64?)
    /// The session record is live and has reported a state.
    case open(sessionID: Int64)
    /// The session the start ran is no longer live (stopped, or it exited
    /// early): the start is over and the sheet offers a new one.
    case ended(sessionID: Int64)
    /// The Mac refused, or it expired; the row offers Try again.
    case failed(message: String, row: PendingAction)

    /// The stage of a target's start: this run's attempt, else (after a
    /// relaunch) its newest overlay row; nil when nothing was sent.
    static func of(targetID: Int64, attempt: StartAttempt?, snapshot: WorkbenchReplicaSnapshot) -> Self? {
        let entity = SessionStarter.targetRecordName(targetID)
        let rows = snapshot.pending.filter { $0.action.kind == .sessionStart && $0.entityRecordName == entity }
        guard let attempt else { return rows.last.map(Self.init) }
        if attempt.applied {
            guard let sessionID = attempt.sessionID else { return .starting(sessionID: nil) }
            guard let session = snapshot.session(sessionID) else { return .starting(sessionID: sessionID) }
            if session.live {
                return session.stateKind == .notStarted ? .starting(sessionID: sessionID) : .open(sessionID: sessionID)
            }
            // A resumed session's record may still read stopped from before
            // the start: only a newer Mac state than the one the start was
            // sent over ends it (the Mac's clock is never compared with the
            // phone's).
            let newerState = attempt.baseline[sessionID].map { session.hasNewerState(than: $0) } ?? true
            return attempt.params.mode == .new || newerState ? .ended(sessionID: sessionID) : .starting(sessionID: sessionID)
        }
        // No row yet: the replica read has not caught up with the save.
        return rows.first { $0.id == attempt.actionID }.map(Self.init) ?? .sent
    }

    private init(_ row: PendingAction) {
        switch row.state {
        case .failed:
            self = .failed(message: SessionStartText.failure(row, fallback: SessionStartText.startFailed), row: row)
        case .pending:
            self = row.echoStatus == nil ? .sent : .pickedUp
        }
    }
}

/// The progress the start sheet draws: three steps, then Open session.
struct StartProgressModel: Equatable {
    struct Step: Equatable, Identifiable {
        enum State: Equatable { case done, current, todo }

        var id: String { title }
        let title: String
        let state: State
    }

    let stage: StartStage
    let steps: [Step]
    /// The step the start is on; "Open session" once it is open.
    let current: String
    /// "Waiting for your Mac" while the save waits on a stale heartbeat.
    let waitingLine: String?
    /// The session Open session goes to; nil until it is open.
    let openSessionID: Int64?
    let failure: String?
    /// The session ended: the sheet offers Start a new one.
    let isEnded: Bool

    init(stage: StartStage, macOnline: Bool) {
        self.stage = stage
        let reached: Int
        switch stage {
        case .sent: reached = 0
        case .pickedUp: reached = 1
        case .starting: reached = 2
        case .open, .ended: reached = 3
        case .failed: reached = -1
        }
        let titles = [SessionStartText.sent, SessionStartText.pickedUp, SessionStartText.starting]
        steps = titles.enumerated().map { index, title in
            Step(title: title, state: index < reached ? .done : (index == reached ? .current : .todo))
        }
        if case .ended = stage {
            isEnded = true
            current = SessionStartText.ended
        } else {
            isEnded = false
            current = reached >= 0 && reached < titles.count ? titles[reached] : (reached == 3 ? SessionStartText.openSession : "")
        }
        waitingLine = stage == .sent && !macOnline ? BoardWriteText.waitingForMac : nil
        if case let .open(sessionID) = stage {
            openSessionID = sessionID
        } else {
            openSessionID = nil
        }
        if case let .failed(message, _) = stage {
            failure = message
        } else {
            failure = nil
        }
    }

    /// A target's start progress; nil when nothing was sent.
    static func of(targetID: Int64, attempt: StartAttempt?, snapshot: WorkbenchReplicaSnapshot, now: Date) -> Self? {
        StartStage.of(targetID: targetID, attempt: attempt, snapshot: snapshot).map {
            Self(stage: $0, macOnline: MacStatus(heartbeat: snapshot.heartbeat, now: now).isOnline)
        }
    }

    /// The line under a target's Work on it button: the stage, or the
    /// refusal.
    var caption: String {
        failure ?? current
    }

    var failedRow: PendingAction? {
        if case let .failed(_, row) = stage { return row }
        return nil
    }

    var toneUses: [ToneUse] {
        steps.filter { $0.state != .todo }.map { ToneUse(element: "start step \($0.title)", tone: .green, role: .progress) }
            + (failure == nil ? [] : [ToneUse(element: "start failure", tone: .red, role: .status)])
    }
}

/// The start sheet's editable fields. The brief is the target's work-on
/// prompt; it goes on the wire only from a phone allowed to type, and only
/// when edited (an unedited, possibly clipped prompt would replace the
/// Mac's full one).
struct StartSessionDraft: Equatable {
    static let briefLimit = 4_000

    var targetID: Int64?
    /// The work-on prompt the brief was filled from.
    private(set) var prefill = ""
    var brief = "" {
        didSet {
            if brief.count > Self.briefLimit { brief = String(brief.prefix(Self.briefLimit)) }
        }
    }
    /// "Bring the window forward on the Mac": off.
    var bringForward = false
    /// "Plan first, then ask me": on.
    var planFirst = true

    init(target: WorkbenchTarget?) {
        targetID = target?.id
        prefill = target?.workOnPrompt ?? ""
        brief = prefill
    }

    /// A newly picked target: the brief is its work-on prompt again.
    mutating func pick(_ target: WorkbenchTarget) {
        targetID = target.id
        prefill = target.workOnPrompt
        brief = prefill
    }

    func params(workbenchID: Int64, mode: SessionStartParams.Mode, grant: StartGrant) -> SessionStartParams {
        let edited = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        let sendsBrief = grant.typingAllowed && !edited.isEmpty && brief != prefill
        return SessionStartParams(
            workbenchID: workbenchID, mode: mode, planFirst: planFirst, bringForward: bringForward,
            brief: sendsBrief ? brief : nil
        )
    }
}

/// The start sheet (spec §6.5, §13 B6) for one workbench: the target (fixed
/// from a target's detail, picked from the Workbench header), the agent,
/// the brief, the two toggles, an existing session's Open it / Start a new
/// one, and the start's progress once one was sent.
struct StartSessionFormModel {
    struct TargetOption: Equatable, Identifiable {
        let id: Int64
        let label: String
    }

    /// A session already on the target: "Open it" opens a live one on the
    /// phone and resumes a stopped one on the Mac.
    struct ExistingSession: Equatable {
        let id: Int64
        let title: String
        let caption: String
        let isLive: Bool
    }

    let workbenchID: Int64
    let workbenchName: String
    let target: WorkbenchTarget?
    /// "#415 Archive Closed Targets Now".
    let targetLabel: String?
    /// The live targets the header's New session can start, in board order.
    let targetOptions: [TargetOption]
    let agent = SessionStartText.agent
    let grant: StartGrant
    /// Why the brief cannot be edited here; nil when it can.
    let briefCaption: String?
    let existing: ExistingSession?
    let progress: StartProgressModel?
    /// Start (and Open it, Start a new one) can send.
    let canStart: Bool
    /// Why starting is off; nil when it is on or no target is picked yet.
    let startCaption: String?

    init?(
        workbenchID: Int64,
        targetID: Int64?,
        snapshot: WorkbenchReplicaSnapshot,
        grant: DeviceGrant?,
        attempt: StartAttempt?,
        inFlight: Set<String>,
        now: Date
    ) {
        guard let workbench = snapshot.workbench(workbenchID) else { return nil }
        self.workbenchID = workbenchID
        workbenchName = workbench.name
        let target = targetID.flatMap { id in snapshot.targets.first { $0.id == id && $0.workbenchID == workbenchID } }
        self.target = target
        targetLabel = target.map { "#\($0.id) \($0.text)" }
        targetOptions = NewBoardTargetDraft.parentOptions(workbenchID: workbenchID, snapshot: snapshot)
            .map { TargetOption(id: $0.id, label: $0.label) }
        let grant = StartGrant(grant)
        self.grant = grant
        if !grant.typingAllowed {
            briefCaption = SessionStartText.briefReadOnly
        } else {
            briefCaption = target?.workOnPromptClipped == true ? SessionStartText.clippedBrief : nil
        }
        existing = target.flatMap { Self.existingSession(of: $0, in: snapshot, now: now) }
        progress = target.flatMap { StartProgressModel.of(targetID: $0.id, attempt: attempt, snapshot: snapshot, now: now) }
        let sending = target.map { inFlight.contains(SessionStarter.startKey($0.id)) } ?? false
        canStart = target.map { !$0.archived } == true && grant.startSessionsAllowed && !sending
        startCaption = grant.startSessionsAllowed ? nil : SessionStartText.notAllowed
    }

    /// The target's session: a live one first, then the latest active.
    static func existingSession(of target: WorkbenchTarget, in snapshot: WorkbenchReplicaSnapshot, now: Date) -> ExistingSession? {
        let ids = Set(target.sessionIDs)
        let sessions = snapshot.sessions.filter { $0.workbenchID == target.workbenchID && ($0.targetID == target.id || ids.contains($0.id)) }
        let pick = sessions.max { lhs, rhs in
            lhs.live != rhs.live ? !lhs.live : lhs.lastActiveAt < rhs.lastActiveAt
        }
        return pick.map { session in
            ExistingSession(
                id: session.id, title: session.title, caption: SessionRowModel(session, now: now).caption, isLive: session.live
            )
        }
    }

    /// What "Open it" does.
    enum OpenIt: Equatable {
        /// The session runs: its detail opens on the phone, nothing is sent.
        case show(sessionID: Int64)
        /// It does not: `open_existing` resumes it on the Mac.
        case resume
    }

    var openIt: OpenIt? {
        existing.map { $0.isLive ? .show(sessionID: $0.id) : .resume }
    }

    /// "#415 · Acme" above the progress.
    var progressHeader: String {
        [target.map { "#\($0.id)" }, workbenchName].compactMap { $0 }.joined(separator: " · ")
    }

    var toneUses: [ToneUse] {
        progress?.toneUses ?? []
    }
}

/// The session detail's actions menu (spec §6.5): Stop on a live session,
/// with the phone's stop in place until the Mac applies it. Finish comes
/// with session input (Task 18).
struct SessionActionsModel: Equatable {
    /// The phone's stop on its way, or the Mac's refusal of it.
    struct StopRow: Equatable, Identifiable {
        enum State: Equatable {
            case sending(String)
            case failed(String)
        }

        var id: String { pending.id }
        let state: State
        let pending: PendingAction
    }

    let canStop: Bool
    let stopRows: [StopRow]
    /// Hidden until session input lands (Task 18).
    let showsFinish = false

    var hasActions: Bool { canStop || showsFinish }

    init(session: TerminalSessionState, snapshot: WorkbenchReplicaSnapshot, inFlight: Set<String>, now: Date) {
        let entity = SessionStarter.sessionRecordName(session.id)
        let online = MacStatus(heartbeat: snapshot.heartbeat, now: now).isOnline
        stopRows = snapshot.pending
            .filter { $0.action.kind == .sessionStop && $0.entityRecordName == entity }
            .map { row in
                switch row.state {
                case .pending:
                    StopRow(state: .sending(online ? SessionStartText.stopping : BoardWriteText.waitingForMac), pending: row)
                case .failed:
                    StopRow(state: .failed(SessionStartText.failure(row, fallback: SessionStartText.stopFailed)), pending: row)
                }
            }
        let stopping = inFlight.contains(SessionStarter.stopKey(session.id))
            || stopRows.contains { if case .sending = $0.state { true } else { false } }
        canStop = session.live && !stopping
    }
}

extension TerminalSessionState {
    /// The Mac wrote a newer state than `baseline`'s: it went live or not,
    /// its kind changed, or its own stamps moved on (Mac clock against Mac
    /// clock). Other fields (ask counts, report counts, title) do not count.
    func hasNewerState(than baseline: Self) -> Bool {
        live != baseline.live
            || stateKind != baseline.stateKind
            || (stateAt ?? .distantPast) > (baseline.stateAt ?? .distantPast)
            || lastActiveAt > baseline.lastActiveAt
    }
}
