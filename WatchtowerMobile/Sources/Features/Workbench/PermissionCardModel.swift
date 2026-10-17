import Foundation
import WatchtowerKit
import WatchtowerSync

/// Why the permission card is read-only on this phone (#517, spec
/// 2026-10-17 §5.4): its own toggle is off, or the Mac has not allowed it
/// to answer. The typing grant never implies it.
enum PermissionHint: Equatable {
    case turnOn
    case waitingForMac

    var text: String {
        switch self {
        case .turnOn: "Turn on Answer permission prompts from this phone to answer here."
        case .waitingForMac: "Allow answering permission prompts on the Mac: Watchtower → Settings → Mobile → Allow…"
        }
    }
}

/// What the phone may do with a session's permission prompt: the Mac's
/// grant, the phone's toggle, the sends waiting for the outbox, and the
/// request whose answer the Mac applied this run.
struct PermissionAccess: Equatable {
    var grant: DeviceGrant?
    var requested = false
    var inFlight: Set<String> = []
    var sentRequestID: Int64?
}

/// The card of a live Claude session's pending permission prompt (#517,
/// spec §5.4), in place of "Needs approval on the Mac": the tool and its
/// summary, **Allow once** and **Deny** while the phone may answer, read
/// only with a hint otherwise. Only the hook's JSON decides the prompt;
/// nothing is typed into the session (PROJ-16).
struct PermissionCardModel: Equatable {
    static let clippedNote = "Shortened on the phone — the full text is on the Mac"
    static let allowLabel = "Allow once"
    static let denyLabel = "Deny"

    let requestID: Int64
    let sessionID: Int64
    let tool: String
    /// Monospace and scrollable on screen; never clipped silently.
    let summary: String
    let clippedNote: String?
    /// Allow once and Deny are live.
    let canAnswer: Bool
    /// nil when the phone may answer.
    let hint: PermissionHint?
    /// Allow on a Bash request asks first, showing the command.
    let confirmsAllow: Bool

    var allowConfirmTitle: String { "Allow this command once?" }

    init(request: PermissionRequest, session: TerminalSessionState, rows: [PermissionAnswerRow], access: PermissionAccess) {
        requestID = request.id
        sessionID = session.id
        tool = request.toolName
        summary = request.summary
        clippedNote = request.summaryClipped == true ? Self.clippedNote : nil
        confirmsAllow = request.toolName == "Bash"
        hint = if !access.requested {
            .turnOn
        } else if access.grant?.permissionsAllowed == true {
            nil
        } else {
            .waitingForMac
        }
        let answering = access.inFlight.contains(SessionInputSender.answerKey(session.id))
            || access.sentRequestID == request.id
            || rows.contains { $0.requestID == request.id && !$0.isFailed }
        canAnswer = hint == nil && session.live && !answering
    }
}

/// One answer the phone sent to a session's prompt, until the Mac applied
/// it: how far it got, or the Mac's refusal (with Dismiss) — e.g.
/// "Answered on the Mac" when the Mac answered first. A row outlives its
/// request: the hub stops publishing a prompt once it is answered.
struct PermissionAnswerRow: Equatable, Identifiable {
    enum State: Equatable {
        case waiting(String)
        case failed(String)
    }

    var id: String { pending.id }
    let requestID: Int64?
    let state: State
    let pending: PendingAction

    var isFailed: Bool {
        if case .failed = state { true } else { false }
    }

    static let failedFallback = "Your Mac could not take the answer"

    /// The session's answer rows, oldest first.
    static func rows(sessionID: Int64, snapshot: WorkbenchReplicaSnapshot, now: Date) -> [Self] {
        let entity = SessionStarter.sessionRecordName(sessionID)
        let online = MacStatus(heartbeat: snapshot.heartbeat, now: now).isOnline
        return snapshot.pending
            .filter { $0.action.kind == .permissionAnswer && $0.entityRecordName == entity }
            .map { row in
                let requestID: Int64? = if case let .integer(id)? = row.action.params["request_id"] { id } else { nil }
                let label = row.action.params["behavior"] == .string(PermissionAnswerParams.Behavior.allow.rawValue)
                    ? PermissionCardModel.allowLabel
                    : PermissionCardModel.denyLabel
                let state: State = switch (row.state, row.echoStatus) {
                case (.failed, _):
                    .failed(SessionStartText.failure(row, fallback: failedFallback))
                case (.pending, .received?):
                    .waiting("\(label) · \(SessionStartText.pickedUp)")
                case (.pending, _):
                    .waiting("\(label) · \(online ? BoardWriteText.sending : BoardWriteText.waitingForMac)")
                }
                return Self(requestID: requestID, state: state, pending: row)
            }
    }
}
