import Foundation
import Observation
import WatchtowerKit
import WatchtowerSync

/// What the Mac did with a line the phone sent (`result.delivery` of an
/// `applied` echo, spec §6.6); `queued` is a submitted line the Mac sent
/// while the agent worked (`result.while_busy`, PROJ-16 amended), which
/// the agent reads at its next step.
enum SessionInputDelivery: String, Equatable {
    case submitted, typed, queued

    var text: String {
        switch self {
        case .submitted: "Sent to the session"
        case .typed: "Typed into the session — press Return on the Mac"
        case .queued: Self.queuedText
        }
    }

    /// What the delivery means for `agent`'s session: send while busy is
    /// Claude's alone (PROJ-16 amended), so another agent's `queued` reads
    /// as `submitted` even if a hub said `while_busy`.
    func resolved(for agent: TerminalSessionState.Agent) -> Self {
        self == .queued && agent != .claudeCode ? .submitted : self
    }

    /// The line under the owner's bubble in the workchat (spec §5.4).
    func caption(for agent: TerminalSessionState.Agent) -> String {
        switch resolved(for: agent) {
        case .submitted: "Sent"
        case .typed, .queued: resolved(for: agent).text
        }
    }

    static let queuedText = "Queued · the agent reads it at its next step"
}

/// The phone's lines to a session (spec §5.2, §6.6, PROJ-16): the
/// workchat's composer (`session_input`), Finish (`session_finish_request`) and a
/// held line's Cancel (`session_input_cancel`), through the outbox. Owned by
/// `AppEnvironment`, so a line's way survives leaving the session. Also a
/// permission prompt's answer (`permission_answer`) and Interrupt
/// (`session_interrupt`, #517): neither types anything the phone wrote.
///
/// One send per session and kind at a time (`SendGuard`); nothing retries
/// on its own. An `applied` echo removes its overlay row, so the outbox's
/// applied observer brings its delivery (`receiveApplied(_:)`).
@MainActor
@Observable
final class SessionInputSender {
    typealias Enqueue = (ActionKind, String, [String: JSONValue]) async throws -> String

    /// Session id → where its last applied line went this run.
    private(set) var delivered: [Int64: SessionInputDelivery] = [:]
    /// Action id → where that applied line went this run: the caption of
    /// its bubble until the feed shows the line.
    private(set) var lineDeliveries: [String: SessionInputDelivery] = [:]
    /// Session id → where the phone's Finish went this run, until the next
    /// line to the session.
    private(set) var finishDeliveries: [Int64: SessionInputDelivery] = [:]
    /// Session id → the permission request whose answer the Mac applied
    /// this run.
    private(set) var answered: [Int64: Int64] = [:]
    var inFlight: Set<String> { sendGuard.inFlight }

    @ObservationIgnored private let sendGuard = SendGuard()
    @ObservationIgnored private let enqueue: Enqueue
    @ObservationIgnored private let remove: (String) throws -> Void

    init(enqueue: @escaping Enqueue, remove: @escaping (String) throws -> Void) {
        self.enqueue = enqueue
        self.remove = remove
    }

    /// The app's sender: actions through the outbox, Dismiss on the overlay.
    static func sending(through outbox: ActionOutbox, store: ReplicaStore) -> SessionInputSender {
        SessionInputSender(
            enqueue: { kind, entity, params in
                try await outbox.enqueue(kind: kind, entityRecordName: entity, params: params)
            },
            remove: { try store.dismissAction(id: $0) }
        )
    }

    nonisolated static func sendKey(_ sessionID: Int64) -> String {
        BoardWriter.key(.sessionInput, SessionStarter.sessionRecordName(sessionID))
    }

    nonisolated static func answerKey(_ sessionID: Int64) -> String {
        BoardWriter.key(.permissionAnswer, SessionStarter.sessionRecordName(sessionID))
    }

    nonisolated static func interruptKey(_ sessionID: Int64) -> String {
        BoardWriter.key(.sessionInterrupt, SessionStarter.sessionRecordName(sessionID))
    }

