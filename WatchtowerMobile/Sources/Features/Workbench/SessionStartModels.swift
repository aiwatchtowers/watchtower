import Foundation
import WatchtowerKit
import WatchtowerSync

/// The fixed texts of starting and stopping a session from the phone
/// (spec §6.5, §9).
enum SessionStartText {
    static let sheetTitle = "New session on the Mac"
    /// The agent a hub older than Codex support starts.
    static let agent = "Claude Code"
    static let sent = "Sent to your Mac"
    static let pickedUp = "Mac picked it up"
    static let openSession = "Open session"
    static let ended = "The session ended"
    static let clippedBrief = "The brief is shortened on the phone. Editing it replaces the Mac's full prompt."
    static let leaveHint = "If the Mac is asleep the request waits and starts when it wakes. You can leave this screen."
    /// The Mac has not allowed this phone to start sessions (#565): the
    /// owner allows typing and then starting sessions on the Mac.
    static let notAllowed = "Your Mac has not allowed this phone to start sessions. "
        + "On the Mac: Watchtower → Settings → Mobile → allow typing, then starting sessions."
    /// The phone's own "Start sessions from this phone" is off.
    static let turnedOff = "Start sessions from this phone is off in Settings."
    static let chooseTarget = "Choose a target to start"
    static let briefReadOnly = "The Mac uses this brief. To edit it here, allow typing for this phone on the Mac."
    static let stopConfirm = "Stop this session on the Mac?"
    static let stopping = "Stopping…"
    static let outcomeUnknown = "Your Mac restarted while applying this — check it on the Mac"
    static let startFailed = "Your Mac could not start the session"
    static let stopFailed = "Your Mac could not stop the session"

    /// "Starting Codex": the progress step naming the agent that starts.
    static func starting(_ agentName: String) -> String {
        "Starting \(agentName)"
    }

    /// The agent a phone start runs: the Mac's default agent (board #399,
    /// D6 — the phone has no picker), Claude Code from an older hub.
    static func agentName(_ workbench: Workbench?) -> String {
        workbench?.defaultAgent.map(SessionDetailModel.agentName) ?? agent
    }

    /// The hub's message, else a fallback for the reason.
    static func failure(_ row: PendingAction, fallback: String) -> String {
        if let message = row.errorMessage, !message.isEmpty, message != ActionOutbox.noMessageFallback {
            return message
        }
        return row.reason == .outcomeUnknown ? outcomeUnknown : fallback
    }
}

/// What this phone may do on the Mac (spec §4.13): the hub's grant, or the
/// spec's defaults while it has none (typing off, starts off: the Mac
/// allows starts, #565).
struct StartGrant: Equatable {
    let typingAllowed: Bool
    let startSessionsAllowed: Bool

    init(_ grant: DeviceGrant?) {
        typingAllowed = grant?.typingAllowed ?? false
        startSessionsAllowed = grant?.startSessionsAllowed ?? false
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

    init(stage: StartStage, macOnline: Bool, agentName: String = SessionStartText.agent) {
        self.stage = stage
        let reached: Int
        switch stage {
        case .sent: reached = 0
        case .pickedUp: reached = 1
        case .starting: reached = 2
        case .open, .ended: reached = 3
        case .failed: reached = -1
        }
        let titles = [SessionStartText.sent, SessionStartText.pickedUp, SessionStartText.starting(agentName)]
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
        let workbenchID = snapshot.targets.first { $0.id == targetID }?.workbenchID
        let agentName = SessionStartText.agentName(workbenchID.flatMap(snapshot.workbench))
        return StartStage.of(targetID: targetID, attempt: attempt, snapshot: snapshot).map {
            Self(stage: $0, macOnline: MacStatus(heartbeat: snapshot.heartbeat, now: now).isOnline, agentName: agentName)
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
