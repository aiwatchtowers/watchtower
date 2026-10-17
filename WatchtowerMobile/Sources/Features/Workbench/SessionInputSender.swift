import Foundation
import Observation
import WatchtowerKit
import WatchtowerSync

/// What the Mac did with a line the phone sent (`result.delivery` of an
/// `applied` echo, spec §6.6).
enum SessionInputDelivery: String, Equatable {
    case submitted, typed

    var text: String {
        switch self {
        case .submitted: "Sent to the session"
        case .typed: "Typed into the session — press Return on the Mac"
        }
    }
}

/// The phone's lines to a session (spec §5.2, §6.6, PROJ-16): "Tell the
/// session…" (`session_input`), Finish (`session_finish_request`) and a
/// held line's Cancel (`session_input_cancel`), through the outbox. Owned by
/// `AppEnvironment`, so a line's way survives leaving the session.
///
/// One send per session at a time (`SendGuard`); nothing retries on its
/// own. An `applied` echo removes its overlay row, so the outbox's applied
/// observer brings its delivery (`receiveApplied(_:)`).
@MainActor
@Observable
final class SessionInputSender {
    typealias Enqueue = (ActionKind, String, [String: JSONValue]) async throws -> String

    /// Session id → where its last applied line went this run.
    private(set) var delivered: [Int64: SessionInputDelivery] = [:]
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
            remove: { try store.removePendingAction(id: $0) }
        )
    }

    nonisolated static func sendKey(_ sessionID: Int64) -> String {
        BoardWriter.key(.sessionInput, SessionStarter.sessionRecordName(sessionID))
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

    /// An `applied` echo of a line: keeps where it went. Other kinds are
    /// not ours.
    func receiveApplied(_ action: ActionRequestPayload) {
        guard action.kind == .sessionInput || action.kind == .sessionFinishRequest,
              let sessionID = action.entityID.flatMap(Int64.init) else { return }
        if case let .string(value)? = action.result?["delivery"], let delivery = SessionInputDelivery(rawValue: value) {
            delivered[sessionID] = delivery
        } else {
            delivered[sessionID] = .submitted
        }
    }

    private func run(_ kind: ActionKind, sessionID: Int64, params: [String: JSONValue]) async throws -> Bool {
        delivered[sessionID] = nil
        let entity = SessionStarter.sessionRecordName(sessionID)
        return try await sendGuard.run(Self.sendKey(sessionID)) {
            _ = try await enqueue(kind, entity, params)
        }
    }
}

/// The session detail's input (spec §6.6, PROJ-16): the "Tell the
/// session…" bar and Finish show only on a phone whose typing the Mac
/// allowed and whose own toggle is on, for a live session. A session at a
/// permission prompt takes nothing from the phone: "Needs approval on the
/// Mac", no send. Each line on its way shows how far the Mac got, a held
/// one why (with Cancel), a refused one the Mac's message (with Dismiss).
struct SessionInputModel: Equatable {
    static let needsApproval = "Needs approval on the Mac"
    static let footnote = "Delivered when the agent is idle"

    /// Why a live session takes no line from this phone (board #515): the
    /// bar's place says what to do instead of staying empty.
    enum TypingHint: Equatable {
        /// The phone's own toggle is off: one tap asks the Mac.
        case turnOn
        /// Asked; the Mac has not allowed it yet.
        case waitingForMac

        var text: String {
            switch self {
            case .turnOn: "Turn on typing to tell this session something from your phone."
            case .waitingForMac: "Waiting for your Mac to allow typing: Watchtower → Settings → Mobile → Allow…"
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

    /// The bar is on screen.
    let showsBar: Bool
    /// In the bar's place on a live session this phone may not type to.
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
        now: Date
    ) {
        let allowed = typingRequested && grant?.typingAllowed == true
        showsBar = allowed && session.live
        showsFinish = showsBar
        typingHint = !session.live || allowed ? nil : (typingRequested ? .waitingForMac : .turnOn)
        approvalText = session.stateKind == .needsApproval ? Self.needsApproval : nil
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
        case .agentBusy?: "Held — goes when the agent is idle"
        case .needsApproval?: "Held — \(needsApproval)"
        case .promptHasText?: "Held — text is typed in the session on the Mac"
        default: "Held — the Mac can't read the session's state yet"
        }
    }
}