    /// Sends `text` to the session, normalized as the Mac does
    /// (`SessionInputText`); false for blank text, text over the Mac's
    /// limit, or while another line to it is on its way.
    @discardableResult
    func send(sessionID: Int64, text: String) async throws -> Bool {
        guard SessionInputText.isSendable(text) else { return false }
        let params = try SessionInputParams(text: SessionInputText.normalize(text)).wireParams()
        return try await run(.sessionInput, sessionID: sessionID, params: params)
    }

    /// Finish: the Mac types its fixed wrap-up line.
    @discardableResult
    func finish(sessionID: Int64) async throws -> Bool {
        try await run(.sessionFinishRequest, sessionID: sessionID, params: try SessionFinishRequestParams().wireParams())
    }

    /// Allow once or Deny on the session's prompt `requestID`; nothing
    /// (false) while an answer to the session is on its way.
    @discardableResult
    func answer(sessionID: Int64, requestID: Int64, behavior: PermissionAnswerParams.Behavior) async throws -> Bool {
        let params = try PermissionAnswerParams(requestID: requestID, behavior: behavior).wireParams()
        let entity = SessionStarter.sessionRecordName(sessionID)
        return try await sendGuard.run(Self.answerKey(sessionID)) {
            // Inside the guard: a refused duplicate keeps the last success.
            answered[sessionID] = nil
            _ = try await enqueue(.permissionAnswer, entity, params)
        }
    }

    /// Interrupt: the Mac sends one Esc while the session works.
    @discardableResult
    func interrupt(sessionID: Int64) async throws -> Bool {
        let params = try SessionInterruptParams().wireParams()
        let entity = SessionStarter.sessionRecordName(sessionID)
        return try await sendGuard.run(Self.interruptKey(sessionID)) {
            _ = try await enqueue(.sessionInterrupt, entity, params)
        }
    }

    /// Cancel on a held line: the Mac drops it if it was not typed yet.
    func cancel(_ row: PendingAction) async throws {
        let params = try SessionInputCancelParams().wireParams()
        _ = try await sendGuard.run(BoardWriter.key(.sessionInputCancel, row.action.recordName)) {
            _ = try await enqueue(.sessionInputCancel, row.action.recordName, params)
        }
    }

    /// Dismiss on a refused, expired or cancelled line.
    func dismiss(_ row: PendingAction) throws {
        try remove(row.id)
    }

    /// An `applied` echo of a line: keeps where it went; of an answer: its
    /// request. Other kinds are not ours.
    func receiveApplied(_ action: ActionRequestPayload) {
        if action.kind == .permissionAnswer,
           let sessionID = action.entityID.flatMap(Int64.init),
           case let .integer(requestID)? = action.params["request_id"] {
            answered[sessionID] = requestID
            return
        }
        guard action.kind == .sessionInput || action.kind == .sessionFinishRequest,
              let sessionID = action.entityID.flatMap(Int64.init) else { return }
        var delivery = SessionInputDelivery.submitted
        if case let .string(value)? = action.result?["delivery"], let known = SessionInputDelivery(rawValue: value) {
            delivery = known
        }
        if delivery == .submitted, action.result?["while_busy"] == .bool(true) {
            delivery = .queued
        }
        delivered[sessionID] = delivery
        if action.kind == .sessionInput {
            lineDeliveries[action.id] = delivery
        } else {
            finishDeliveries[sessionID] = delivery
        }
    }

    private func run(_ kind: ActionKind, sessionID: Int64, params: [String: JSONValue]) async throws -> Bool {
        delivered[sessionID] = nil
        finishDeliveries[sessionID] = nil
        let entity = SessionStarter.sessionRecordName(sessionID)
        return try await sendGuard.run(Self.sendKey(sessionID)) {
            _ = try await enqueue(kind, entity, params)
        }
    }
}

