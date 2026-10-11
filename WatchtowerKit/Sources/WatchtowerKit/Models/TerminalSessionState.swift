import Foundation
import WatchtowerSync

/// The `terminal_session` slice (mobile POC spec §4.5), record name
/// `terminal_session-<terminal_sessions.id>`: one claude session of a
/// workbench. The state fields are the Mac's resolved presentation
/// (`SessionSwitcherPresentation.State` through `SessionStatePresentation`);
/// the phone draws them as given and has no state rules of its own (PROJ-11).
/// The Claude session id, the folder and the raw hook columns are never
/// published.
public struct TerminalSessionState: SliceMirror, Identifiable {
    public static let sliceKind = SliceKind.terminalSession

    /// The resolved state. rawValues are wire format.
    public struct Kind: OpenWireValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let working = Self(rawValue: "working")
        /// Live, with no state reported during this run.
        public static let running = Self(rawValue: "running")
        public static let waitingOnAsk = Self(rawValue: "waiting_on_ask")
        public static let needsApproval = Self(rawValue: "needs_approval")
        public static let finished = Self(rawValue: "finished")
        public static let stopped = Self(rawValue: "stopped")
        public static let failed = Self(rawValue: "failed")
        public static let notStarted = Self(rawValue: "not_started")
        public static let knownValues: [Self] = [
            .working, .running, .waitingOnAsk, .needsApproval, .finished, .stopped, .failed, .notStarted
        ]
    }

    /// The dot's colour (`SessionStatePresentation.Tone`). rawValues are
    /// wire format.
    public struct Tone: OpenWireValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let green = Self(rawValue: "green")
        public static let orange = Self(rawValue: "orange")
        public static let blue = Self(rawValue: "blue")
        public static let red = Self(rawValue: "red")
        public static let secondary = Self(rawValue: "secondary")
        public static let knownValues: [Self] = [.green, .orange, .blue, .red, .secondary]
    }

    /// The agent running in the session; always `claude_code` in the POC.
    public struct Agent: OpenWireValue {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let claudeCode = Self(rawValue: "claude_code")
        public static let knownValues: [Self] = [.claudeCode]
    }

    public let id: Int64
    public let workbenchID: Int64
    /// Cap 200.
    public let title: String
    public let titleClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    public let targetID: Int64?
    public let agent: Agent
    public let createdAt: Date
    public let lastActiveAt: Date
    /// When the current state was reported; nil when unknown.
    public let stateAt: Date?
    /// The process runs on the Mac.
    public let live: Bool
    public let stateKind: Kind
    /// `SessionStatePresentation.caption`. Cap 120.
    public let stateCaption: String
    public let stateCaptionClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    public let stateTone: Tone
    /// An SF Symbol name, or "" for none.
    public let stateGlyph: String
    /// Draw a ring instead of a filled dot (the process does not run).
    public let isRing: Bool
    public let openAsks: Int
    /// The oldest open ask (the one a waiting caption names); nil without
    /// open asks.
    public let oldestAskID: Int64?
    /// Drives "▸ N closed".
    public let closedAsks: Int
    /// Cap 2000.
    public let finishSummary: String
    public let finishSummaryClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// The failed turn's error ("" when none or unknown). Cap 60.
    public let agentError: String
    public let agentErrorClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// The session-report summary (`#<target> · <done>/<total> · <pr line>`);
    /// absent until the hub's first summary run for the session.
    public let reportTargetID: Int64?
    public let reportDone: Int?
    public let reportTotal: Int?
    /// Cap 120.
    public let reportPRLine: String?
    public let reportPRLineClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean

    // convertFromSnakeCase maps "*_id" -> "*Id" and "report_pr_line" ->
    // "reportPrLine", so those keys use that form.
    enum CodingKeys: String, CodingKey {
        case id
        case workbenchID = "workbenchId"
        case title, titleClipped
        case targetID = "targetId"
        case agent, createdAt, lastActiveAt, stateAt, live, stateKind, stateCaption, stateCaptionClipped
        case stateTone, stateGlyph, isRing, openAsks
        case oldestAskID = "oldestAskId"
        case closedAsks, finishSummary, finishSummaryClipped, agentError, agentErrorClipped
        case reportTargetID = "reportTargetId"
        case reportDone, reportTotal
        case reportPRLine = "reportPrLine"
        case reportPRLineClipped = "reportPrLineClipped"
    }
}
