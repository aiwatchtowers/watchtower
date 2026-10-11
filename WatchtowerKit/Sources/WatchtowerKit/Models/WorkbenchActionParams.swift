import Foundation
import WatchtowerSync

/// The typed `params` of one workbench action kind (mobile POC spec §5.2).
/// The phone builds them and hands `wireParams()` to `ActionOutbox`; the
/// keys are snake_case, as the hub reads them. A nil optional is an absent
/// key. The Mac re-validates every value.
public protocol ActionParams: Codable, Hashable, Sendable {
    static var actionKind: ActionKind { get }
}

extension ActionParams {
    /// The request's `params` object.
    public func wireParams() throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: try RelayCoder.makeEncoder().encode(self))
    }

    /// Reads the params back from a request (an echo, a queued action).
    public init(wireParams: [String: JSONValue]) throws {
        self = try RelayCoder.makeDecoder().decode(Self.self, from: try JSONEncoder().encode(wireParams))
    }
}

/// `ask_answer`, entity: the ask id.
public struct AskAnswerParams: ActionParams {
    public static let actionKind = ActionKind.askAnswer

    public let workbenchID: Int64
    public let answer: OwnerAskAnswer

    public init(workbenchID: Int64, answer: OwnerAskAnswer) {
        self.workbenchID = workbenchID
        self.answer = answer
    }

    enum CodingKeys: String, CodingKey {
        case workbenchID = "workbenchId"
        case answer
    }
}

/// `board_target_status`, entity: the target id. `fromStatus` is the status
/// the phone showed (stale-view guard).
public struct BoardTargetStatusParams: ActionParams {
    public static let actionKind = ActionKind.boardTargetStatus

    public let workbenchID: Int64
    /// One of `WorkbenchTargetStatus.editable`.
    public let status: WorkbenchTargetStatus
    public let fromStatus: WorkbenchTargetStatus

    public init(workbenchID: Int64, status: WorkbenchTargetStatus, fromStatus: WorkbenchTargetStatus) {
        self.workbenchID = workbenchID
        self.status = status
        self.fromStatus = fromStatus
    }

    enum CodingKeys: String, CodingKey {
        case workbenchID = "workbenchId"
        case status, fromStatus
    }
}

/// `board_target_priority`, entity: the target id. `fromPriority` is the
/// priority the phone showed (stale-view guard).
public struct BoardTargetPriorityParams: ActionParams {
    public static let actionKind = ActionKind.boardTargetPriority

    public let workbenchID: Int64
    public let priority: WorkbenchTargetPriority
    public let fromPriority: WorkbenchTargetPriority

    public init(workbenchID: Int64, priority: WorkbenchTargetPriority, fromPriority: WorkbenchTargetPriority) {
        self.workbenchID = workbenchID
        self.priority = priority
        self.fromPriority = fromPriority
    }

    enum CodingKeys: String, CodingKey {
        case workbenchID = "workbenchId"
        case priority, fromPriority
    }
}

/// `board_comment_add`, entity: the target id. `body` at most 4000.
public struct BoardCommentAddParams: ActionParams {
    public static let actionKind = ActionKind.boardCommentAdd

    public let workbenchID: Int64
    public let body: String

    public init(workbenchID: Int64, body: String) {
        self.workbenchID = workbenchID
        self.body = body
    }

    enum CodingKeys: String, CodingKey {
        case workbenchID = "workbenchId"
        case body
    }
}

/// `board_comment_reply`, entity: the root comment id. `body` at most 4000.
public struct BoardCommentReplyParams: ActionParams {
    public static let actionKind = ActionKind.boardCommentReply

    public let workbenchID: Int64
    public let body: String

    public init(workbenchID: Int64, body: String) {
        self.workbenchID = workbenchID
        self.body = body
    }

    enum CodingKeys: String, CodingKey {
        case workbenchID = "workbenchId"
        case body
    }
}

/// `board_target_create`, no entity. `text` at most 200, `intent` at most
/// 4000; `parentID` nil for a top-level target.
public struct BoardTargetCreateParams: ActionParams {
    public static let actionKind = ActionKind.boardTargetCreate

    public let workbenchID: Int64
    public let parentID: Int64?
    public let text: String
    public let intent: String
    public let priority: WorkbenchTargetPriority

    public init(
        workbenchID: Int64, parentID: Int64? = nil, text: String, intent: String, priority: WorkbenchTargetPriority
    ) {
        self.workbenchID = workbenchID
        self.parentID = parentID
        self.text = text
        self.intent = intent
        self.priority = priority
    }

    enum CodingKeys: String, CodingKey {
        case workbenchID = "workbenchId"
        case parentID = "parentId"
        case text, intent, priority
    }
}

/// `session_start`, entity: the target id. `brief` replaces the Mac's
/// "Work on it" brief, honoured only from a device allowed to type.
public struct SessionStartParams: ActionParams {
    public static let actionKind = ActionKind.sessionStart

    /// rawValues are wire format.
    public struct Mode: OpenWireValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// Always a new session.
        public static let new = Self(rawValue: "new")
        /// Reuse the target's session when it has one, as Work on it does.
        public static let openExisting = Self(rawValue: "open_existing")
        public static let knownValues: [Self] = [.new, .openExisting]
    }

    public let workbenchID: Int64
    public let mode: Mode
    public let planFirst: Bool
    /// Bring the workbench window forward on the Mac.
    public let bringForward: Bool
    public let brief: String?

    public init(workbenchID: Int64, mode: Mode, planFirst: Bool, bringForward: Bool, brief: String? = nil) {
        self.workbenchID = workbenchID
        self.mode = mode
        self.planFirst = planFirst
        self.bringForward = bringForward
        self.brief = brief
    }

    enum CodingKeys: String, CodingKey {
        case workbenchID = "workbenchId"
        case mode, planFirst, bringForward, brief
    }
}

/// `session_input`, entity: the session id. `text` at most 4000 (PROJ-16).
public struct SessionInputParams: ActionParams {
    public static let actionKind = ActionKind.sessionInput

    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// `session_input_cancel`, entity: the original `session_input` action id.
public struct SessionInputCancelParams: ActionParams {
    public static let actionKind = ActionKind.sessionInputCancel
    public init() {}
}

/// `session_finish_request`, entity: the session id. The Mac sends its fixed
/// wrap-up line.
public struct SessionFinishRequestParams: ActionParams {
    public static let actionKind = ActionKind.sessionFinishRequest
    public init() {}
}

/// `session_stop`, entity: the session id.
public struct SessionStopParams: ActionParams {
    public static let actionKind = ActionKind.sessionStop
    public init() {}
}

/// `session_report_request`, entity: the session id.
public struct SessionReportRequestParams: ActionParams {
    public static let actionKind = ActionKind.sessionReportRequest
    public init() {}
}