/// The workchat's input (spec §5.4, §6.6, PROJ-16): the composer and Finish
/// show only on a phone whose typing the Mac allowed and whose own toggle
/// is on, for a live Claude session (the Mac refuses any other agent's). A session at a permission prompt takes
/// nothing from the phone: "Needs approval on the Mac" (or "Answer the
/// request above" when the screen's permission card takes this phone's
/// answer, #517), no send. Each line on its way shows how far the Mac got,
/// a held one why (with Cancel), a refused one the Mac's message (with
/// Dismiss).
struct SessionInputModel: Equatable {
    static let needsApproval = "Needs approval on the Mac"
    static let answerAbove = "Answer the request above"
    /// Why a live session takes no line from this phone (board #515): the
    /// composer's place says what to do instead of staying empty.
    enum TypingHint: Equatable {
        /// The phone's own toggle is off: one tap asks the Mac.
        case turnOn
        /// Asked; the Mac has not allowed it yet.
        case waitingForMac
        /// Not a Claude session: the Mac takes phone lines and Finish for Claude sessions only (PROJ-16).
        case macOnly(TerminalSessionState.Agent)

        var text: String {
            switch self {
            case .turnOn: "Turn on typing to tell this session something from your phone."
            case .waitingForMac: "Waiting for your Mac to allow typing: Watchtower → Settings → Mobile → Allow…"
            case let .macOnly(agent): agent == .codexCLI ? "Write to Codex sessions on the Mac." : "Write to this session on the Mac."
            }
        }
    }

    /// One line the phone sent, until the Mac applied it.
    struct LineRow: Equatable, Identifiable {
        enum State: Equatable {
            /// On its way or held: the caption says which.
            case waiting(String)
            /// Held: Cancel drops it on the Mac.
            case held(String)
            case failed(String)
        }

        var id: String { pending.id }
        let text: String
        let state: State
        let pending: PendingAction
    }

    /// The composer is on screen.
    let showsBar: Bool
    /// In the composer's place on a live session this phone may not type to.
    let typingHint: TypingHint?
    /// Finish is in the actions menu.
    let showsFinish: Bool
    /// The session waits on a permission prompt: no send.
    let approvalText: String?
    let lines: [LineRow]
    /// Where the last applied line went.
    let notice: String?

    var canSend: Bool { showsBar && approvalText == nil }

    init(
        session: TerminalSessionState,
        snapshot: WorkbenchReplicaSnapshot,
        grant: DeviceGrant?,
        typingRequested: Bool,
        delivered: SessionInputDelivery?,
        now: Date,
        answersPermission: Bool = false
    ) {
        let allowed = typingRequested && grant?.typingAllowed == true
        let takesLines = session.agent == .claudeCode
        showsBar = allowed && session.live && takesLines
        showsFinish = showsBar
        typingHint = if !session.live {
            nil
        } else if !takesLines {
            .macOnly(session.agent)
        } else {
            allowed ? nil : (typingRequested ? .waitingForMac : .turnOn)
        }
        approvalText = session.stateKind == .needsApproval ? (answersPermission ? Self.answerAbove : Self.needsApproval) : nil
        notice = delivered?.text
        let entity = SessionStarter.sessionRecordName(session.id)
        let online = MacStatus(heartbeat: snapshot.heartbeat, now: now).isOnline
        lines = snapshot.pending
            .filter { ($0.action.kind == .sessionInput || $0.action.kind == .sessionFinishRequest) && $0.entityRecordName == entity }
            .map { Self.row($0, online: online) }
    }

    private static func row(_ row: PendingAction, online: Bool) -> LineRow {
        let text: String = if row.action.kind == .sessionFinishRequest {
            "Finish"
        } else if case let .string(line)? = row.action.params["text"] {
            line
        } else {
            ""
        }
        let state: LineRow.State
        switch (row.state, row.echoStatus) {
        case (.failed, _):
            state = .failed(row.errorMessage ?? BoardWriteText.waitingForMac)
        case (.pending, .held?):
            state = .held(heldText(row.reason))
        case (.pending, .received?):
            state = .waiting("Mac picked it up")
        case (.pending, _):
            state = .waiting(online ? "Sending…" : BoardWriteText.waitingForMac)
        }
        return LineRow(text: text, state: state, pending: row)
    }

    /// Why the Mac holds a line (spec §6.6).
    static func heldText(_ reason: ActionReason?) -> String {
        switch reason {
        case .agentBusy?: "Queued · sends when the agent stops"
        case .needsApproval?: "Held — \(needsApproval)"
        case .promptHasText?: "Held — text is typed in the session on the Mac"
        default: "Held — the Mac can't read the session's state yet"
        }
    }
}
